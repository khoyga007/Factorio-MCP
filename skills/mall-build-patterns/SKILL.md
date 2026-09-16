---
name: mall-build-patterns
description: Use to set up a Factorio "mall" - assemblers that continuously produce buildings and logistics items (belts, inserters, miners, assemblers, poles, pipes) so you can pull them from chests instead of micro-crafting each one. Reference when you repeatedly need buildables.
---

# Mall build patterns

A mall mass-produces the things you place constantly, so you stop hand-crafting.
Feed it iron plate, copper plate, steel, gears, circuits, and stone; pull
finished buildings from output chests with `factorio_remove_items` (or just let
them buffer).

## Core mall recipes (one assembler each, set via factorio_set_recipe)

- `transport-belt`, `underground-belt`, `splitter`
- `inserter`, `long-handed-inserter`, `fast-inserter`
- `small-electric-pole`, `medium-electric-pole`
- `pipe`, `pipe-to-ground`
- `electric-mining-drill`
- `assembling-machine-1` / `assembling-machine-2`
- `stone-furnace` / `steel-furnace`
- `lab`

## Feeder sub-assemblers

- `copper-cable`, `electronic-circuit`, `iron-gear-wheel`, `iron-stick`.

## Pattern

Lay a bus of plate/gear/circuit belts; tap each mall assembler off the bus with
inserters; drop outputs into passive chests. As a quick bootstrap you can prime
each assembler's input directly with `factorio_insert_items` and read stock with
`factorio_get_inventory` on the output chest.

With a mall running, building the rocket-launch infrastructure becomes "pull and
place" rather than crafting every part by hand.
