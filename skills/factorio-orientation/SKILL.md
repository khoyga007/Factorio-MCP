---
name: factorio-orientation
description: Load this FIRST whenever automating Factorio through the bridge. Explains the coordinate system, the three MCP tools (observe / achieve / report) and how the old CLI action names map onto them, the perceive-act-verify loop, the real-economy rules, and how to recover from common errors.
---

# Factorio orientation

You control a single-player Factorio 2.0 game (base game, no Space Age, peaceful)
through the `factorio-engineer` MCP server and its three tools: `observe`, `achieve`
and `report`. Your objective is to bootstrap a factory and ultimately **launch a
rocket**, playing under the real game economy.

**Every in-game action goes through MCP.** `python factorio_ai.py` is a diagnostic CLI
for the human maintainer, not a way to play. The full tool contract is in
`CONTRACT.md`; the README has the fresh-save walkthrough.

## Golden rules

1. **Perceive before acting.** Start with `observe(view="situation")` (treasury,
   machine counts, top issues, nearest enemies, ore patches). Never assume positions.
2. **Dry-run, act, then verify.** Every build goes through `achieve(..., dry_run=true)`
   first, then for real, then `report(job_id="exec-N")` until it is `verified` or
   `needs-attention`. Hand actions (`craft`, `collect`, `insert`, `set_recipe`) reply
   per row; read the result back with `observe`.
3. **Respect the economy.** Everything is built from real items in your character's
   inventory (the *treasury*). The executor gathers what a build needs from the
   treasury, your own chests and machine outputs, trees and rocks, and hand crafting.
   Nothing is spawned; locked technology is refused.
4. **Plan by numbers, measure by flow.** `observe(view="plan", query="item@N/min")`
   before building a line; `observe(view="flow", query="item@10m")` before claiming a
   bottleneck.

## The three tools

`observe(view=...)`, read only:
- `situation`: one-call base survey around the player (or `x,y,radius`).
- `deposits` (`resource=` optional): ore patches, paged with `offset`.
- `water`: offshore-pump spots with the tile the pump's pipe must use.
- `nearby` / `entities` (`query=name`) / `grid` / `lanes`: what stands around `x,y`:
  a summary, full rows (paged), a tile map, or belt lane contents.
- `research`: current tech, queue, labs, and the `available` list (what can be queued
  now).
- `plan` (`query="item@N/min"`): recipe tree → machine counts, raw inputs, power.
- `flow` (`query="a,b@10m"`): measured production and consumption per minute.
- `supply` (`query=item`): where an item is and how much is spare.
- `route` (`x,y`, `query="tx,ty[,dir][,belt|pipe]"`): an A* belt or pipe path.
- `ledger`: what was built, what feeds what, measured output per block.
- `patterns` / `references`: saved layouts in the catalog.

`achieve(goal=...)`, acts:
- `build_design` (`design=[rows]`, `contract`): build from rows you designed. Rows may
  be plain entities `{name,x,y,direction?,recipe?}`, production cells
  `{cell:recipe,...}`, chains `{chain:"item@N/min",...,feed?:true}`, ore feeds
  `{mine:ore,to:[x,y],lane?}`, or `{route:id}`.
- `reuse_blueprint` (`pattern_id`): build a saved pattern.
- `research` (`tech="name"`, or `"a,b,c"` to queue several).
- `set_recipe` (`design=[{x,y,recipe}]`): commission empty assemblers.
- `craft` / `collect` / `insert` (`design=[{name,count,x?,y?,source?}]`, ≤8 rows).
- `recall` (`area` or `design`): mine your own buildings back into the treasury.
- `capture` / `build_ghosts` (`area`), `drop_ghosts`, `import`, `annotate`, `launch`.

`report(job_id="exec-N", resume?)`: state of a build job: site, materials, each audit
window. `resume=true` continues a built job once you fixed what stopped it.

## Old CLI names → MCP

Older notes and logs use the CLI action names. Map them like this; never call the CLI
to play.

| Old CLI action | MCP call |
|---|---|
| `brief` | `observe(view="situation")` |
| `index` | `observe(view="deposits")` + `observe(view="water")`; enemies are in `situation` |
| `snapshot` | `observe(view="nearby" \| "entities" \| "grid", x, y, radius)` |
| `snapshot --tiles` (water) | `observe(view="water")` |
| `research <name>` | `observe(view="research")` |
| `research --start <name>` | `achieve(goal="research", tech="<name>")` |
| `audit <item>` | `observe(view="flow", query="<item>@10m")` |
| `place <name> <x> <y>` | `achieve(goal="build_design", design=[{"name":…, "x":…, "y":…, "direction":…}])` |
| `place --dry-run` | the same call with `dry_run=true` |
| `set-recipe <recipe> <x> <y>` | `achieve(goal="set_recipe", design=[{"x":…, "y":…, "recipe":…}])`, or `recipe` on the build row |
| `craft <recipe> [n]` | `achieve(goal="craft", design=[{"name":"<recipe>", "count":n}])` |
| `insert <item> <n> <x> <y> [--source]` | `achieve(goal="insert", design=[{"name":…, "count":n, "x":…, "y":…, "source":true}])` (`source` only for a furnace's ore slot) |
| `collect <item> <n> <x> <y>` | `achieve(goal="collect", design=[{"name":…, "count":n, "x":…, "y":…}])` |
| `spec <kind> <name>` | diagnostic CLI only; `observe(view="plan")` reads recipes for you |
| `mine <name> <x> <y>` | no MCP goal. The executor mines trees and rocks itself when a build needs wood or stone; ore comes from drills |
| `treasury <x> <y>` | **do not use.** The treasury must be your character's inventory: the executor refuses to build while a chest is named (`player-treasury-on-target-surface-required`) |
| `autofuel on\|off` | diagnostic CLI only |
| `ping` | diagnostic CLI only; an answer from `observe(view="situation")` already shows the bridge is up |

## The treasury

The treasury is **player 1's main inventory**. `craft` puts results there, builds take
their items from there, `collect` pulls into it and `insert` moves out of it.
`observe(view="situation")` reports its contents. Keep space free: a full inventory
stops jobs (`player-inventory-full`).

## Coordinates and grid

- World coordinates are floating-point tiles: **+x = east, +y = south**.
- Design rows use **entity centres**: an odd-sized entity sits on `.5`, an even-sized one
  on a whole number (a 3x3 assembler at `x.5`, a 2x2 stone furnace at an integer).
- Directions use 16 steps: `0` north, `4` east, `8` south, `12` west. An inserter's
  direction is its **pickup** side: direction `0` picks up from the north and drops to
  the south.
- To build at a known place, write the design in world centres and pass no `x,y`: the
  executor builds the rows where they stand (`site.mode="absolute"`). To let it find a
  spot, pass `contract.site.mode="search"`.
- There is no teleport or pathfinding goal; the executor works by coordinates.

## The core loop

```
observe(situation / deposits / plan)
  -> achieve(build_design, dry_run=true) -> fix what it names
  -> achieve(build_design) -> report(exec-N) until verified
  -> set_recipe / insert if needed -> observe(flow / ledger) -> repeat
```

## Recovering from errors

- `blocked` + `missing` / `locked`: items you lack, or a recipe not yet researched.
  Build the production for it, or research it.
- `blocked` + `no-site`: `rejects` counts why each spot failed and `rejects.at` names what
  stood in the way. Pick another area or relax the contract.
- `inserter-unconnected` / `pipe-unconnected`: an inserter end or an underground pipe
  has no partner. The reply names the tile and often a `hint` shift.
- `needs-attention` after the build (`infra-missing:*`, a failed audit): fix the cause,
  then `report(job_id, resume=true)`. Do not recall and rebuild.
- Empty or slow production: `observe(view="flow")` and machine status in
  `observe(view="entities")` (e.g. `no_power`, `no_ingredients`).

CONTRACT.md has the full state and error tables. When you need a plan for a specific
stage, the other skills cover early bootstrap, smelting, each science pack, research
progression, mall builds, and the rocket.
