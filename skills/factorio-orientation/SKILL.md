---
name: factorio-orientation
description: Load this FIRST whenever automating Factorio through the bridge. Explains the coordinate system, the perceive-act-verify loop, the 15 bridge actions (and how they map from the old factorio_* MCP names), the legit-economy rules, and how to recover from common errors.
---

# Factorio orientation

You control a single-player Factorio 2.0 game (base game, no Space Age, peaceful)
through the Factorio AI Bridge's UDP actions (`python factorio_ai.py <action> ...`).
Your objective is to bootstrap a factory and ultimately **launch a rocket**, playing
under the real game economy.

## Golden rules

1. **Perceive before acting.** Start with `brief` (one-call base survey) and `index`
   (whole-map ore/enemy/water). Use `snapshot` to list entities around a point.
   Never assume positions.
2. **Act, then verify.** After any mutating action (`place`, `set_recipe`, `insert`,
   `research --start`, ...), confirm with a read (`brief`, `snapshot`, `research`,
   `audit`). Action errors carry the game's own message — read it and adjust.
3. **Respect the economy.** You must mine real ore, craft real items, and feed labs
   real science packs. `place` consumes the item from the treasury, so craft/obtain it
   first. Research completes only as labs consume science over time — poll `research`.

## Bridge actions (15)

Read:
- `ping` — bridge alive + advertised actions.
- `brief [--x --y --radius]` — one reply: owned machine counts, top issues, nearest
  enemies, ore patches, nearest water, treasury contents.
- `index` — whole-map survey: ore patches, enemy clusters, water (cached).
- `snapshot [--x --y --radius --offset --limit --tiles [--name]]` — entities around a
  point (paged); with `--tiles` also map tile names (default: pumpable water).
- `spec <entity|item|recipe> <name> [--entity]` — prototype reads; `kind=recipe` is
  force-level (enabled state, live `have` counts, unlocking technology).
- `research [name]` — read one technology; `research --start <name>` — start it.
- `audit <item> [--precision]` — measured production/consumption per minute.

Write:
- `place <name> <x> <y> [--direction] [--dry-run]` — place a building (consumes the item
  from treasury); `--dry-run` reports blockers and builds nothing.
- `set-recipe <recipe> <x> <y>` — commission an empty assembler.
- `craft <recipe> [count]` — craft items into the treasury.
- `mine <name> <x> <y>` — mine a resource tile by hand.
- `insert <item> <count> <x> <y>` — move items into a lab/assembler/turret input, or a
  machine's fuel slot (burners).
- `collect <item> <count> <x> <y>` — take items out of a chest or machine output.
- `treasury <x> <y>` — name a chest the treasury (where craft/place draw from).
- `autofuel on|off` — auto-fuel drills/furnaces every 5 seconds.

## Treasury pattern (replaces get_inventory)

The bridge tracks one **treasury**: place a chest, then `treasury <x> <y>` to name it.
`craft` puts results there, `place` takes buildings from there, and `brief` reports its
contents. Move items with `insert` (into a machine) or `collect` (out of a chest/machine
at x,y). There is no "read arbitrary machine inventory" action — read the treasury
instead.

## Coordinates and grid

- World coordinates are floating-point tiles: **+x = east, +y = south**.
- Most buildings occupy whole tiles; align to tile centers (x.5, y.5) or integers.
  A stone furnace is 2x2, an assembling machine 3x3, a burner miner 2x2 — leave room
  and a tile for belts/inserters.
- `--direction` takes north/east/south/west (internally Factorio's 16-step encoding:
  0 = North, 4 = East, 8 = South, 12 = West). Inserters *take from behind and drop in
  front*, so a north-facing inserter picks up from the south tile.
- There is no teleport/pathfinding action — operate by absolute coordinates only.

## The core loop

```
brief/index -> decide -> craft missing items -> place -> set_recipe -> insert -> verify (brief/audit) -> repeat
```

## Recovering from errors

- "missing item to place" -> `craft` it first, or build the production for it.
- "cannot place ... here (blocked)" -> the spot collides; `snapshot`/`place --dry-run` and pick a
  clear tile, mind footprints.
- "already researched" / "unknown technology" -> re-check `research <name>`.
- Empty/slow production -> `audit <item>` and machine `status` from `brief` (e.g.
  "no_power", "no_ingredients").

When you need a plan for a specific stage, the other skills cover early bootstrap,
smelting, each science pack, research progression, mall builds, and the rocket.
