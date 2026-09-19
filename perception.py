"""Compress raw snapshot rows into what an agent reads: issues first, machines, runs, poles.

Pure functions (no game I/O) so the Lua side stays a cheap fact dump.
Rule: compress repetition, never geometry -- every run keeps from/to/len/direction.
"""
from __future__ import annotations

from collections import defaultdict

RUN_TYPES = {"transport-belt", "pipe"}
POLE_TYPES = {"electric-pole"}
QUIET = {"working", "normal", None}
# Flow states: backpressure or idle between items. Shown on the row, not raised as issues.
WAITING = {"waiting_for_space_in_destination", "waiting_for_source_items", "full_output",
           "waiting_to_launch_rocket", "waiting_for_target_to_be_built"}
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
    if e.get("type") not in NO_DIRECTION and e.get("direction") is not None:
        row["dir"] = e["direction"]
    if e.get("status_name") not in QUIET:
        row["status"] = e["status_name"]
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
    run = {"name": name, "from": [num(keys[0][0]), num(keys[0][1])],
           "to": [num(keys[-1][0]), num(keys[-1][1])], "len": len(keys)}
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


def summarize(rows: list[dict]) -> dict:
    counts: dict[str, int] = defaultdict(int)
    run_rows, machines, poles = [], [], defaultdict(list)
    for e in rows:
        if not isinstance(e, dict) or "x" not in e:
            continue
        counts[e["name"]] += 1
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
    issues = [m for m in compact if m.get("status") not in WAITING and "status" in m]
    rest = [m for m in compact if m.get("status") in WAITING or "status" not in m]
    runs_out = runs(run_rows)
    issues += [dict(r, kind="run") for r in runs_out if "status" in r]
    for name in poles:
        poles[name].sort(key=lambda p: (p[1], p[0]))
    return {"counts": dict(sorted(counts.items())), "issues": issues, "machines": rest,
            "runs": [r for r in runs_out if "status" not in r], "poles": dict(poles)}
