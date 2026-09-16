---
name: factorio-orientation
description: Load this FIRST whenever playing or automating Factorio through the factorio MCP tools. Explains the coordinate system, the perceive-act-verify loop, tile/grid placement, direction encoding, the legit-economy rules, and how to recover from common errors.
---

# Factorio orientation

You control a single-player Factorio 2.0 game (base game, no Space Age, peaceful)
through the `factorio_*` MCP tools. Your objective is to bootstrap a factory and
ultimately **launch a rocket**, playing under the real game economy.

## Golden rules

1. **Perceive before acting.** Start by calling `factorio_get_player_state`,
   `factorio_scan_resources`, and `factorio_scan_entities` to understand the
   surroundings. Never assume positions.
2. **Act, then verify.** After any mutating call (`factorio_place_entity`,
   `factorio_set_recipe`, ...), confirm it with a scan or inventory read. Tool
   errors carry the game's own message — read it and adjust.
3. **Respect the economy.** You must mine real ore, craft real items, and feed
   labs real science packs. Placing a building **consumes the item from your
   inventory**, so you must craft/obtain it first. Research completes only as
   labs consume science over time — poll `factorio_get_research_state`.

## Coordinates and grid

- World coordinates are floating-point tiles: **+x = east, +y = south**.
- Most buildings occupy whole tiles; align positions to tile centers (x.5, y.5)
  or integers consistently. A stone furnace is 2x2, an assembling machine 3x3, a
  burner miner 2x2 — leave room and a tile for belts/inserters.
- `direction` uses Factorio's 16-step encoding: **0 = North, 4 = East,
  8 = South, 12 = West**. Inserters *take from behind and drop in front*, so a
  north-facing inserter picks up from the south tile.

## The core loop

```
scan -> decide -> craft missing items -> place/wire -> set recipe -> verify -> repeat
```

Move with `factorio_teleport` (pathfinding is intentionally out of scope). Use
`factorio_mine_resource` for the very first ore/wood by hand, then let drills and
furnaces do the work.

## Recovering from errors

- "missing item to place" -> craft it first with `factorio_craft`, or build the
  production for it.
- "cannot place ... here (blocked)" -> the spot collides; scan and pick a clear
  tile, mind building footprints.
- "already researched" / "unknown technology" -> re-check `factorio_get_tech_tree`.
- Empty/slow production -> check `factorio_get_production_stats` and machine
  `status` from `factorio_scan_entities` (e.g. "no_power", "no_ingredients").

When you need a plan for a specific stage, the other Factorio skills cover early
bootstrap, smelting, each science pack, research progression, mall builds, and
the rocket.
