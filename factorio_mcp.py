"""Factorio Engineer MCP: typed stdio tools over the existing CLI/UDP flow."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Annotated, Literal

from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent, ToolAnnotations
from pydantic import Field, FiniteFloat

from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, execute


Count = Annotated[int, Field(ge=1)]
Offset = Annotated[int, Field(ge=0)]
Limit = Annotated[int, Field(ge=1, le=64)]
Direction = Literal["north", "east", "south", "west"]
READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
REMOVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False)

mcp = FastMCP(
    "factorio-engineer",
    instructions=(
        "Use brief for orientation; use index/ore_marks for known deposits. "
        "For the first iron/copper plates use starter_smelt -> starter_status. "
        "For a larger iron row use smelt_plan -> smelt_build -> smelt_status. "
        "Plans, blueprints and detailed build receipts stay outside model context. "
        "The mod checks live collisions, technology and real item costs. "
        "After a mutation timeout, inspect the world or plan status before retrying."
    ),
    log_level="WARNING",
)


def invoke(command: str, **values) -> CallToolResult:
    """No subprocess, shell or second planner: CLI and MCP share execute()."""
    try:
        if "file" in values:
            path = Path(values["file"])
            if not path.is_absolute():
                raise ValueError("blueprint file must be an absolute path")
            values["file"] = path
        args = argparse.Namespace(
            command=command,
            host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
            port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)),
            **values,
        )
        reply = execute(args)
    except (OSError, ValueError) as exc:
        reply = {"ok": False, "error": str(exc)}
    return CallToolResult(
        isError=not reply.get("ok", False),
        content=[TextContent(type="text", text=json.dumps(reply, ensure_ascii=False, separators=(",", ":")))],
    )


@mcp.tool(annotations=READ)
def ping() -> CallToolResult:
    """Read the loaded mod build and supported actions."""
    return invoke("ping")


@mcp.tool(annotations=READ)
def brief(x: FiniteFloat | None = None, y: FiniteFloat | None = None,
          radius: FiniteFloat = 32, surface: str = "nauvis") -> CallToolResult:
    """One compact base/ore/water/enemy/stock survey. Supply x and y together."""
    return invoke("brief", **locals())


@mcp.tool(annotations=READ)
def snapshot(x: FiniteFloat | None = None, y: FiniteFloat | None = None,
             radius: FiniteFloat = 16, offset: Offset = 0, limit: Limit = 64,
             tiles: bool = False, name: list[str] | None = None,
             obstacles: bool = False, surface: str = "nauvis") -> CallToolResult:
    """Page local entities/fluids. Optional tiles and natural obstacles; radius capped at 32."""
    return invoke("snapshot", **locals())


@mcp.tool(annotations=READ)
def index(surface: str = "nauvis") -> CallToolResult:
    """Read the cached survey of all generated chunks, including ore marks."""
    return invoke("index", **locals())


@mcp.tool(annotations=READ)
def ore_marks(name: str | None = None, offset: Offset = 0, limit: Limit = 50,
              surface: str = "nauvis") -> CallToolResult:
    """Page remembered ore sectors, including depleted deposits; limit capped at 50."""
    return invoke("ore-marks", **locals())


@mcp.tool(annotations=READ)
def spec(kind: Literal["entity", "item", "recipe"], name: str | None = None,
         entity: str | None = None, force: str = "player") -> CallToolResult:
    """Read native prototype/recipe data, including fluid ports. Recipe accepts entity instead of name."""
    return invoke("spec", **locals())


@mcp.tool(annotations=WRITE)
def smelt_plan(rate: Annotated[float, Field(gt=0, allow_inf_nan=False)],
               x: FiniteFloat | None = None, y: FiniteFloat | None = None,
               input_x: FiniteFloat | None = None, input_y: FiniteFloat | None = None,
               surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Plan a 1–6 furnace iron row for plates/minute. Returns plan_id, site and material/connection needs."""
    return invoke("smelt-plan", **locals())


@mcp.tool(annotations=WRITE)
def smelt_build(plan_id: str) -> CallToolResult:
    """Revalidate and build the saved row with real items; save blueprint/receipts and start its audit."""
    return invoke("smelt-build", **locals())


@mcp.tool(annotations=READ)
def smelt_status(plan_id: str) -> CallToolResult:
    """Read one row's state and measured production. Audit finishes after 30s warmup + 60 game seconds."""
    return invoke("smelt-status", **locals())


@mcp.tool(annotations=WRITE)
def starter_smelt(product: Literal["iron-plate", "copper-plate"] = "iron-plate",
                  x: FiniteFloat | None = None, y: FiniteFloat | None = None,
                  radius: Annotated[float, Field(ge=4, le=256, allow_inf_nan=False)] = 192,
                  surface: str = "nauvis", force: str = "player",
                  dry_run: bool = False) -> CallToolResult:
    """One starter goal: mine real coal with starting wood, then direct-feed a stone furnace; no belts or power."""
    return invoke("starter-smelt", **locals())


@mcp.tool(annotations=READ)
def starter_status(job_id: str) -> CallToolResult:
    """Read coal/bootstrap/build/audit progress for one starter goal."""
    return invoke("starter-status", **locals())


@mcp.tool(annotations=WRITE)
def coal_stockpile(x: FiniteFloat | None = None, y: FiniteFloat | None = None,
                   radius: Annotated[float, Field(ge=4, le=256, allow_inf_nan=False)] = 192,
                   surface: str = "nauvis", force: str = "player",
                   dry_run: bool = False) -> CallToolResult:
    """Build or reuse a burner drill dropping mined coal into an adjacent chest."""
    return invoke("coal-stockpile", **locals())


@mcp.tool(annotations=READ)
def coal_status(job_id: str) -> CallToolResult:
    """Read measured coal output and saved receipt for one stockpile cell."""
    return invoke("coal-status", **locals())


@mcp.tool(annotations=REMOVE)
def repair_demo_economy(key: str) -> CallToolResult:
    """One-time exact ingredient correction for the Sandbox coal demo."""
    return invoke("repair-demo-economy", **locals())


@mcp.tool(annotations=WRITE)
def set_treasury(x: FiniteFloat, y: FiniteFloat, surface: str = "nauvis") -> CallToolResult:
    """Select an existing chest as the source of real construction items."""
    return invoke("treasury", **locals())


@mcp.tool(annotations=WRITE)
def place(name: str, x: FiniteFloat, y: FiniteFloat, direction: Direction = "north",
          dry_run: bool = False, type: Literal["input", "output"] | None = None,
          surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Place one entity using real stock. dry_run reports blockers; type applies only to underground-belt."""
    return invoke("place", **locals())


@mcp.tool(annotations=WRITE)
def craft(recipe: str, count: Count = 1) -> CallToolResult:
    """Craft using real ingredients and unlocked recipes."""
    return invoke("craft", **locals())


@mcp.tool(annotations=REMOVE)
def mine(name: str, x: FiniteFloat, y: FiniteFloat, surface: str = "nauvis") -> CallToolResult:
    """Mine one entity into treasury; report any real items spilled by a full inventory."""
    return invoke("mine", **locals())


@mcp.tool(annotations=WRITE)
def collect(item: str, count: Count, x: FiniteFloat, y: FiniteFloat,
            ground: bool = False, surface: str = "nauvis") -> CallToolResult:
    """Move real chest/output items or a ground stack into player inventory. ground selects a drop explicitly."""
    return invoke("collect", **locals())


@mcp.tool(annotations=WRITE)
def insert(item: str, count: Count, x: FiniteFloat, y: FiniteFloat,
           source: bool = False, surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Move treasury items into a chest, machine input or fuel slot. source selects furnace ingredients."""
    return invoke("insert", **locals())


@mcp.tool(annotations=WRITE)
def autofuel(state: Literal["on", "off"]) -> CallToolResult:
    """Enable/disable automatic burner refueling from real treasury stock."""
    return invoke("autofuel", **locals())


@mcp.tool(annotations=WRITE)
def set_recipe(recipe: str, x: FiniteFloat, y: FiniteFloat,
               surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Assign an unlocked recipe to an empty assembler; same recipe is a no-op."""
    return invoke("set-recipe", **locals())


@mcp.tool(annotations=WRITE)
def research(name: str | None = None, start: bool = False, force: str = "player") -> CallToolResult:
    """Read research, or start an available technology with start=true."""
    return invoke("research", **locals())


@mcp.tool(annotations=READ)
def audit(item: str, precision: Literal["five_seconds", "one_minute", "ten_minutes", "one_hour"] = "one_minute",
          expected_per_second: FiniteFloat | None = None, surface: str = "nauvis",
          force: str = "player") -> CallToolResult:
    """Read force-wide item production. Use smelt_status to attribute output to one row."""
    return invoke("audit", **locals())


@mcp.tool(annotations=WRITE)
def blueprint_export(x1: FiniteFloat, y1: FiniteFloat, x2: FiniteFloat, y2: FiniteFloat,
                     file: str, surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Export built area to a NEW absolute file; return path/counts, keeping blueprint string out of context."""
    return invoke("blueprint-export", **locals())


@mcp.tool(annotations=WRITE)
def blueprint_import(file: str, x: FiniteFloat, y: FiniteFloat, ghosts: bool = False,
                     surface: str = "nauvis", force: str = "player") -> CallToolResult:
    """Import an absolute blueprint file. Default direct construction uses real items, no robots; max 64 entities."""
    return invoke("blueprint-import", **locals())


@mcp.tool(annotations=WRITE)
def blueprint_run(file: str, contract: dict | None = None, pattern_id: str | None = None,
                  x: FiniteFloat | None = None, y: FiniteFloat | None = None,
                  radius: Annotated[float, Field(ge=4, le=256, allow_inf_nan=False)] = 192,
                  surface: str = "nauvis", force: str = "player",
                  dry_run: bool = False) -> CallToolResult:
    """Generic executor: agent contract drives site search, real-item gather, build, prime, holdout audit."""
    return invoke("blueprint-run", **locals())


@mcp.tool(annotations=READ)
def blueprint_job(job_id: str) -> CallToolResult:
    """Read one executor job: state, site, feed totals and every holdout window."""
    return invoke("blueprint-job", **locals())


if __name__ == "__main__":
    mcp.run(transport="stdio")
