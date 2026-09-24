---
name: smelting-setup
description: Use to build and scale iron, copper, and steel plate production in Factorio, including the transition from burner to electric power (boiler + steam engine, then electric drills and furnaces). Covers ratios and layout, through the MCP tools.
---

# Smelting setup

Plates are the backbone of everything. Scale these early.

## Power first

Electric drills and assemblers need power. Build a starter steam setup:
- `observe(view="water")` lists offshore-pump spots, each with the `output` tile where
  the pump's pipe must go. Build `offshore-pump` → `boiler`(s) fuelled with coal →
  `steam-engine`(s) as one `build_design`.
- Declare the links so the executor checks them: `contract.connect =
  [{"entity":"boiler","fluid":"water"}, {"entity":"steam-engine","power":true}]`.
  The saved pattern `bp-985eb5fc230538b4` is a tested 1 boiler : 2 engines layout
  (`achieve(goal="reuse_blueprint", pattern_id="bp-985eb5fc230538b4", contract=...)`,
  see CONTRACT.md "Saved contracts" for the `declared_load_mw` it needs).
- Ratio of thumb: **1 offshore pump : ~20 boilers : ~40 steam engines** (1 boiler :
  2 engines). Start small: 1 pump, 2-4 boilers, 4-8 engines.
- Distribute with `small-electric-pole`s. A row `power: true` on a cell or chain routes
  a pole line to the nearest powered pole for you. Check that machines leave `no_power`
  with `observe(view="entities", x, y, radius)`.

## Smelting lines

- Replace burner drills with `electric-mining-drill` on patches; replace
  `stone-furnace` with `steel-furnace` once steel is available (2x faster, still
  burner-fuelled) or `electric-furnace` once you have advanced circuits.
- Size the line by numbers: `observe(view="plan", query="iron-plate@60/min")` gives
  furnace and drill counts.
- A furnace production cell is one build row: `{"cell":"iron-plate", "x":…, "y":…,
  "count":8}` lays furnaces with input and output belts and inserters. Burner furnaces
  take coal on the input belt's second lane.
- **Feed it from the ore patch without hand routing** (electric drills only): a row
  `{"mine":"iron-ore", "to":[px, py], "lane":"N", "per_min":60}` plans the drill column on
  the nearest patch, routes its belt into the port at `px,py`, side-loads the given lane
  and runs power to the grid. Add a second row with `"mine":"coal", "lane":"S"` for a
  burner furnace's fuel. Write the design in world positions and pass no `x,y` to
  `achieve` (`mine-needs-world-rows-no-x-y` otherwise).
- **Steel**: a furnace cell for `steel-plate` fed with iron plates (5 iron plate → 1
  steel, slow). Dedicate furnaces to steel as rocket-tier demand grows.

## Layout pattern

`drills → belt → inserters → furnaces → inserters → output belt`. Keep ore input and
plate output on separate belts. Leave a tile between rows for inserters and poles.
`observe(view="route", x, y, query="tx,ty")` finds a belt path from the drills to the
cell's input port and returns a `route_id`; build it with a `{"route":"route-N"}` row.

Use `observe(view="flow", query="iron-plate,copper-plate@10m")` to confirm plate
throughput is rising, then proceed to red-science.
