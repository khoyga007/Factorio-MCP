"""Compress raw snapshot rows into what an agent reads: issues first, machines, runs, poles.

Pure functions (no game I/O) so the Lua side stays a cheap fact dump.
Rule: compress repetition, never geometry -- every run keeps from/to/len/direction.
"""
from __future__ import annotations

import math
from collections import defaultdict

RUN_TYPES = {"transport-belt", "pipe"}
POLE_TYPES = {"electric-pole"}
QUIET = {"working", "normal", None}
# Flow states: backpressure or idle between items. Shown on the row, not raised as issues.
WAITING = {"waiting_for_space_in_destination", "waiting_for_source_items", "full_output",
           "waiting_to_launch_rocket", "waiting_for_target_to_be_built"}
# Flow states are frequent and long: short aliases (documented in MCP.md).
SHORT = {"waiting_for_space_in_destination": "blocked", "waiting_for_source_items": "idle",
         "full_output": "full"}
# Direction carries no meaning for these; omit it.
NO_DIRECTION = {"electric-pole", "container", "pipe", "furnace", "lab", "logistic-container"}


def num(v):
    """Round floats to 1 decimal; integral values become int."""
    if isinstance(v, float):
        v = round(v, 1)
        return int(v) if v == int(v) else v
    return v


def stock(rows) -> str | None:
    """[{name,count}] or {name:count} -> 'coal:5 iron-plate:3' (None when empty)."""
    totals: dict[str, int] = defaultdict(int)
    items = rows.items() if isinstance(rows, dict) else (
        (r.get("name"), r.get("count", 0)) for r in rows or [] if isinstance(r, dict))
    for name, count in items:
        if name:
            totals[name] += count
    return " ".join(f"{n}:{c}" for n, c in sorted(totals.items())) or None


def fluid(rows) -> str | None:
    """Fluidboxes -> 'water:100 steam:199.8@165' (temperature only when not ambient 15)."""
    out = []
    for f in rows or []:
        if not isinstance(f, dict) or not f.get("name"):
            continue
        s = f"{f['name']}:{num(float(f.get('amount', 0)))}"
        t = f.get("temperature")
        if t is not None and num(float(t)) != 15:
            s += f"@{num(float(t))}"
        out.append(s)
    return " ".join(out) or None


def machine(e: dict) -> dict:
    row = {"name": e["name"], "at": [num(e["x"]), num(e["y"])]}
    d = e.get("direction")
    if e.get("type") not in NO_DIRECTION and d is not None and (d or e.get("type") != "assembling-machine"):
        row["dir"] = d
    if e.get("status_name") not in QUIET:
        row["status"] = SHORT.get(e["status_name"], e["status_name"])
    if e.get("recipe"):
        row["recipe"] = e["recipe"]
    if e.get("belt_to_ground_type"):
        row["io"] = e["belt_to_ground_type"]
    for key, src in (("fuel", "fuel"), ("in", "input"), ("out", "output")):
        s = stock(e.get(src))
        if s:
            row[key] = s
    s = fluid(e.get("fluids"))
    if s:
        row["fluid"] = s
    return row


def _segments(cells: dict, horizontal: bool):
    """Maximal straight chains of adjacent tiles. cells: (x,y) -> row."""
    lines = defaultdict(list)
    for (x, y) in cells:
        lines[y if horizontal else x].append(x if horizontal else y)
    for fixed, coords in lines.items():
        coords.sort()
        start = prev = coords[0]
        for c in coords[1:] + [None]:
            if c is not None and c - prev == 1:
                prev = c
                continue
            yield [((k, fixed) if horizontal else (fixed, k))
                   for k in _span(start, prev)]
            if c is not None:
                start = prev = c


def _span(a, b):
    k = a
    while k <= b + 1e-9:
        yield k
        k += 1


def _run(name, cells, keys, direction=None) -> dict:
    rows = [cells[k] for k in keys]
    run = {"name": name, "from": [num(keys[0][0]), num(keys[0][1])]}
    if len(keys) > 1:
        run["to"] = [num(keys[-1][0]), num(keys[-1][1])]  # straight: len = |dx|+|dy|+1
    if direction is not None:
        run["dir"] = direction
    items = stock([i for r in rows for line in r.get("lines") or [] for i in
                   (line if isinstance(line, list) else [])])
    if items:
        run["items"] = items
    amounts = defaultdict(list)
    for r in rows:
        for f in r.get("fluids") or []:
            if isinstance(f, dict) and f.get("name"):
                amounts[f["name"]].append(float(f.get("amount", 0)))
    if amounts:
        run["fluid"] = " ".join(
            f"{n}:{num(min(a))}" + (f"..{num(max(a))}" if num(max(a)) != num(min(a)) else "")
            for n, a in sorted(amounts.items()))
    odd = sorted({r.get("status_name") for r in rows} - QUIET - {None})
    if odd:
        run["status"] = odd
    return run


def runs(rows: list[dict]) -> list[dict]:
    """Belts: same name+direction along their travel axis. Pipes: horizontal chains first,
    then vertical chains of what is left, singletons last."""
    out = []
    belts = defaultdict(dict)
    pipes = defaultdict(dict)
    for e in rows:
        key = (e["x"], e["y"])
        if e.get("type") == "transport-belt":
            belts[(e["name"], e.get("direction", 0))][key] = e
        else:
            pipes[e["name"]][key] = e
    for (name, d), cells in belts.items():
        for keys in _segments(cells, horizontal=d in (4, 12)):
            if d in (0, 12):
                keys = keys[::-1]  # from = upstream end (north/west travel toward smaller coords)
            out.append(_run(name, cells, keys, d))
    for name, cells in pipes.items():
        left = dict(cells)
        for horizontal in (True, False):
            for keys in list(_segments(left, horizontal)):
                if len(keys) > 1 or not horizontal:
                    out.append(_run(name, cells, keys))
                    for k in keys:
                        left.pop(k, None)
    out.sort(key=lambda r: (r["name"], r["from"][1], r["from"][0]))
    return out


TYPE_ORDER = ["boiler", "generator", "offshore-pump", "mining-drill", "furnace",
              "assembling-machine", "lab", "inserter", "splitter", "underground-belt",
              "pipe-to-ground", "container"]


def arrays(rows: list[dict]) -> list[dict]:
    """Identical rows (all fields but position) evenly spaced on one line -> one row with
    n + step. Geometry stays exact: i-th = at + i*step."""
    groups = defaultdict(list)
    for r in rows:
        key = tuple(sorted((k, str(v)) for k, v in r.items() if k != "at"))
        groups[key].append(r)
    out = []
    for members in groups.values():
        members.sort(key=lambda r: (r["at"][1], r["at"][0]))
        left = members
        for axis in (0, 1):  # rows along x first, then columns along y
            lines = defaultdict(list)
            for r in left:
                lines[r["at"][1 - axis]].append(r)
            left = []
            for line in lines.values():
                line.sort(key=lambda r: r["at"][axis])
                i = 0
                while i < len(line):
                    j = i + 1
                    step = line[j]["at"][axis] - line[i]["at"][axis] if j < len(line) else None
                    while j < len(line) and line[j]["at"][axis] - line[j - 1]["at"][axis] == step:
                        j += 1
                    if j - i >= 3 or (axis == 1 and j - i >= 2):
                        row = dict(line[i], n=j - i)
                        row["step"] = [num(step), 0] if axis == 0 else [0, num(step)]
                        out.append(row)
                    else:
                        left += line[i:j]
                    i = j
        out += left
    out.sort(key=lambda r: (r["at"][1], r["at"][0]))
    return out


NATURAL = {"tree": "trees", "simple-entity": "rocks", "cliff": "cliffs"}


def natural(summary) -> dict | None:
    """Trees/rocks -> counts only (the executor mines them off build tiles).
    Cliffs block building and need explosives -> [count, [x1,y1], [x2,y2]]."""
    out = {}
    for kind, s in sorted((summary or {}).items()):
        if not isinstance(s, dict) or not s.get("count") or kind not in NATURAL:
            continue
        key = NATURAL[kind]
        out[key] = s["count"] if key != "cliffs" else [
            s["count"], [num(s["x1"]), num(s["y1"])], [num(s["x2"]), num(s["y2"])]]
    return out or None


def ground(items) -> dict | None:
    """Loose item piles -> {name: [total, piles, [x1,y1](, [x2,y2])]}; box only when piles spread."""
    groups = defaultdict(list)
    for i in items or []:
        if isinstance(i, dict) and i.get("name") and "x" in i:
            groups[i["name"]].append(i)
    out = {}
    for name, piles in sorted(groups.items()):
        xs, ys = [p["x"] for p in piles], [p["y"] for p in piles]
        row = [sum(p.get("count", 1) for p in piles), len(piles), [num(min(xs)), num(min(ys))]]
        if (min(xs), min(ys)) != (max(xs), max(ys)):
            row.append([num(max(xs)), num(max(ys))])
        out[name] = row
    return out or None


def _by_name(rows: list[dict]) -> dict:
    out = defaultdict(list)
    for r in rows:
        r = dict(r)
        out[r.pop("name")].append(r)
    return dict(out)


def summarize(rows: list[dict]) -> dict:
    run_rows, machines, poles = [], [], defaultdict(list)
    for e in rows:
        if not isinstance(e, dict) or "x" not in e:
            continue
        t = e.get("type")
        if t in RUN_TYPES:
            run_rows.append(e)
        elif t in POLE_TYPES:
            poles[e["name"]].append([num(e["x"]), num(e["y"])])
        else:
            machines.append(e)
    rank = {t: i for i, t in enumerate(TYPE_ORDER)}
    machines.sort(key=lambda e: (rank.get(e.get("type"), len(rank)), e["name"], e["y"], e["x"]))
    compact = [machine(e) for e in machines]
    waiting = set(SHORT.values()) | WAITING
    issues = [m for m in compact if "status" in m and m["status"] not in waiting]
    rest = [m for m in compact if "status" not in m or m["status"] in waiting]
    runs_out = runs(run_rows)
    issues += [dict(r, kind="run") for r in runs_out if "status" in r]
    for name in poles:
        poles[name].sort(key=lambda p: (p[1], p[0]))
    ordered = {}
    for m in rest:  # keep TYPE_ORDER between names
        ordered.setdefault(m["name"], []).append(m)
    return {"issues": issues,
            "machines": {n: [{k: v for k, v in r.items() if k != "name"} for r in arrays(ms)]
                         for n, ms in ordered.items()},
            "runs": _by_name(r for r in runs_out if "status" not in r), "poles": dict(poles)}


# --- grid: one char per tile ------------------------------------------------------
# Coordinates read as lists cost the agent the most time on 23/09 (a 3-chem-sci block
# stalled on "which tiles are free"). A text map answers that at a glance.
ARROW = {0: "^", 4: ">", 8: "v", 12: "<"}
GRID_FIXED = {"electric-pole": "+", "pipe": "=", "pipe-to-ground": "~", "wall": "#",
              "gate": "#", "splitter": "$"}
# Letters the fixed symbols use; machine letters come from what is left.
RESERVED = set("^>v<+=~#$.*uUnesw") | set("NESW")
POOL = [c for c in "ABCDFGHIJKLMOPQRTVXYZabcdfghijklmopqrtxyz0123456789" if c not in RESERVED]
COMPASS = "nesw"


def _tiles(e: dict):
    """Integer tile corners covered by the entity's bounding box."""
    box = e.get("bounding_box")
    if not box:
        yield math.floor(e["x"]), math.floor(e["y"])
        return
    lt, rb = box["left_top"], box["right_bottom"]
    for tx in range(math.floor(lt["x"] + 0.01), math.ceil(rb["x"] - 0.01)):
        for ty in range(math.floor(lt["y"] + 0.01), math.ceil(rb["y"] - 0.01)):
            yield tx, ty


def _flow(e: dict):
    """Inserter drop side as n/e/s/w; long reach (>1.5 tiles) upper case."""
    drop = e.get("drop_position")
    if not isinstance(drop, dict):
        return "i"
    dx, dy = drop["x"] - e["x"], drop["y"] - e["y"]
    c = (("e" if dx > 0 else "w") if abs(dx) > abs(dy) else ("s" if dy > 0 else "n"))
    return c.upper() if max(abs(dx), abs(dy)) > 1.5 else c


def grid(rows: list[dict], cx: float, cy: float, radius: float, obstacles=()) -> dict:
    """Tile map around (cx,cy). rows = snapshot entities (need bounding_box).
    Row label = tile-center y; `ruler` digit = |tile-center x| mod 10."""
    x0, y0 = math.floor(cx - radius), math.floor(cy - radius)
    w = h = 2 * math.ceil(radius) + 1
    cells = [["."] * w for _ in range(h)]
    legend, letters = {}, {}

    def put(tx, ty, ch):
        i, j = tx - x0, ty - y0
        if 0 <= i < w and 0 <= j < h:
            cells[j][i] = ch

    for o in obstacles or ():
        if isinstance(o, dict) and "x" in o:
            for tx, ty in _tiles(o):
                put(tx, ty, "*")
    for e in rows:
        if not isinstance(e, dict) or "x" not in e:
            continue
        t, name = e.get("type"), e.get("name")
        if t == "transport-belt":
            ch = ARROW.get(e.get("direction", 0), "?")
        elif t == "underground-belt":
            ch = "u" if e.get("belt_to_ground_type") == "input" else "U"
        elif t == "inserter":
            ch = _flow(e)
        elif t in GRID_FIXED:
            ch = GRID_FIXED[t]
        else:
            key = name + (":" + e["recipe"] if e.get("recipe") else "")
            if key not in letters:
                letters[key] = POOL[len(letters) % len(POOL)]
                legend[letters[key]] = key
            ch = letters[key]
        for tx, ty in _tiles(e):
            put(tx, ty, ch)
    width = max(len(str(num(y0 + k + 0.5))) for k in range(h))
    lines = [str(num(y0 + j + 0.5)).rjust(width) + " " + "".join(r) for j, r in enumerate(cells)]
    ruler = " " * (width + 1) + "".join(str(int(abs(x0 + i + 0.5)) % 10) for i in range(w))
    return {"x0": num(x0 + 0.5), "y0": num(y0 + 0.5), "ruler": ruler, "rows": lines,
            "legend": legend,
            "key": "^>v< belt, u/U underground in/out, n/e/s/w inserter drop side "
                   "(caps=long), + pole, = pipe, ~ pipe-to-ground, $ splitter, # wall, "
                   "* tree/rock, . free"}
