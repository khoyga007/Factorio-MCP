"""Goal-level MCP surface over the existing Factorio bridge actions."""

from __future__ import annotations

import json
import os
from typing import Annotated

from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import Field, FiniteFloat

from factorio_mcp import invoke
from perception import ground, natural, summarize
from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, request, self_sustaining
from blueprint_library import (encode_blueprint, list_patterns, load_pattern,
                               pattern_entities, pattern_id_for, record_blueprint)


READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
mcp = FastMCP(
    "factorio-engineer",
    instructions=(
        "Choose a production goal and call achieve once. The bridge reuses existing "
        "machines, checks real stock and geometry, builds a feasible pattern and "
        "audits in game. Use observe(patterns) and achieve(reuse_blueprint) for saved "
        "native blueprints; achieve(build_design) builds a layout the agent designed itself. Use report(job_id) for the outcome and observe for blockers. "
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
    """situation|deposits|nearby(issues,machines,runs,poles)|entities(raw)|water|research|ledger(blocks
    +flow, edges +declared/measured/min)|patterns(+pattern_id)
    |references(imported human work). query+offset page both. water radius<=2048,
    others<=32."""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "x-and-y-required-together"}, True)
    if view not in {"situation", "deposits", "nearby", "entities", "patterns", "references",
                    "water", "research", "ledger"}:
        return _result({"ok": False, "error": "unknown-view"}, True)
    if view == "ledger":
        return _send({"action": "ledger"}, 5)
    if view == "research":
        return _send({"action": "research", "surface": surface, "available": True}, 5)
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
        return _result({"ok": True, "view": view, "pattern_id": pattern_id,
                        "state": pattern.get("state"), "contract": pattern.get("contract"),
                        "entities": pattern_entities(pattern["blueprint_string"])})
    if view in {"patterns", "references"}:
        return _result({"ok": True, "view": view,
                        **list_patterns(reference=view == "references", query=query,
                                        offset=offset)})
    if view == "situation":
        p = _read(invoke("brief", surface=surface, x=x, y=y, radius=radius))
        return _result({"ok": p.get("ok", False), "view": view, **_fields(p,
            "center", "counts", "issue_total", "issues", "enemy_total",
            "nearest_enemies", "ore_total", "ore_patches", "treasury", "error")},
            not p.get("ok", False))
    if view == "deposits":
        p = _read(invoke("ore-marks", surface=surface, name=resource, offset=offset, limit=12))
        return _result({"ok": p.get("ok", False), "view": view,
                        **_fields(p, "total", "marks", "next_offset", "error")},
                       not p.get("ok", False))
    if view == "nearby":
        return _nearby(surface, x, y, radius)
    p = _read(invoke("snapshot", surface=surface, x=x, y=y, radius=radius,
                     offset=offset, limit=12, tiles=False, name=None, obstacles=True))
    rows = p.get("entities") or []
    entities = [_fields(e, "name", "type", "x", "y", "direction", "status_name",
                        "fuel", "input", "output", "fluids", "lines")
                for e in rows if isinstance(e, dict)]
    return _result({"ok": p.get("ok", False), "view": view,
                    **_fields(p, "center", "resources", "entities_total",
                              "entities_next_offset", "obstacles_total", "obstacles",
                              "ground_items", "error"), "entities": entities},
                   not p.get("ok", False))


NEARBY_MAX_PAGES = 16  # x64 rows per Lua page


def _nearby(surface, x, y, radius) -> CallToolResult:
    """Pull every snapshot page, then compress in Python (Lua stays a cheap fact dump)."""
    rows, offset, head = [], 0, None
    for _ in range(NEARBY_MAX_PAGES):
        p = _read(invoke("snapshot", surface=surface, x=x, y=y, radius=radius,
                         offset=offset, limit=64, tiles=False, name=None, obstacles=offset == 0))
        if not p.get("ok", False):
            return _result({"ok": False, "view": "nearby", **_fields(p, "error")}, True)
        head = head or p
        rows += [e for e in p.get("entities") or [] if isinstance(e, dict)]
        offset = p.get("entities_next_offset")
        if offset is None:
            break
    data = {"ok": True, "view": "nearby", **_fields(head, "center", "entities_total"),
            **summarize(rows)}
    if offset is not None:
        data["truncated_at"] = len(rows)
    data["resources"] = [[r.get("name"), r.get("x"), r.get("y"), r.get("amount")]
                         for r in head.get("resources") or [] if isinstance(r, dict)]
    for key, value in (("obstacles", natural(head.get("obstacle_summary"))),
                       ("ground_items", ground(head.get("ground_items")))):
        if value:
            data[key] = value
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
    """Goals (CONTRACT.md; area=[x1,y1,x2,y2]): reuse_blueprint(pattern_id),
build_design(design=[{name,x,y,direction?}] centers, dir 0N4E8S12W),
recall(area|design=[{name,x,y}]->bag; force_active beats job),
capture(area->catalog), research(tech), annotate(contract.block; new needs area),
set_recipe(design=[{x,y,recipe}]; empty asm), craft|collect|insert
(design=[{name,count,x?,y?,source?}]<=8; craft queues)."""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "coordinate-pairs-required"}, True)
    if goal not in {"reuse_blueprint", "build_design", "recall", "capture", "research",
                    "annotate", "set_recipe", "craft", "collect", "insert"}:
        return _result({"ok": False, "error": "unknown-goal"}, True)
    if (tech is not None) != (goal == "research"):
        return _result({"ok": False, "error": "tech-only-for-research"}, True)
    if goal == "set_recipe":
        return _set_recipe(design, surface, force)
    if goal in HAND:
        return _hand(goal, design, surface, force, x, y)
    if goal == "research":
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
        return _result({"ok": True, "goal": goal, **saved,
                        "layout": pattern_entities(p["blueprint"])})
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
            return _recall_area(body, area)
        elif design:
            body["entities"] = design
        else:
            return _result({"ok": False, "error": "area-or-design-required"}, True)
        return _send(body, 15)
    if area is not None or force_active:
        return _result({"ok": False, "error": "area-only-for-recall-or-capture"}, True)
    if (design is not None) != (goal == "build_design"):
        return _result({"ok": False, "error": "design-only-for-build-design"}, True)
    if goal == "build_design":
        if pattern_id is not None:
            return _result({"ok": False, "error": "design-takes-no-pattern-id"}, True)
        try:
            blueprint = encode_blueprint(design)
            pattern_id = pattern_id_for(blueprint)
            if not dry_run:
                record_blueprint(blueprint, state="designed", source="build_design",
                                 contract=contract)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            return _result({"ok": False, "error": str(exc)}, True)
        pattern = {"blueprint_string": blueprint, "contract": None}
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
                        **_fields(p, "job_id", "state", "site", "site_validated", "materials",
                                  "missing", "locked", "steps", "rejects", "checks", "unconnected",
                                  "plan", "error")},
                       not p.get("ok", False))

@mcp.tool(annotations=READ)
def report(job_id: str, resume: bool = False) -> CallToolResult:
    """One goal's audit, progress, blocker, block, artifact path.

    resume=True restarts a built job stopped on a blocker, once fixed; never
    re-imports or re-primes what is on the ground.
    """
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
                              "block", "error", "artifact")},
                   not p.get("ok", False))


if __name__ == "__main__":
    mcp.run(transport="stdio")
