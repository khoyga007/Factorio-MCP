"""Scan a grid for water (pumpable fluid) using snapshot --tiles.

Usage: python scan_water.py CX CY [HALF_EXTENT] [STEP]
"""

import sys

from factorio_ai import request


def scan(cx: float, cy: float, half: float = 160.0, step: float = 64.0) -> int:
    hits = []
    x = cx - half
    while x <= cx + half:
        y = cy - half
        while y <= cy + half:
            rep = request(
                {"action": "snapshot", "surface": "nauvis", "x": x, "y": y,
                 "radius": 32, "tiles": True}
            )
            tiles = rep.get("tiles") if rep.get("ok") else None
            n = tiles.get("count", 0) if tiles else -1
            if n and n > 0:
                hits.append((round(x), round(y), n))
                print(f"water at grid ({x},{y}) count={n}")
            y += step
        x += step
    if not hits:
        print("no water in scan box")
    else:
        print(f"total {len(hits)} grid cells with water")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    cx = float(sys.argv[1])
    cy = float(sys.argv[2])
    half = float(sys.argv[3]) if len(sys.argv) > 3 else 160.0
    step = float(sys.argv[4]) if len(sys.argv) > 4 else 64.0
    raise SystemExit(scan(cx, cy, half, step))
