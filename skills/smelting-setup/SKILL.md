---
name: smelting-setup
description: Use to build and scale iron, copper, and steel plate production in Factorio, including the transition from burner to electric power (boiler + steam engine, then electric drills and furnaces). Covers ratios and layout.
---

# Smelting setup

Plates are the backbone of everything. Scale these early.

## Power first

Electric drills/furnaces need power. Build a starter steam setup:
- `offshore-pump` on water -> `boiler`(s) fueled with coal -> `steam-engine`(s).
- Ratio of thumb: **1 offshore pump : ~20 boilers : ~40 steam engines** (1:1
  boiler:2 engines). Start small: 1 pump, 2-4 boilers, 4-8 engines.
- Place `small-electric-pole`s to distribute power. Verify machines leave the
  "no_power" status via `factorio_scan_entities`.

## Smelting lines

- Replace burner drills with `electric-mining-drill` on patches; replace
  `stone-furnace` with `steel-furnace` once steel is available (2x faster, still
  burner-fueled) or `electric-furnace` once you have advanced circuits.
- A full yellow belt of ore feeds roughly **24 stone/steel furnaces** per side.
  Start with rows of ~8-16 furnaces per product (iron, copper).
- **Steel**: set a furnace block to smelt iron plates -> steel (5 iron plate ->
  1 steel, slow). Dedicate furnaces to steel as rocket-tier demand grows.

## Layout pattern

`drills -> belt -> inserters -> furnaces -> inserters -> output belt`. Keep ore
input and plate output on separate belts. Leave a tile between rows for
inserters and poles.

Use `factorio_get_production_stats` to confirm plate throughput is rising, then
proceed to red-science.
