"""Export prototype numbers from a running game into spec.json.

Reads a manifest of (kind, name) prototype lookups, calls the live ``spec``
action on each, and writes a machine-readable spec.json that ``spec_loader``
and ``factorio_model`` consume. Requires the game to be running with the
bridge mod loaded; the loader and its tests run without the game.

Usage:
    python spec_export.py --entity burner-mining-drill --item coal --recipe iron-plate -o spec.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from factorio_ai import request
from spec_loader import SCHEMA_VERSION, entity_fields, item_fields, recipe_fields


def collect(manifest: list[dict[str, str]], *, host: str, port: int) -> dict[str, Any]:
    out: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "entities": {},
        "items": {},
        "recipes": {},
    }
    for entry in manifest:
        kind, name = entry["kind"], entry["name"]
        reply = request(
            {"action": "spec", "kind": kind, "name": name}, host=host, port=port
        )
        if not reply.get("ok"):
            raise RuntimeError(f"spec {kind}:{name} failed: {reply.get('error')}")
        if kind == "entity":
            out["entities"][name] = entity_fields(reply)
        elif kind == "item":
            out["items"][name] = item_fields(reply)
        elif kind == "recipe":
            out["recipes"][name] = recipe_fields(reply)
        else:
            raise ValueError(f"unknown spec kind {kind!r}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=34198)
    ap.add_argument("--entity", action="append", default=[], metavar="NAME")
    ap.add_argument("--item", action="append", default=[], metavar="NAME")
    ap.add_argument("--recipe", action="append", default=[], metavar="NAME")
    ap.add_argument("-o", "--output", default="spec.json")
    args = ap.parse_args()

    manifest = (
        [{"kind": "entity", "name": n} for n in args.entity]
        + [{"kind": "item", "name": n} for n in args.item]
        + [{"kind": "recipe", "name": n} for n in args.recipe]
    )
    if not manifest:
        ap.error("nothing to export; pass --entity/--item/--recipe at least once")

    spec = collect(manifest, host=args.host, port=args.port)
    Path(args.output).write_text(
        json.dumps(spec, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {"ok": True, "output": args.output, "count": len(manifest)},
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
