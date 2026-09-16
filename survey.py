"""Read-only map survey: compact factory status around a point.

Usage: python survey.py X Y [RADIUS] [--details]
"""

from collections import Counter
import sys

from factorio_ai import request


ATTENTION = {"no_power", "no_fuel", "no_ingredients", "item_ingredient_shortage",
             "fluid_ingredient_shortage", "low_power", "not_plugged_in_electric_network"}


def survey(x: float, y: float, radius: float = 32.0, *, details: bool = False) -> int:
    entities = []
    offset = 0
    pages = 0
    while True:
        reply = request({
            "action": "snapshot", "surface": "nauvis", "x": x, "y": y,
            "radius": radius, "offset": offset, "limit": 64,
        })
        if not reply.get("ok"):
            print("ERR", reply.get("error", reply))
            return 1
        pages += 1
        entities.extend(reply.get("entities", []))
        offset = reply.get("entities_next_offset")
        if offset is None:
            break

    print(
        f"=== center=({x},{y}) r={radius} "
        f"entities={len(entities)}/{reply.get('entities_total')} "
        f"pages={pages} tick={reply.get('tick')}"
    )
    counts = Counter(e["name"] for e in entities)
    print("machines:", ", ".join(f"{name}={count}" for name, count in counts.most_common()))
    issues = [e for e in entities if e.get("status_name") in ATTENTION]
    print("attention:", len(issues))
    for e in issues[:20]:
        print(f"  {e['name']} ({e['x']},{e['y']}) {e['status_name']}")
    if len(issues) > 20:
        print(f"  ... {len(issues) - 20} more")
    if details:
        for e in entities:
            print(
                f"  {e['type']:22s} {e['name']:26s} "
                f"x={e['x']:8.1f} y={e['y']:8.1f} u={e.get('unit_number')}"
            )
    resources = Counter()
    for row in reply.get("resources", []):
        resources[row["name"]] += row["amount"]
    print("resources:", dict(resources) if resources else "(none)")
    treasury = reply.get("treasury") or {}
    print("treasury:", {row["name"]: row["count"] for row in treasury.get("contents", [])})
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    x = float(sys.argv[1])
    y = float(sys.argv[2])
    args = [arg for arg in sys.argv[3:] if arg != "--details"]
    r = float(args[0]) if args else 32.0
    raise SystemExit(survey(x, y, r, details="--details" in sys.argv[3:]))
