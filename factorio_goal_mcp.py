"""Goal-level MCP surface over the existing Factorio bridge actions."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
from typing import Annotated

from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import Field, FiniteFloat

from bridge_client import invoke
from cells import cell
from chain import chain
from planner import live_spec, plan
from perception import grid, ground, lanes, natural, summarize
from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, request, self_sustaining
from blueprint_library import (encode_blueprint, import_reference, list_patterns,
                               load_pattern, pattern_entities, pattern_id_for,
                               record_blueprint)


READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
mcp = FastMCP(
    "factorio-engineer",
    instructions=(
        "Choose a production goal and call achieve once. The bridge reuses existing "
        "machines, checks real stock and geometry, builds a feasible pattern and "
        "audits in game. Use observe(patterns) and achieve(reuse_blueprint) for saved "
        "native blueprints; achieve(build_design) builds a layout the agent designed itself. Use report(job_id) for the outcome and observe for blockers. "
        "observe(plan) sizes a chain; build_design {cell:recipe} lays one machine row between "
        "belts, {chain:item@N/min} stacks cells and routes their belts; both return ports "
        "(external inputs to feed, output). Design rows are entity centers. Goal details: CONTRACT.md. "
        "Detailed actions remain in the CLI for diagnosis. Never spawn free items."
    ),
    log_level="WARNING",
)


def _read(result: CallToolResult) -> dict:
    return json.loads(result.content[0].text)


def _result(data: dict, error: bool = False) -> CallToolResult:
    return CallToolResult(
        isError=error,
        content=[TextContent(type="text", text=json.dumps(data, ensure_ascii=False, separators=(",", ":")))],
    )


def _send(body: dict, timeout: float) -> CallToolResult:
    try:
        p = request(body, host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                    port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=timeout)
    except (OSError, ValueError, TimeoutError) as exc:
        return _result({"ok": False, "error": str(exc)}, True)
    p.pop("nonce", None)
    p.pop("v", None)
    return _result(p, not p.get("ok", False))


SPEC_CACHE: dict[str, dict] = {}  # per build_design call; cleared there (research unlocks machines)


def _plan(query: str | None) -> dict:
    """item@rate/min[;recipe=item:name,...] -> planner.plan() over live read-only spec."""
    target, separator, rest = (query or "").partition("@")
    rate_text, *options = rest.split(";")
    value, unit_separator, unit = rate_text.partition("/")
    if not target or not separator or unit_separator != "/" or unit != "min":
        raise ValueError("plan-query=item@rate/min[;recipe=item:name,...]")
    overrides = {}
    for option in options:
        if not option.startswith("recipe="):
            raise ValueError("plan-option-must-be-recipe=item:name,...")
        for pair in option[7:].split(","):
            product, colon, recipe = pair.partition(":")
            if not colon or not product or not recipe:
                raise ValueError("plan-recipe-option=item:name")
            overrides[product] = recipe
    return plan(live_spec(target, overrides), target, float(value), recipes=overrides)


def _chain_rows(row: dict) -> tuple[list[dict], dict]:
    """Expand {chain:item@rate/min,x,y}: plan, stack cells, route every internal edge."""
    surface = row.get("surface", "nauvis")

    def route(frm, to, end_dir, avoid, planned):
        p = request({"action": "route", "surface": surface, "from": {"x": frm[0], "y": frm[1]},
                     "to": {"x": to[0], "y": to[1]}, "end_dir": end_dir, "avoid": avoid,
                     "planned_belts": planned},
                    host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                    port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=60)
        if not p.get("ok"):
            raise ValueError(f"chain-route:{p.get('error')}:{frm}->{to}")
        return p["design"]

    return chain(_plan(row["chain"]),
                 lambda recipe, count, cx, cy: _cell_rows({"cell": recipe, "count": count,
                                                          "x": cx, "y": cy}),
                 route, int(row["x"]), int(row["y"]))


def _power_rows(rows: list[dict], boxes: list, surface: str, pole: str,
                free=()) -> list[dict]:
    """Pole line from the nearest box edge to the nearest existing pole (row `power:true`).
    Path = the belt router's A* over free tiles; a pole every <=7 tiles of it. Whether that
    pole is LIVE is the executor's power check (`unpowered` in the reply), not this one."""
    reach = 7  # ponytail: small pole wire 7.5; bigger poles just get denser lines
    own = {(r["x"], r["y"]) for r in rows}
    x1, y1 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x2, y2 = max(b[2] for b in boxes), max(b[3] for b in boxes)
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    err, _, found, *_ = _pull(surface, cx, cy, 64)
    if err:
        raise ValueError(f"power-scan:{err.get('error')}")
    poles = [e for e in found if ("electric-pole" in e["name"] or "substation" in e["name"])
             and (e["x"], e["y"]) not in own]
    if not poles:
        raise ValueError("power-no-pole-within-64")

    def gap(e):  # distance from the layout bbox to a pole
        return math.hypot(max(x1 - e["x"], 0, e["x"] - x2), max(y1 - e["y"], 0, e["y"] - y2))
    to = min(poles, key=gap)
    if gap(to) <= reach - 3:  # a cell pole sits <=3 tiles inside the box edge
        return []
    # Start on the free tile just outside the box, facing the target pole.
    sx = min(max(to["x"], x1 + 0.5), x2 - 0.5)
    sy = min(max(to["y"], y1 + 0.5), y2 - 0.5)
    if to["x"] < x1: sx = x1 - 0.5
    elif to["x"] > x2: sx = x2 + 0.5
    elif to["y"] < y1: sy = y1 - 0.5
    else: sy = y2 + 0.5
    ends = [(to["x"] + dx, to["y"] + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
    ends.sort(key=lambda t: math.hypot(t[0] - sx, t[1] - sy))
    belts = [[r["x"], r["y"], r["direction"]] for r in rows if "belt" in r["name"]]
    keep = [(b[0], b[1]) for b in belts] + list(free)  # external feed tiles stay open
    last = None
    for ex, ey in ends:
        p = request({"action": "route", "surface": surface, "from": {"x": sx, "y": sy},
                     "to": {"x": ex, "y": ey}, "planned_belts": belts,
                     "avoid": boxes + [[kx - .5, ky - .5, kx + .5, ky + .5] for kx, ky in keep]},
                    host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                    port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=60)
        if p.get("ok"):
            break
        last = p.get("error")
    else:
        raise ValueError(f"power-route:{last}")
    path = [(r["x"], r["y"]) for r in p["design"]]
    out, at = [], (sx, sy)
    out.append(at)
    for prev, nxt in zip(path, path[1:]):
        if math.hypot(nxt[0] - at[0], nxt[1] - at[1]) > reach:
            at = prev
            out.append(at)
    if math.hypot(to["x"] - at[0], to["y"] - at[1]) > reach:
        out.append(path[-1])
    return [{"name": pole, "x": px, "y": py, "direction": 0} for px, py in dict.fromkeys(out)]


def _cell_rows(row: dict) -> tuple[list[dict], dict]:
    """Expand {cell:recipe,x,y,count?,machine?,belt?,inserter?} via read-only spec calls."""
    def ask(body):
        key = json.dumps(body, sort_keys=True)
        if key not in SPEC_CACHE:
            SPEC_CACHE[key] = request({"action": "spec", **body},
                                      host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                                      port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)))
        return SPEC_CACHE[key]
    recipe = ask({"kind": "recipe", "name": row["cell"]})
    if not recipe.get("ok"):
        raise ValueError(f"cell-recipe:{recipe.get('error')}")
    machine = row.get("machine")
    if not machine:
        # Same rule as planner._cost: fewest ingredients among UNLOCKED machines
        # (first live try picked a locked assembling-machine-3).
        costs = {}
        for m in recipe.get("machines") or []:
            r = ask({"kind": "recipe", "name": m})
            costs[m] = (sum(i["amount"] for i in r.get("ingredients") or []) or float("inf")
                        if r.get("ok") and r.get("enabled") else float("inf"))
        if not costs:
            raise ValueError(f"cell-no-machine:{row['cell']}")
        machine = min(sorted(costs), key=costs.get)
    size = ask({"kind": "entity", "name": machine})
    if not size.get("ok"):
        raise ValueError(f"cell-machine:{size.get('error')}")
    extra = {k: row[k] for k in ("belt", "inserter", "long_inserter", "pole", "fuel") if k in row}
    if size.get("burner_effectivity"):
        extra.setdefault("fuel", "coal")
    rows, ports = cell(row["cell"], recipe.get("ingredients") or [], recipe.get("products") or [],
                       machine, size["tile_width"], size["tile_height"], int(row.get("count", 1)),
                       int(row["x"]), int(row["y"]), **extra)
    if size.get("entity_type") == "furnace":
        # A furnace picks its recipe from the input; a ghost refuses `recipe` on it.
        for r in rows:
            r.pop("recipe", None)
    return rows, ports


HAND = {"craft": 15.0, "collect": 10.0, "insert": 10.0}


def _hand(goal: str, rows, surface: str, force: str, x, y) -> CallToolResult:
    """craft / collect / insert, one design row per item.

    The bridge has had these three handlers since the CLI days; what was missing was an
    MCP door to them, and maintainer's 20/09 rule is MCP-only, so without one the agent cannot
    feed a furnace. They reuse `design` instead of adding `recipe`/`item`/`count`/`source`
    parameters because the three tools' schemas have ~18 bytes of headroom under the
    4000-byte budget. A row is {name, count, x?, y?, source?}; x/y fall back to the call's
    own x/y, and `craft` ignores them. craft only STARTS the hand-craft queue -- the items
    land in the bag over the following ticks, so read them back with observe.
    """
    if not isinstance(rows, list) or not rows:
        return _result({"ok": False, "error": "design-rows-required"}, True)
    if len(rows) > 8:
        return _result({"ok": False, "error": "too-many-rows"}, True)
    key = "recipe" if goal == "craft" else "item"
    out, every = [], True
    for i, row in enumerate(rows):
        name = row.get("name") if isinstance(row, dict) else None
        count = row.get("count", 1) if isinstance(row, dict) else 0
        if not isinstance(name, str) or not name or not isinstance(count, int) or count < 1:
            return _result({"ok": False, "error": "invalid-design-entity:%d" % i}, True)
        body = {"action": goal, key: name, "count": count, "surface": surface}
        if goal != "craft":
            row_x, row_y = row.get("x", x), row.get("y", y)
            if row_x is None or row_y is None:
                return _result({"ok": False, "error": "coordinate-pairs-required:%d" % i}, True)
            body.update(x=float(row_x), y=float(row_y))
        if goal == "insert":
            body["force"] = force
            if row.get("source"):
                body["source"] = True
        try:
            p = request(body, host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                        port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)),
                        timeout=HAND[goal])
        except (OSError, ValueError, TimeoutError) as exc:
            p = {"ok": False, "error": str(exc)}
        every = every and bool(p.get("ok"))
        # Every row carries a treasury dump otherwise; 8 of those is the reply, not the news.
        out.append({"name": name, "ok": bool(p.get("ok")),
                    **_fields(p, "error", "count", "requested", "slot", "remaining",
                              "source_remaining", "player_total", "have", "need",
                              "craftable")})
    return _result({"ok": every, "goal": goal, "rows": out}, not every)


RECALL_SLICE = 64


def _slices(lo: float, hi: float) -> list:
    """Cuts covering [lo, hi), each shorter than the Lua handler's 64-tile cap."""
    out, v = [], lo
    while v < hi:
        n = min(v + RECALL_SLICE, hi)
        out.append((v, n))
        v = n
    return out


def _trim_rows(res: CallToolResult) -> CallToolResult:
    """23/09 a 50-tile belt recall printed 50 receipts; `delta` already sums them."""
    p = _read(res)
    for key in ("receipts", "entities"):
        rows = p.get(key)
        if isinstance(rows, list) and len(rows) > 8:
            p[key], p[key + "_total"] = rows[:3], len(rows)
    return _result(p, not p.get("ok", False))


def _recall_area(body: dict, area: list) -> CallToolResult:
    """Recall a box of any size by slicing it into pieces the bridge accepts.

    field.lua caps one recall at 64x64 tiles and 200 entities on purpose: it is the
    safety net against an accidental base-wide recall, so the cap stays where it is and
    the slicing happens here. A long pipe or belt run is one agent intent, not twelve.
    Entities straddling a cut are returned by both slices, so rows are deduped by
    name+position; in a real run the first slice already mined them, so only a dry_run
    can actually see the duplicate.
    """
    pieces = [(x1, y1, x2, y2)
              for x1, x2 in _slices(area[0], area[2])
              for y1, y2 in _slices(area[1], area[3])]
    if len(pieces) == 1:
        body.update(x1=area[0], y1=area[1], x2=area[2], y2=area[3])
        return _send(body, 15)
    rows, receipts, seen = [], [], set()
    delta, spilled, done = {}, {}, 0
    for i, (x1, y1, x2, y2) in enumerate(pieces):
        part = _read(_send({**body, "x1": x1, "y1": y1, "x2": x2, "y2": y2}, 15))
        if not part.get("ok"):
            # "nothing-to-recall" is the normal answer for an empty slice.
            if part.get("error") == "nothing-to-recall":
                continue
            return _result({"ok": False, "error": part.get("error"), "slice": [x1, y1, x2, y2],
                            "slices": len(pieces), "slices_done": done,
                            "count": len(receipts) or len(rows),
                            "receipts": receipts or None, "entities": rows or None,
                            "delta": delta or None}, True)
        done += 1
        for row in part.get("entities") or []:
            key = (row["name"], row["x"], row["y"])
            if key not in seen:
                seen.add(key)
                rows.append(row)
        for row in part.get("receipts") or []:
            key = (row["name"], row["x"], row["y"])
            if key not in seen:
                seen.add(key)
                receipts.append(row)
        for name, n in (part.get("delta") or {}).items():
            delta[name] = delta.get(name, 0) + n
        for name, n in (part.get("spilled") or {}).items():
            spilled[name] = spilled.get(name, 0) + n
    out = {"ok": True, "action": "recall", "slices": len(pieces), "slices_done": done,
           "state": "planned" if body.get("dry_run") else "done"}
    if body.get("dry_run"):
        out.update(entities=rows, count=len(rows))
    else:
        out.update(receipts=receipts, count=len(receipts), delta=delta)
        if spilled:
            out["spilled"] = spilled
    return _result(out)


def _digest(rows: list) -> dict:
    """Same shape a build reply's `plan` uses: count, per-name tally, bbox.

    A 500-entity layout is ~15k chars of rows nobody reads in chat; the catalog file
    on disk keeps every row (`blueprint_library.pattern_entities`), so nothing is lost.
    No `detail` flag: the tool schema is ~4 bytes under its 4000-byte budget.
    """
    names: dict = {}
    box = None
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = row.get("name", "unknown")
        names[name] = names.get(name, 0) + 1
        x, y = row.get("x"), row.get("y")
        if x is None or y is None:
            continue
        box = ([x, y, x, y] if box is None else
               [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)])
    return {"count": len(rows), "entities": names, "bbox": box}


ROUTES: dict[str, list[dict]] = {}  # ponytail: in-memory, lost on MCP restart; re-run observe(route)
_ARROW = {0: "^", 4: ">", 8: "v", 12: "<"}


def _route_runs(design: list[dict]) -> list[str]:
    """Compact path: straight belt runs 'x1,y1..x2,y2 >' and 'ug x,y>x,y'."""
    out, run = [], None
    for e in design:
        if e.get("type") == "input" or e.get("ug") == "in":
            ug_in = e
            continue
        if e.get("type") == "output" or e.get("ug") == "out":
            run = None
            out.append(f"ug {ug_in['x']},{ug_in['y']}>{e['x']},{e['y']} {_ARROW[e['direction']]}")
            continue
        e = {**e, "direction": e.get("d", e["direction"])}  # pipe rows carry travel dir in d
        if run and run[2] == e["direction"]:
            run[1] = e
            out[-1] = f"{run[0]['x']},{run[0]['y']}..{e['x']},{e['y']} {_ARROW[e['direction']]}"
        else:
            run = [e, e, e["direction"]]
            out.append(f"{e['x']},{e['y']} {_ARROW[e['direction']]}")
    return out


def _fields(source: dict, *names: str) -> dict:
    return {name: source[name] for name in names if name in source}


@mcp.tool(annotations=READ)
def observe(view: str = "situation",
            surface: str = "nauvis", x: FiniteFloat | None = None,
            y: FiniteFloat | None = None,
            radius: Annotated[float, Field(ge=1, le=2048, allow_inf_nan=False)] = 16,
            resource: str | None = None, pattern_id: str | None = None,
            query: str | None = None,
            offset: Annotated[int, Field(ge=0)] = 0) -> CallToolResult:
    """situation|deposits|nearby|grid|lanes|water|research|patterns|references
|entities(query=name)|flow(query=a,b@10m)|ledger(query=id|status:|cluster:|item:)
|supply(query=item)|route(x,y;query=tx,ty[,dir][,sDIR][,belt|pipe])
|plan(query=item@rate/min[;recipe=item:name,...]); offset paging; r<=32"""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "x-and-y-required-together"}, True)
    if view not in {"situation", "deposits", "nearby", "entities", "patterns", "references",
                    "water", "research", "ledger", "grid", "flow", "lanes", "supply", "route", "plan"}:
        return _result({"ok": False, "error": "unknown-view"}, True)
    if view == "plan":
        try:
            return _result({"ok": True, "view": view, **_plan(query)})
        except (OSError, ValueError, TimeoutError) as exc:
            return _result({"ok": False, "view": view, "error": str(exc)}, True)
    if view == "ledger":
        # Default is the roll-up: the whole base in a fixed number of bytes. A filter or a
        # block id is what opens rows; nothing returns every block at full detail any more.
        body = {"action": "ledger", "detail": "roll", "offset": offset}
        q = (query or "").strip()
        if q:
            key, _, value = q.partition(":")
            if not value:
                body.update(detail="one", only={"id": key})
            elif key in LEDGER_FILTERS:
                body.update(detail="rows", only={key: value})
            else:
                return _result({"ok": False, "error": "ledger-query-is-exec-N-or-"
                                + "|".join(sorted(LEDGER_FILTERS)) + ":value"}, True)
        return _send(body, 5)
    if view == "research":
        return _send({"action": "research", "surface": surface, "available": True}, 5)
    if view == "flow":
        items, _, window = (query or "").partition("@")
        return _send({"action": "flow", "surface": surface, "window": window or "10m",
                      "items": [i.strip() for i in items.split(",") if i.strip()] or None}, 5)
    if view == "supply":
        # One call for "where is X, how much spare": replaces a dozen nearby/lanes probes.
        item = (query or "").strip()
        p = _read(_send({"action": "supply", "surface": surface, "item": item}, 30))
        if not p.get("ok", False):
            return _result(p, True)
        f = _read(_send({"action": "flow", "surface": surface, "window": "10m",
                         "items": [item]}, 5))
        rows = [{"type": "transport-belt", "x": bx, "y": by, "direction": d,
                 "lines": [[{"name": item, "count": c1}] if c1 else [],
                           [{"name": item, "count": c2}] if c2 else []]}
                for bx, by, d, c1, c2 in p.get("belts") or []]
        return _result({"ok": True, "view": view, "item": item,
                        "flow_10m": (f.get("rows") or [None])[0],
                        # Lua serialises an empty table as {}; keep lists lists
                        **{k: p.get(k) or [] for k in ("makers", "users", "chests")},
                        **_fields(p, "stored", "belt_tiles"),
                        # ponytail: first 40 runs; iron-plate can have hundreds, add paging if needed
                        "runs": (r := lanes(rows))[:40], "run_total": len(r)})
    if view == "route":
        # Belt path finder: 23/09 three long feeds each cost several grid scans and hand
        # routing. Lua plans; the design is parked here and built by reference so a
        # 130-tile belt never travels through the conversation twice.
        parts = [q.strip() for q in (query or "").split(",")]
        if x is None or len(parts) < 2:
            return _result({"ok": False, "error": "route-needs-x-y-and-query-tx,ty[,end_dir][,belt]"}, True)
        try:
            body = {"action": "route", "surface": surface, "from": {"x": x, "y": y},
                    "to": {"x": float(parts[0]), "y": float(parts[1])}}
        except ValueError:
            return _result({"ok": False, "error": "route-query-tx,ty-numbers"}, True)
        for extra in parts[2:]:
            if extra.lstrip("-").isdigit():
                body["end_dir"] = int(extra)
            elif extra[:1] == "s" and extra[1:].isdigit():
                # First tile's facing: fixes which lane a side-on source inserter fills.
                body["start_dir"] = int(extra[1:])
            elif extra:
                body["belt"] = extra
        p = _read(_send(body, 60))
        if not p.get("ok", False):
            return _result(p, True)
        rid = f"route-{len(ROUTES) + 1}"
        ROUTES[rid] = p["design"]
        return _result({"ok": True, "view": view, "route_id": rid,
                        **_fields(p, "belts", "underground_pairs", "cost"),
                        "path": _route_runs(p["design"])})
    if view == "water":
        body = {"action": "water_sites", "surface": surface, "radius": max(radius, 8), "offset": offset}
        if x is not None:
            body.update(x=x, y=y)
        return _send(body, 60)
    if radius > 32:
        return _result({"ok": False, "error": "radius-over-32-only-for-water"}, True)
    if view == "patterns" and pattern_id:
        try:
            pattern = load_pattern(pattern_id)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        # Headline digest + ONE page of rows. A 533-entity reference used to arrive as
        # 533 rows; the rows still have to be reachable, because reading a pattern,
        # editing it and re-submitting it as `build_design` is the only way an agent
        # derives a layout from an existing one. `offset` pages them like references.
        rows = pattern_entities(pattern["blueprint_string"])
        page = rows[offset:offset + PATTERN_PAGE]
        return _result({"ok": True, "view": view, "pattern_id": pattern_id,
                        "state": pattern.get("state"), "contract": pattern.get("contract"),
                        "layout": _digest(rows), "entities": page,
                        "entities_offset": offset,
                        "entities_next_offset": (offset + len(page)
                                                 if offset + len(page) < len(rows) else None)})
    if view in {"patterns", "references"}:
        return _result({"ok": True, "view": view,
                        **list_patterns(reference=view == "references", query=query,
                                        offset=offset)})
    if view == "situation":
        p = _read(invoke("brief", surface=surface, x=x, y=y, radius=radius))
        return _result({"ok": p.get("ok", False), "view": view, **_fields(p,
            "center", "counts", "ghost_total", "ghost_counts", "ghost_box",
            "issue_total", "issues", "enemy_total",
            "nearest_enemies", "ore_total", "ore_patches", "treasury", "error")},
            not p.get("ok", False))
    if view == "deposits":
        p = _read(invoke("ore-marks", surface=surface, name=resource, offset=offset, limit=12))
        return _result({"ok": p.get("ok", False), "view": view,
                        **_fields(p, "total", "marks", "next_offset", "error")},
                       not p.get("ok", False))
    if view == "nearby":
        return _nearby(surface, x, y, radius)
    if view == "grid":
        return _grid(surface, x, y, radius)
    if view == "lanes":
        err, head, rows, _, _, more = _pull(surface, x, y, radius)
        if err:
            return _result({"ok": False, "view": view, **_fields(err, "error")}, True)
        return _result({"ok": True, "view": view, "runs": lanes(rows),
                        **({"truncated_at": len(rows)} if more is not None else {})})
    # entities: full rows, but a belt tile is geometry grid/nearby already show, and on
    # 23/09 half of every 12-row page was identical copper-belt tiles. query = name filter.
    err, head, rows, ghosts, _, more = _pull(surface, x, y, radius)
    if err:
        return _result({"ok": False, "view": view, **_fields(err, "error")}, True)
    q = (query or "").strip()
    keep = ([e for e in rows if q in e.get("name", "") or q == e.get("type")] if q
            else [e for e in rows if e.get("type") != "transport-belt"])
    page = keep[offset:offset + ENTITY_PAGE]
    entities = [_fields(e, "name", "type", "x", "y", "direction", "status_name", "recipe",
                        "fuel", "input", "output", "fluids", "lines", "belt_to_ground_type")
                for e in page]
    return _result({"ok": True, "view": view, **_fields(head, "center", "ground_items"),
                    "entities_total": len(keep),
                    **({"belts_hidden": len(rows) - len(keep)} if not q else {}),
                    **({"truncated_at": len(rows)} if more is not None else {}),
                    "entities_next_offset": (offset + len(page)
                                             if offset + len(page) < len(keep) else None),
                    **({"ghosts": _digest(ghosts)} if ghosts else {}),
                    "entities": entities})


LEDGER_FILTERS = {"status", "cluster", "item"}
PATTERN_PAGE = 40  # layout rows per observe(patterns, pattern_id) page
NEARBY_MAX_PAGES = 16  # x64 rows per Lua page
ENTITY_PAGE = 16  # full rows per observe(entities) page


def _pull(surface, x, y, radius, obstacles=False):
    """Every snapshot page (Lua stays a cheap fact dump). -> (error|None, head, rows, ghosts, natural, more)."""
    rows, ghosts, natural_rows, offset, head = [], [], [], 0, None
    for _ in range(NEARBY_MAX_PAGES):
        p = _read(invoke("snapshot", surface=surface, x=x, y=y, radius=radius,
                         offset=offset, limit=64, tiles=False, name=None,
                         obstacles=obstacles or offset == 0))
        if not p.get("ok", False):
            return p, None, [], [], [], None
        head = head or p
        rows += [e for e in p.get("entities") or [] if isinstance(e, dict)]
        ghosts += [g for g in p.get("ghosts") or [] if isinstance(g, dict)]
        natural_rows += [o for o in p.get("obstacles") or [] if isinstance(o, dict)]
        # The lists share one offset but not one length: keep paging while ANY has more,
        # or a field of ghosts hides behind a short entity list.
        nxt = [v for v in (p.get("entities_next_offset"), p.get("ghosts_next_offset"),
                           p.get("obstacles_next_offset") if obstacles else None) if v is not None]
        offset = max(nxt) if nxt else None
        if offset is None:
            break
    return None, head, rows, ghosts, natural_rows, offset


def _nearby(surface, x, y, radius) -> CallToolResult:
    """Pull every snapshot page, then compress in Python (Lua stays a cheap fact dump)."""
    err, head, rows, ghosts, _, offset = _pull(surface, x, y, radius)
    if err:
        return _result({"ok": False, "view": "nearby", **_fields(err, "error")}, True)
    data = {"ok": True, "view": "nearby", **_fields(head, "center", "entities_total"),
            **summarize(rows)}
    if ghosts:
        data["ghosts"] = _digest(ghosts)
    if offset is not None:
        data["truncated_at"] = len(rows)
    data["resources"] = [[r.get("name"), r.get("x"), r.get("y"), r.get("amount")]
                         for r in head.get("resources") or [] if isinstance(r, dict)]
    for key, value in (("obstacles", natural(head.get("obstacle_summary"))),
                       ("ground_items", ground(head.get("ground_items")))):
        if value:
            data[key] = value
    return _result(data)


def _grid(surface, x, y, radius) -> CallToolResult:
    err, head, rows, ghosts, obstacles, offset = _pull(surface, x, y, radius, obstacles=True)
    if err:
        return _result({"ok": False, "view": "grid", **_fields(err, "error")}, True)
    c = head.get("center") or {"x": x or 0, "y": y or 0}
    data = {"ok": True, "view": "grid", **grid(rows, c["x"], c["y"], radius, obstacles)}
    if ghosts:
        data["ghosts"] = _digest(ghosts)  # plans, not drawn: a ghost tile is not free
    if offset is not None:
        data["truncated_at"] = len(rows)
    return _result(data)


def _set_recipe(design, surface: str, force: str) -> CallToolResult:
    """Commission empty assemblers. One call per machine so a bad target names itself.

    The Lua handler refuses a machine that already holds a recipe or items, so this is
    not a re-configure: it only fills in what the blueprint left blank.
    """
    if not design:
        return _result({"ok": False, "error": "design-required"}, True)
    done, failed = [], []
    for t in design:
        name = t.get("recipe")
        if not name or t.get("x") is None or t.get("y") is None:
            failed.append({"x": t.get("x"), "y": t.get("y"), "error": "recipe-and-xy-required"})
            continue
        p = _read(_send({"action": "set_recipe", "recipe": name, "x": t["x"], "y": t["y"],
                         "surface": surface, "force": force}, 5))
        row = {"x": t["x"], "y": t["y"], "recipe": name}
        if p.get("ok"):
            done.append(row | {"unchanged": bool(p.get("unchanged"))})
        else:
            failed.append(row | {"error": p.get("error"), "current": p.get("current")})
    return _result({"ok": not failed, "goal": "set_recipe",
                    "set": done, "failed": failed}, bool(failed))


@mcp.tool(annotations=WRITE)
def achieve(goal: str,
            x: FiniteFloat | None = None, y: FiniteFloat | None = None,
            radius: Annotated[float, Field(ge=4, le=256, allow_inf_nan=False)] = 192,
            surface: str = "nauvis", force: str = "player",
            dry_run: bool = False, pattern_id: str | None = None,
            contract: dict | None = None, design: list[dict] | None = None,
            area: list[float] | None = None, force_active: bool = False,
            tech: str | None = None) -> CallToolResult:
    """area=x1,y1,x2,y2. reuse_blueprint(pattern_id)
build_design(design=[{name,x,y,direction?,recipe?,filter?,output_priority?}|{file:json}|{route:id}|{cell:recipe|chain:item@N/min,x,y,count?}]; dir 0N4E8S12W)
recall(area|design) capture|build_ghosts(area) drop_ghosts(pattern_id=exec-N)
research(tech|a,b) annotate(contract.block) set_recipe(design=[{x,y,recipe}])
craft|collect|insert(design=[{name,count,x?,y?,source?}]<=8) import(pattern_id=bp) launch(x,y)"""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "coordinate-pairs-required"}, True)
    if goal not in {"reuse_blueprint", "build_design", "recall", "capture", "research",
                    "annotate", "set_recipe", "craft", "collect", "insert", "import",
                    "build_ghosts", "drop_ghosts", "launch"}:
        return _result({"ok": False, "error": "unknown-goal"}, True)
    if (tech is not None) != (goal == "research"):
        return _result({"ok": False, "error": "tech-only-for-research"}, True)
    if goal == "import":
        # A blueprint string a human pasted has no other way in: the catalog only ever
        # grew from `capture`. It lands as a REFERENCE (no contract, never auto-built),
        # the same door `import_reference` already gives the CLI. `pattern_id` carries the
        # string rather than a new parameter: the three schemas have 26 bytes of headroom.
        if not pattern_id:
            return _result({"ok": False, "error": "pattern_id-carries-the-blueprint-string"},
                           True)
        try:
            saved = import_reference(pattern_id, note=(contract or {}).get("note"))
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        return _result({"ok": True, "goal": goal,
                        **{k: saved[k] for k in ("pattern_id", "state", "entity_count",
                                                 "over_build_limit") if k in saved},
                        "layout": _digest(pattern_entities(pattern_id))})
    if goal == "launch":
        if x is None:
            return _result({"ok": False, "error": "coordinate-pairs-required"}, True)
        return _send({"action": "launch", "x": x, "y": y, "surface": surface}, 5)
    if goal == "set_recipe":
        return _set_recipe(design, surface, force)
    if goal in HAND:
        return _hand(goal, design, surface, force, x, y)
    if goal == "research":
        if "," in tech:
            return _send({"action": "research", "backlog": [t.strip() for t in tech.split(",") if t.strip()],
                          "force": force, "surface": surface}, 5)
        return _send({"action": "research", "name": tech, "start": True, "force": force,
                      "surface": surface}, 5)
    if goal == "annotate":
        body = {"action": "ledger_note", "block": (contract or {}).get("block"),
                "surface": surface, "force": force}
        if area is not None:
            if len(area) != 4:
                return _result({"ok": False, "error": "area-is-x1-y1-x2-y2"}, True)
            body.update(x1=area[0], y1=area[1], x2=area[2], y2=area[3])
        return _send(body, 5)
    if goal == "capture":
        if area is None or len(area) != 4:
            return _result({"ok": False, "error": "area-is-x1-y1-x2-y2"}, True)
        try:
            p = request({"action": "blueprint_export", "surface": surface, "force": force,
                         "x1": area[0], "y1": area[1], "x2": area[2], "y2": area[3]},
                        host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                        port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=5)
            if not p.get("ok"):
                return _result({"ok": False, **_fields(p, "error", "entities")}, True)
            saved = record_blueprint(p["blueprint"], state="captured", source="capture",
                                     contract=contract)
        except (OSError, ValueError, KeyError, TimeoutError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        # `site` is the anchor to hand straight back to reuse_blueprint with
        # site.mode="exact". Without it the caller had to guess the frame from a
        # centre-based bbox, and a 3x3 drill and a 2x2 furnace floor to different tiles.
        return _result({"ok": True, "goal": goal, **saved,
                        **({"site": p["anchor"]} if p.get("anchor") else {}),
                        "layout": _digest(pattern_entities(p["blueprint"]))})
    if goal == "drop_ghosts":
        # A job id rides in pattern_id, the same way `import` carries its string: the three
        # schemas have no room for another parameter.
        if not (pattern_id or "").startswith("exec-"):
            return _result({"ok": False, "error": "pattern_id-carries-the-job-id"}, True)
        return _send({"action": "drop_ghosts", "job_id": pattern_id, "dry_run": dry_run}, 10)
    if goal == "build_ghosts":
        # Ghosts a human pasted had no goal that would build them. The workaround was
        # capture -> reuse_blueprint, which re-derived the frame and (21/09, exec-21..24)
        # laid a SECOND ghost set one tile off the first. Here the frame is never
        # re-derived: the export hands back the exact anchor of the entities it captured,
        # so every layout row lands on the ghost that is already there and drain() adopts
        # it instead of creating one.
        if area is None or len(area) != 4:
            return _result({"ok": False, "error": "area-is-x1-y1-x2-y2"}, True)
        try:
            p = request({"action": "blueprint_export", "surface": surface, "force": force,
                         "x1": area[0], "y1": area[1], "x2": area[2], "y2": area[3]},
                        host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                        port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=5)
            if not p.get("ok"):
                return _result({"ok": False, **_fields(p, "error", "entities")}, True)
            if not p.get("anchor"):
                return _result({"ok": False, "error": "no-anchor-in-export"}, True)
            saved = record_blueprint(p["blueprint"], state="captured", source="build_ghosts",
                                     contract=contract)
        except (OSError, ValueError, KeyError, TimeoutError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        deal = dict(contract or {})
        deal["site"] = {"mode": "exact"}
        # Keep the caller's build options (skip_locked); only the mode is forced.
        deal["build"] = {**(deal.get("build") or {}), "mode": "ghost"}
        body = {"action": "blueprint_run", "blueprint": p["blueprint"],
                "pattern_id": saved["pattern_id"], "contract": deal, "surface": surface,
                "force": force, "radius": radius, "dry_run": dry_run,
                "x": p["anchor"]["x"], "y": p["anchor"]["y"]}
        try:
            run = request(body, host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                          port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=15)
        except (OSError, ValueError, TimeoutError) as exc:
            return _result({"ok": False, "error": str(exc),
                            "pattern_id": saved["pattern_id"]}, True)
        return _result({"ok": run.get("ok", False), "goal": goal,
                        "pattern_id": saved["pattern_id"], "site_requested": p["anchor"],
                        "ghosts_captured": p.get("entities"),
                        **_fields(run, "job_id", "state", "site", "site_validated",
                                  "materials", "missing", "locked", "skipped_locked", "bots", "uncovered", "steps", "rejects",
                                  "checks", "unconnected", "plan", "error")},
                       not run.get("ok", False))
    if goal == "recall":
        if pattern_id or contract or x is not None:
            return _result({"ok": False, "error": "recall-takes-area-or-design-only"}, True)
        body = {"action": "recall", "surface": surface, "force": force,
                "dry_run": dry_run, "force_active": force_active}
        if area is not None:
            if len(area) != 4:
                return _result({"ok": False, "error": "area-is-x1-y1-x2-y2"}, True)
            if not (area[0] < area[2] and area[1] < area[3]):
                return _result({"ok": False, "error": "area-is-x1-y1-x2-y2"}, True)
            return _trim_rows(_recall_area(body, area))
        elif design:
            body["entities"] = design
        else:
            return _result({"ok": False, "error": "area-or-design-required"}, True)
        return _trim_rows(_send(body, 15))
    if area is not None or force_active:
        return _result({"ok": False, "error": "area-only-for-recall-capture-build-ghosts"},
                       True)
    if (design is not None) != (goal == "build_design"):
        return _result({"ok": False, "error": "design-only-for-build-design"}, True)
    if goal == "build_design":
        if pattern_id is not None:
            return _result({"ok": False, "error": "design-takes-no-pattern-id"}, True)
        expanded, ports = [], []
        SPEC_CACHE.clear()
        for row in design:
            if "cell" in row or "chain" in row:
                try:
                    rows, port = _cell_rows(row) if "cell" in row else _chain_rows(row)
                except (OSError, ValueError, KeyError, TimeoutError) as exc:
                    return _result({"ok": False, "error": str(exc)}, True)
                if row.get("power"):
                    boxes = [c["box"] for c in port["cells"]] if "cells" in port else [port["box"]]
                    try:
                        rows += _power_rows(rows, boxes, surface, row.get("pole", "small-electric-pole"),
                                            [(e["x"], e["y"]) for e in port.get("external", [])])
                    except (OSError, ValueError, KeyError, TimeoutError) as exc:
                        return _result({"ok": False, "error": str(exc)}, True)
                expanded += rows
                ports.append({"cell" if "cell" in row else "chain": row.get("cell") or row["chain"], **port})
            elif "route" in row:
                if row["route"] not in ROUTES:
                    return _result({"ok": False, "error": f"unknown-route:{row['route']}"}, True)
                expanded += ROUTES[row["route"]]
            elif "file" in row:
                # Script-generated layouts: a JSON list of rows on disk, not pasted inline.
                try:
                    rows = json.loads(Path(row["file"]).read_text(encoding="utf-8"))
                except (OSError, ValueError) as exc:
                    return _result({"ok": False, "error": f"design-file:{exc}"}, True)
                if not isinstance(rows, list) or any("file" in r or "route" in r for r in rows):
                    return _result({"ok": False, "error": "design-file-must-be-plain-rows"}, True)
                expanded += rows
            else:
                expanded.append(row)
        design = expanded
        try:
            blueprint = encode_blueprint(design)
            pattern_id = pattern_id_for(blueprint)
            if not dry_run:
                record_blueprint(blueprint, state="designed", source="build_design",
                                 contract=contract)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        pattern = {"blueprint_string": blueprint, "contract": None}
        if x is None and not (contract or {}).get("site"):
            # No anchor given: design rows are world positions, built where they stand.
            # 23/09 every design needed hand floor(min corner) math and one wrong anchor
            # shifted a whole layout; the executor now derives it from row 1.
            contract = {**(contract or {}),
                        "site": {"mode": "absolute", "rotations": [0],
                                 "ref": {"x": float(design[0]["x"]), "y": float(design[0]["y"])}},
                        # Direct caps at 64 entities (control.lua); 23/09 a 243-row block
                        # failed direct-blueprint-too-large, so big designs default to ghost.
                        "build": (contract or {}).get("build")
                                 or {"mode": "direct" if len(design) <= 64 else "ghost"}}
    elif goal == "reuse_blueprint":
        if not pattern_id:
            return _result({"ok": False, "error": "pattern-id-required"}, True)
        try:
            pattern = load_pattern(pattern_id)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        # Imported human material is reference, not a plan: it was never run here, so the
        # agent has to state what it expects of it before the executor spends anything.
        if pattern.get("state") == "reference" and not contract:
            return _result({"ok": False, "error": "reference-pattern-needs-contract",
                            "pattern_id": pattern_id,
                            "origin": pattern.get("origin")}, True)
    if goal in {"reuse_blueprint", "build_design"}:
        # The agent's contract wins; otherwise the one saved with the pattern.
        body = {"action": "blueprint_run", "blueprint": pattern["blueprint_string"],
                "pattern_id": pattern_id, "contract": contract or pattern.get("contract") or {},
                "surface": surface, "force": force, "radius": radius, "dry_run": dry_run}
        if x is not None:
            body.update(x=x, y=y)
        try:
            p = request(body, host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                        port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)), timeout=15)
        except (OSError, ValueError, TimeoutError) as exc:
            return _result({"ok": False, "error": str(exc), "pattern_id": pattern_id}, True)
        return _result({"ok": p.get("ok", False), "goal": goal, "pattern_id": pattern_id,
                        **({"ports": ports} if goal == "build_design" and ports else {}),
                        **_fields(p, "job_id", "state", "site", "site_validated", "materials",
                                  "missing", "locked", "skipped_locked", "bots", "uncovered", "unpowered", "lane_joins", "steps", "rejects", "checks", "unconnected",
                                  "plan", "error")},
                       not p.get("ok", False))

@mcp.tool(annotations=READ)
def report(job_id: str, resume: bool = False) -> CallToolResult:
    """Job audit/progress/blockers/artifact. resume=True restarts a built job after blocker clears."""
    if not job_id.startswith("exec-"):
        return _result({"ok": False, "error": "unknown-job-id"}, True)
    p = _read(invoke("blueprint-job", job_id=job_id, resume=resume or None))
    extra = {}
    if p.get("audit"):
        extra["self_sustaining"] = self_sustaining(p["audit"])
    return _result({"ok": p.get("ok", False), "job_id": job_id, **extra,
                    "pattern_id": p.get("pattern_id") or (p.get("pattern") or {}).get("pattern_id"),
                    **_fields(p, "state", "site", "step", "steps", "placed", "materials", "feed",
                              "missing", "audit", "cleared", "blasted", "filled", "ground", "plan", "placed_at",
                              # A blocked job used to arrive as "blueprint-blocked:23" and
                              # nothing else: the executor knew WHICH tiles and what stood
                              # on them, the whitelist here dropped every one of them.
                              "blocked", "pending", "waiting", "standing", "built", "existing",
                              "replaced", "replaced_at", "drift", "skipped_locked", "bots", "uncovered", "unpowered", "lane_joins",
                              "block", "error", "artifact")},
                   not p.get("ok", False))


if __name__ == "__main__":
    mcp.run(transport="stdio")
