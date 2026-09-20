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
# `reference` ranks below everything: imported human material never overrides what the
# agent designed, built or verified, and any of those promote a reference record.
RANK = {"reference": 0, "designed": 1, "captured": 1, "built": 2, "verified": 3}
# The executor builds at most 1000 entities: a whole starter base is one paste (maintainer's
# lab blueprint is 508), and ghost mode drains it 12 entities per tick. The reply that
# carries one row per entity still fits a UDP datagram (~34 B/row). Reference material is
# only ever read, so it keeps a looser cap.
BUILD_ENTITY_LIMIT = 1000
REFERENCE_ENTITY_LIMIT = 2000
# A string the bridge may have to carry over UDP vs one that is only ever read locally.
BUILD_STRING_CHARS = 24000
REFERENCE_STRING_CHARS = 200000
# A blueprint book is one string holding many layouts; 30 nested books decompress to ~10 MB.
BOOK_PAYLOAD_BYTES = 40_000_000
# Space Age entities, screened statically because the base game cannot be enumerated
# offline. INCOMPLETE by construction: the authoritative check is `verify_against_game`,
# which asks the running map whether every name exists.
SPACE_AGE = {
    "agricultural-tower", "asteroid-collector", "biochamber", "big-mining-drill",
    "captive-biter-spawner", "cargo-bay", "cargo-landing-pad", "crusher",
    "cryogenic-plant", "electromagnetic-plant", "foundry", "fusion-generator",
    "fusion-reactor", "heating-tower", "lightning-collector", "lightning-rod",
    "railgun-turret", "recycler", "rocket-turret", "space-platform-hub",
    "stack-inserter", "tesla-turret", "thruster", "turbo-splitter",
    "turbo-transport-belt", "turbo-underground-belt",
}
# Native 2.0 blueprint version stamp (from in-game exports).
VERSION = 562949954732032
DESIGN_KEYS = {"recipe", "type"}


def catalog_dir() -> Path:
    return Path(os.environ.get("FACTORIO_BLUEPRINT_CATALOG", ROOT / "blueprints" / "catalog"))


def script_output_dir() -> Path:
    if "FACTORIO_SCRIPT_OUTPUT" in os.environ:
        return Path(os.environ["FACTORIO_SCRIPT_OUTPUT"])
    return Path(os.environ["APPDATA"]) / "Factorio" / "script-output"


def _decode_blueprint(value: str, limit: int = BUILD_ENTITY_LIMIT) -> dict:
    # One knob: asking for more entities than a job can build means this string is
    # reference material, which is read locally and never has to fit in a UDP packet.
    max_chars = BUILD_STRING_CHARS if limit <= BUILD_ENTITY_LIMIT else REFERENCE_STRING_CHARS
    if not value.startswith("0") or len(value) > max_chars:
        raise ValueError("invalid-native-blueprint")
    try:
        decoder = zlib.decompressobj()
        cap = 1_000_000 if limit <= BUILD_ENTITY_LIMIT else 20_000_000
        raw = decoder.decompress(base64.b64decode(value[1:], validate=True), cap + 1)
        if len(raw) > cap or not decoder.eof:
            raise ValueError("blueprint-payload-too-large")
        data = json.loads(raw)
        blueprint = data["blueprint"]
        if blueprint["item"] != "blueprint":
            raise ValueError("not-a-blueprint")
        entities = blueprint["entities"]
        if not isinstance(entities, list) or not 0 < len(entities) <= limit:
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


def parse_blueprint(value: str, limit: int = BUILD_ENTITY_LIMIT) -> list[dict]:
    return _decode_blueprint(value, limit)["entities"]


def encode_blueprint(design: list[dict], label: str | None = None) -> str:
    """Agent layout -> native blueprint string. Positions = entity centers in tiles
    (odd-size entity on .5, even-size on integer); direction 16-way (0 N, 4 E, 8 S, 12 W)."""
    if not isinstance(design, list) or not 0 < len(design) <= BUILD_ENTITY_LIMIT:
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


def pattern_id_for(value: str, limit: int = BUILD_ENTITY_LIMIT) -> str:
    """Ignore translation and entity ordering for plain machine layouts."""
    blueprint = _decode_blueprint(value, limit)
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
                     contract: dict | None = None, origin: dict | None = None,
                     limit: int = BUILD_ENTITY_LIMIT) -> dict:
    """Deduplicate plain layouts; keep placement coordinates out of metadata."""
    if state not in RANK:
        raise ValueError("invalid-pattern-state")
    entities = parse_blueprint(value, limit)
    pattern_id = pattern_id_for(value, limit)
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
        "origin": origin or old.get("origin"),
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


def list_patterns(reference: bool = False, query: str | None = None,
                  offset: int = 0, limit: int = 40) -> dict:
    """The agent's own patterns by default. Imported reference material is a library, not
    a work queue: hundreds of rows would drown the reply, so it is listed separately,
    compactly, and only what a filter word asks for."""
    folder = catalog_dir()
    rows, total = [], 0
    for path in sorted(folder.glob("bp-*.json")) if folder.exists() else []:
        data = json.loads(path.read_text(encoding="utf-8"))
        origin = data.get("origin") or {}
        is_reference = data.get("state") == "reference"
        if is_reference != reference:
            continue
        if reference:
            where = " / ".join(origin.get("path") or [])
            text = f"{origin.get('label') or ''} {where}".lower()
            if query and query.lower() not in text:
                continue
            total += 1
            if offset <= total - 1 < offset + limit:
                rows.append({"pattern_id": data["pattern_id"], "label": origin.get("label"),
                             "book": where or None, "entity_count": data.get("entity_count")})
            continue
        total += 1
        row = {key: data.get(key) for key in (
            "pattern_id", "state", "entity_count", "entities", "required_items")}
        row["has_contract"] = bool(data.get("contract"))
        if origin:
            row["origin"] = origin.get("kind")
        rows.append(row)
    return {"patterns": rows, "total": total,
            "next_offset": offset + len(rows) if reference and offset + len(rows) < total else None}


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
    limit = REFERENCE_ENTITY_LIMIT if data.get("state") == "reference" else BUILD_ENTITY_LIMIT
    if pattern_id_for(value, limit) != pattern_id:
        raise ValueError("pattern-content-mismatch")
    parse_blueprint(value, limit)
    return data


def artifact_blueprint(artifact: str) -> str:
    relative = Path(artifact)
    if relative.is_absolute() or ".." in relative.parts or not artifact:
        raise ValueError("invalid-artifact")
    path = script_output_dir() / (artifact + ".blueprint.txt")
    return path.read_text(encoding="ascii").strip()


def game_version(blueprint: dict) -> str:
    """Factorio packs its version as four 16-bit fields in one integer."""
    v = int(blueprint.get("version") or 0)
    return ".".join(str((v >> (16 * i)) & 0xFFFF) for i in (3, 2, 1, 0))


def screen_reference(value: str) -> dict:
    """What an imported string is, before anything is written. Never builds, never
    contacts the game: `space_age` here is a static guess, `unknown` stays empty until
    verify_against_game has asked the running map."""
    blueprint = _decode_blueprint(value, REFERENCE_ENTITY_LIMIT)
    names = Counter(e["name"] for e in blueprint["entities"])
    version = game_version(blueprint)
    return {
        "label": blueprint.get("label"),
        "description": blueprint.get("description"),
        "game_version": version,
        "major": version.split(".")[0],
        "entity_count": sum(names.values()),
        "entities": dict(sorted(names.items())),
        "space_age": sorted(n for n in names if n in SPACE_AGE),
        "unknown": [],
        "over_build_limit": sum(names.values()) > BUILD_ENTITY_LIMIT,
    }


def import_reference(value: str, *, url: str | None = None, note: str | None = None,
                     checked_against: str | None = None,
                     unknown: list[str] | None = None,
                     path: list[str] | None = None) -> dict:
    """Store a human-made blueprint as REFERENCE: readable, never auto-built. It carries
    no contract, so the agent must declare its own before the executor will touch it."""
    value = "".join(value.split())
    screen = screen_reference(value)
    if screen["major"] != "2":
        raise ValueError("not-a-2.0-blueprint:" + screen["game_version"])
    if screen["space_age"]:
        raise ValueError("space-age-entities:" + ",".join(screen["space_age"]))
    if unknown:
        raise ValueError("entities-not-in-this-game:" + ",".join(sorted(unknown)))
    origin = {"kind": "community", "url": url, "note": note,
              "label": screen["label"], "game_version": screen["game_version"],
              "checked_against": checked_against, "path": path or None}
    record = record_blueprint(value, state="reference", source="import",
                              origin={k: v for k, v in origin.items() if v is not None},
                              limit=REFERENCE_ENTITY_LIMIT)
    record["origin"] = origin
    record["over_build_limit"] = screen["over_build_limit"]
    return record


def read_book(text: str) -> list[tuple[list[str], str]]:
    """Flatten one blueprint-book string into (path, single-blueprint string) leaves.
    Path is the chain of book labels, so an imported leaf still says where it sat."""
    text = "".join(text.split())
    if not text.startswith("0"):
        raise ValueError("invalid-native-blueprint")
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(base64.b64decode(text[1:], validate=True),
                                 BOOK_PAYLOAD_BYTES + 1)
        if len(raw) > BOOK_PAYLOAD_BYTES or not decoder.eof:
            raise ValueError("book-payload-too-large")
        data = json.loads(raw)
    except (TypeError, ValueError, binascii.Error, zlib.error) as exc:
        raise ValueError("invalid-native-blueprint") from exc
    if "blueprint_book" not in data:
        raise ValueError("not-a-blueprint-book")
    leaves: list[tuple[list[str], str]] = []

    def walk(entries, path):
        for entry in entries or []:
            if "blueprint_book" in entry:
                book = entry["blueprint_book"]
                walk(book.get("blueprints"), path + [str(book.get("label") or "?")])
            elif "blueprint" in entry:
                raw_leaf = json.dumps({"blueprint": entry["blueprint"]},
                                      separators=(",", ":")).encode()
                leaves.append((path, "0" + base64.b64encode(
                    zlib.compress(raw_leaf, 9)).decode("ascii")))

    walk(data["blueprint_book"].get("blueprints"), [])
    if not leaves:
        raise ValueError("empty-blueprint-book")
    return leaves

