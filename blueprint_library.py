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
RANK = {"designed": 0, "captured": 0, "built": 1, "verified": 2}
# Native 2.0 blueprint version stamp (from in-game exports).
VERSION = 562949954732032
DESIGN_KEYS = {"recipe", "type"}


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


def encode_blueprint(design: list[dict], label: str | None = None) -> str:
    """Agent layout -> native blueprint string. Positions = entity centers in tiles
    (odd-size entity on .5, even-size on integer); direction 16-way (0 N, 4 E, 8 S, 12 W)."""
    if not isinstance(design, list) or not 0 < len(design) <= 500:
        raise ValueError("invalid-design-size")
    entities = []
    for i, row in enumerate(design, 1):
        try:
            name, x, y = row["name"], float(row["x"]), float(row["y"])
            direction = int(row.get("direction", 0))
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"invalid-design-entity:{i}") from exc
        if not isinstance(name, str) or not name or not (math.isfinite(x) and math.isfinite(y))            or not 0 <= direction <= 15 or (x * 2) % 1 or (y * 2) % 1:
            raise ValueError(f"invalid-design-entity:{i}")
        entity = {"entity_number": i, "name": name, "position": {"x": x, "y": y}}
        if direction:
            entity["direction"] = direction
        for key in DESIGN_KEYS & set(row):
            if not isinstance(row[key], str):
                raise ValueError(f"invalid-design-entity:{i}")
            entity[key] = row[key]
        entities.append(entity)
    blueprint = {"item": "blueprint", "version": VERSION, "entities": entities,
                 "icons": [{"signal": {"name": n}, "index": k} for k, n in
                           enumerate(dict.fromkeys(e["name"] for e in entities), 1) if k <= 4]}
    if label:
        blueprint["label"] = str(label)[:100]
    raw = json.dumps({"blueprint": blueprint}, separators=(",", ":")).encode()
    value = "0" + base64.b64encode(zlib.compress(raw, 9)).decode("ascii")
    _decode_blueprint(value)
    return value


def pattern_entities(value: str) -> list[dict]:
    """Readable layout shifted by whole tiles near 0,0 (keeps .5/integer center parity)."""
    entities = parse_blueprint(value)
    min_x = math.floor(min(e["position"]["x"] for e in entities))
    min_y = math.floor(min(e["position"]["y"] for e in entities))
    rows = []
    for e in entities:
        row = {"name": e["name"], "x": e["position"]["x"] - min_x, "y": e["position"]["y"] - min_y,
               "direction": e.get("direction", 0)}
        row.update({k: e[k] for k in DESIGN_KEYS if k in e})
        rows.append(row)
    return rows


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
                     materials: dict | None = None, audit: dict | None = None,
                     contract: dict | None = None) -> dict:
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
        "contract": contract or old.get("contract"),
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
        row = {key: data.get(key) for key in (
            "pattern_id", "state", "entity_count", "entities", "required_items")}
        row["has_contract"] = bool(data.get("contract"))
        rows.append(row)
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
