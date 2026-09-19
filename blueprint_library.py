"""Small local catalog of reusable native Factorio blueprints."""

from __future__ import annotations

import base64
import binascii
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import zlib


ROOT = Path(__file__).resolve().parent
ID = re.compile(r"bp-[0-9a-f]{16}\Z")
RANK = {"captured": 0, "built": 1, "verified": 2}


def catalog_dir() -> Path:
    return Path(os.environ.get("FACTORIO_BLUEPRINT_CATALOG", ROOT / "blueprints" / "catalog"))


def script_output_dir() -> Path:
    if "FACTORIO_SCRIPT_OUTPUT" in os.environ:
        return Path(os.environ["FACTORIO_SCRIPT_OUTPUT"])
    return Path(os.environ["APPDATA"]) / "Factorio" / "script-output"


def _decode_blueprint(value: str) -> dict:
    if not value.startswith("0") or len(value) > 24000:
        raise ValueError("invalid-native-blueprint")
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(base64.b64decode(value[1:], validate=True), 1_000_001)
        if len(raw) > 1_000_000 or not decoder.eof:
            raise ValueError("blueprint-payload-too-large")
        data = json.loads(raw)
        blueprint = data["blueprint"]
        if blueprint["item"] != "blueprint":
            raise ValueError("not-a-blueprint")
        entities = blueprint["entities"]
        if not isinstance(entities, list) or not 0 < len(entities) <= 500:
            raise ValueError("invalid-entity-count")
        for entity in entities:
            if not isinstance(entity["name"], str) or not entity["name"]:
                raise ValueError("invalid-entity")
            pos = entity["position"]
            if not math.isfinite(pos["x"]) or not math.isfinite(pos["y"]):
                raise ValueError("invalid-position")
        return blueprint
    except (KeyError, TypeError, IndexError, ValueError, binascii.Error, zlib.error) as exc:
        raise ValueError("invalid-native-blueprint") from exc


def parse_blueprint(value: str) -> list[dict]:
    return _decode_blueprint(value)["entities"]


def pattern_id_for(value: str) -> str:
    """Ignore translation and entity ordering for plain machine layouts."""
    blueprint = _decode_blueprint(value)
    entities = blueprint["entities"]
    raw_id = hashlib.sha256(value.encode("ascii")).hexdigest()[:16]
    if set(blueprint) - {"icons", "entities", "item", "version", "label", "description"} or any(any(key in e for key in ("connections", "neighbours", "wires", "schedule"))
           for e in entities):
        return "bp-" + raw_id
    min_x = min(e["position"]["x"] for e in entities)
    min_y = min(e["position"]["y"] for e in entities)
    normalized = []
    for entity in entities:
        row = {key: value for key, value in entity.items()
               if key not in {"entity_number", "position", "direction"}}
        row["direction"] = entity.get("direction", 0)
        row["position"] = {
            "x": round(entity["position"]["x"] - min_x, 6),
            "y": round(entity["position"]["y"] - min_y, 6),
        }
        normalized.append(json.dumps(row, sort_keys=True, separators=(",", ":")))
    normalized.sort()
    return "bp-" + hashlib.sha256("\n".join(normalized).encode()).hexdigest()[:16]


def record_blueprint(value: str, *, state: str, source: str,
                     materials: dict | None = None, audit: dict | None = None) -> dict:
    """Deduplicate plain layouts; keep placement coordinates out of metadata."""
    if state not in RANK:
        raise ValueError("invalid-pattern-state")
    entities = parse_blueprint(value)
    pattern_id = pattern_id_for(value)
    folder = catalog_dir()
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{pattern_id}.json"
    old = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    positions = [e["position"] for e in entities]
    counts = dict(sorted(Counter(e["name"] for e in entities).items()))
    best = state if RANK[state] > RANK.get(old.get("state"), -1) else old["state"]
    record = {
        "schema_version": 1,
        "pattern_id": pattern_id,
        "state": best,
        "sources": sorted(set(old.get("sources", [])) | {source}),
        "entity_count": len(entities),
        "entities": counts,
        "relative_centers": {
            "min_x": 0,
            "min_y": 0,
            "max_x": max(p["x"] for p in positions) - min(p["x"] for p in positions),
            "max_y": max(p["y"] for p in positions) - min(p["y"] for p in positions),
        },
        "required_items": old.get("required_items") or materials or None,
        "audit": audit if state == "verified" and audit else old.get("audit"),
        "blueprint_string": value,
    }
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=folder,
                                     prefix=pattern_id + ".", suffix=".tmp",
                                     delete=False) as output:
        temp = Path(output.name)
        json.dump(record, output, ensure_ascii=False, separators=(",", ":"))
        output.write("\n")
    os.replace(temp, path)
    return {key: record[key] for key in ("pattern_id", "state", "entity_count", "entities")}


def list_patterns() -> list[dict]:
    folder = catalog_dir()
    if not folder.exists():
        return []
    rows = []
    for path in sorted(folder.glob("bp-*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        rows.append({key: data.get(key) for key in (
            "pattern_id", "state", "entity_count", "entities", "required_items")})
    return rows


def load_pattern(pattern_id: str) -> dict:
    if not ID.fullmatch(pattern_id):
        raise ValueError("invalid-pattern-id")
    path = catalog_dir() / f"{pattern_id}.json"
    if not path.exists():
        raise ValueError("pattern-not-found")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("pattern_id") != pattern_id:
        raise ValueError("pattern-id-mismatch")
    value = data["blueprint_string"]
    if pattern_id_for(value) != pattern_id:
        raise ValueError("pattern-content-mismatch")
    parse_blueprint(value)
    return data


def artifact_blueprint(artifact: str) -> str:
    relative = Path(artifact)
    if relative.is_absolute() or ".." in relative.parts or not artifact:
        raise ValueError("invalid-artifact")
    path = script_output_dir() / (artifact + ".blueprint.txt")
    return path.read_text(encoding="ascii").strip()
