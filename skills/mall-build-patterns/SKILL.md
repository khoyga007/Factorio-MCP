---
name: mall-build-patterns
description: Use to set up a Factorio "mall" - assemblers that continuously produce buildings and logistics items (belts, inserters, miners, assemblers, poles, pipes) so you can pull them from chests instead of hand-crafting each one, through the MCP tools. Reference when you repeatedly need buildables.
---

# Mall build patterns

A mall mass-produces the things you place constantly, so you stop hand-crafting.
Feed it iron plate, copper plate, steel, gears, circuits, and stone. Finished buildings
buffer in output chests. The executor already looks in your own chests and machine
outputs when a build needs an item, so a stocked mall feeds your builds without any
extra step; `achieve(goal="collect", design=[{"name":…, "count":n, "x":…, "y":…}])`
pulls a batch into the treasury by hand.

## Core mall recipes (one assembler each)

Give each assembler its recipe on the build row (`"recipe": …`), or commission empty
ones with `achieve(goal="set_recipe", design=[{"x":…, "y":…, "recipe":…}])`.

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

Lay a bus of plate, gear and circuit belts; tap each mall assembler off the bus with
inserters; drop outputs into chests. As a quick bootstrap you can prime each assembler's
input directly with `achieve(goal="insert", design=[...])`. Read what the mall has made
with `observe(view="supply", query="<item>")`.

Register the mall in the ledger (`contract.block` on the build, or
`achieve(goal="annotate", ...)` for something already standing) so
`observe(view="ledger")` shows what it makes and what feeds it.

With a mall running, building the rocket-launch infrastructure becomes "the executor
pulls it from the mall" rather than crafting every part by hand.
