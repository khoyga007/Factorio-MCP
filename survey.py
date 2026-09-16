"""Read-only map survey: print entities, resources and treasury around a point.

Usage: python survey.py X Y [RADIUS]
"""

import json
import sys

from factorio_ai import request


def survey(x: float, y: float, radius: float = 32.0) -> int:
    reply = request(
        {
            "action": "snapshot",
            "surface": "nauvis",
            "x": x,
            "y": y,
            "radius": radius,
            "offset": 0,
            "limit": 64,
        }
    )
    if not reply.get("ok"):
        print("ERR", json.dumps(reply, ensure_ascii=False))
        return 1
    print(
        f"=== center=({x},{y}) r={radius} "
        f"entities={reply.get('entities_total')} tick={reply.get('tick')}"
    )
    for e in reply.get("entities", []):
        print(
            f"  {e['type']:22s} {e['name']:26s} "
            f"x={e['x']:8.1f} y={e['y']:8.1f} u={e.get('unit_number')}"
        )
    res = reply.get("resources", {})
    print("resources:", json.dumps(res, ensure_ascii=False) if res else "(none)")
    treasury = reply.get("treasury", {})
    print("treasury:", json.dumps(treasury.get("contents"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    x = float(sys.argv[1])
    y = float(sys.argv[2])
    r = float(sys.argv[3]) if len(sys.argv) > 3 else 32.0
    raise SystemExit(survey(x, y, r))
