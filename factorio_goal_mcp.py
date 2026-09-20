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


def _fields(source: dict, *names: str) -> dict:
    return {name: source[name] for name in names if name in source}


@mcp.tool(annotations=READ)
def observe(view: str = "situation",
            surface: str = "nauvis", x: FiniteFloat | None = None,
            y: FiniteFloat | None = None,
            radius: Annotated[float, Field(ge=1, le=2048, allow_inf_nan=False)] = 16,
            resource: str | None = None, pattern_id: str | None = None,
            offset: Annotated[int, Field(ge=0)] = 0) -> CallToolResult:
    """situation|deposits|nearby(issues,machines,runs,poles)|entities(raw)|water|research|ledger(blocks
    +flow, edges +declared/measured per min)|patterns(+pattern_id). offset pages. water radius<=2048,
    others<=32."""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "x-and-y-required-together"}, True)
    if view not in {"situation", "deposits", "nearby", "entities", "patterns", "water", "research", "ledger"}:
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
    if view == "patterns":
        return _result({"ok": True, "view": view, "patterns": list_patterns()})
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


@mcp.tool(annotations=WRITE)
def achieve(goal: str,
            x: FiniteFloat | None = None, y: FiniteFloat | None = None,
            radius: Annotated[float, Field(ge=4, le=256, allow_inf_nan=False)] = 192,
            surface: str = "nauvis", force: str = "player",
            dry_run: bool = False, pattern_id: str | None = None,
            contract: dict | None = None, design: list[dict] | None = None,
            area: list[float] | None = None, force_active: bool = False,
            tech: str | None = None) -> CallToolResult:
    """Goals: reuse_blueprint(pattern_id), build_design(design=[{name,x,y,direction?}] centers,
    dir 0N 4E 8S 12W), recall(area=[x1,y1,x2,y2] or design=[{name,x,y}]; own entities+contents to
    bag; force_active overrides live job), capture(area -> catalog), research(tech; queued if
    busy), annotate(contract.block; new block needs area). contract: CONTRACT.md."""
    if (x is None) != (y is None):
        return _result({"ok": False, "error": "coordinate-pairs-required"}, True)
    if goal not in {"reuse_blueprint", "build_design", "recall",
                    "capture", "research", "annotate"}:
        return _result({"ok": False, "error": "unknown-goal"}, True)
    if (tech is not None) != (goal == "research"):
        return _result({"ok": False, "error": "tech-only-for-research"}, True)
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
            body.update(x1=area[0], y1=area[1], x2=area[2], y2=area[3])
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
                                  "placed_at", "error")},
                       not p.get("ok", False))

@mcp.tool(annotations=READ)
def report(job_id: str) -> CallToolResult:
    """One goal's audit, progress, blocker, block and artifact path."""
    if not job_id.startswith("exec-"):
        return _result({"ok": False, "error": "unknown-job-id"}, True)
    p = _read(invoke("blueprint-job", job_id=job_id))
    extra = {}
    if p.get("audit"):
        extra["self_sustaining"] = self_sustaining(p["audit"])
    return _result({"ok": p.get("ok", False), "job_id": job_id, **extra,
                    "pattern_id": p.get("pattern_id") or (p.get("pattern") or {}).get("pattern_id"),
                    **_fields(p, "state", "site", "step", "steps", "placed", "materials", "feed",
                              "missing", "audit", "cleared", "placed_at",
                              "block", "error", "artifact")},
                   not p.get("ok", False))


if __name__ == "__main__":
    mcp.run(transport="stdio")
