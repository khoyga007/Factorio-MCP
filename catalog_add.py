"""Import a community blueprint string into the catalog as REFERENCE material.

Reference patterns are read, never auto-built: they carry no contract, so the agent has
to declare its own before the executor will touch one. Screening is two-stage — a static
offline screen (2.0 stamp, known Space Age names), then, when the game is reachable, the
only authoritative check: does every entity name exist in the running map.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from blueprint_library import import_reference, screen_reference
from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, request


def verify_against_game(names: list[str]) -> tuple[str, list[str]]:
    """Ask the running map for each prototype. Returns (version, names it does not know)."""
    host = os.environ.get("FACTORIO_HOST", DEFAULT_HOST)
    port = int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT))
    ping = request({"action": "ping"}, host=host, port=port, timeout=5)
    unknown = []
    for name in names:
        reply = request({"action": "spec", "kind": "entity", "name": name},
                        host=host, port=port, timeout=10)
        if not reply.get("ok"):
            unknown.append(name)
    return str(ping.get("version") or ping.get("build") or "unknown"), unknown


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path, help="file holding one blueprint string")
    parser.add_argument("--url", help="where it came from (factorioprints, factorio.school)")
    parser.add_argument("--note", help="one line: what it is good for")
    parser.add_argument("--screen-only", action="store_true",
                        help="report what the string is; write nothing")
    parser.add_argument("--offline", action="store_true",
                        help="skip the running-game check (record stays unverified)")
    args = parser.parse_args()

    value = "".join(args.file.read_text(encoding="utf-8").split())
    screen = screen_reference(value)
    checked, unknown = None, None
    if not args.offline:
        try:
            checked, unknown = verify_against_game(sorted(screen["entities"]))
            screen["unknown"] = unknown
        except (OSError, ValueError, TimeoutError) as exc:
            print(f"game unreachable ({exc}); rerun without --offline once it is up",
                  file=sys.stderr)
            checked, unknown = None, None
    if args.screen_only:
        print(json.dumps(screen, indent=2, ensure_ascii=False))
        return 0
    try:
        record = import_reference(value, url=args.url, note=args.note,
                                  checked_against=checked, unknown=unknown)
    except ValueError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(record, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
