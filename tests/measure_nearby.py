"""Live check of agent-facing observe(nearby) size vs the raw per-entity view.

Run at each factory scale step (read-only):
    python tests/measure_nearby.py --x -55 --y 25 --radius 32
Prints calls/chars old vs new. Capture a new fixture with --save when the factory
changes shape, then keep tests/test_perception.py caps honest.
"""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import factorio_goal_mcp as g  # noqa: E402

KEEP = ("name", "type", "x", "y", "direction", "status_name", "recipe", "belt_to_ground_type",
        "fuel", "input", "output", "fluids", "lines")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--x", type=float, required=True)
    ap.add_argument("--y", type=float, required=True)
    ap.add_argument("--radius", type=float, default=32)
    ap.add_argument("--save", type=Path, help="write trimmed snapshot rows as a test fixture")
    a = ap.parse_args()
    old = calls = 0
    offset = 0
    while offset is not None:
        text = g.observe(view="entities", x=a.x, y=a.y, radius=a.radius, offset=offset).content[0].text
        page = json.loads(text)
        if not page.get("ok"):
            raise SystemExit(text)
        old += len(text)
        calls += 1
        offset = page.get("entities_next_offset")
    text = g.observe(view="nearby", x=a.x, y=a.y, radius=a.radius).content[0].text
    new = json.loads(text)
    print(json.dumps({"entities": new.get("entities_total"), "old_calls": calls, "old_chars": old,
                      "new_calls": 1, "new_chars": len(text), "ratio": round(old / len(text), 1),
                      "issues": len(new.get("issues", [])), "truncated_at": new.get("truncated_at")}))
    if a.save:
        rows, offset = [], 0
        while offset is not None:
            p = g._read(g.invoke("snapshot", surface="nauvis", x=a.x, y=a.y, radius=a.radius,
                                 offset=offset, limit=64, tiles=False, name=None, obstacles=False))
            rows += [{k: e[k] for k in KEEP if k in e} for e in p["entities"]]
            offset = p.get("entities_next_offset")
        a.save.write_text(json.dumps({"source": f"live x={a.x} y={a.y} r={a.radius}", "rows": rows},
                                     separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    main()
