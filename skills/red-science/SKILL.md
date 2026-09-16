---
name: red-science
description: Use to set up automation (red) science pack production in Factorio and the first lab-based research. Covers copper cable, iron gear wheels, the assembler recipe, and feeding labs.
---

# Red science (automation science pack)

Recipe: **1 copper plate + 1 iron gear wheel -> 1 automation-science-pack**
(craft time 5s in an assembling-machine-1).

## Build

1. Iron gear wheels: assembler with recipe `iron-gear-wheel` (2 iron plate -> 1
   gear). Feed iron plates.
2. Red science: assembler with recipe `automation-science-pack`, fed copper
   plates + iron gears (`factorio_set_recipe`, then wire belts/inserters or, for
   a quick start, `factorio_insert_items`).
3. Labs: place `lab`s, insert automation-science-packs. Then
   `factorio_set_research` to a cheap tech and poll `factorio_get_research_state`
   to confirm progress > 0.

## Ratios (assembling-machine-1, rough)

- ~1.5 gear assemblers : 1 science assembler.
- 1 red-science assembler supplies ~3 labs.

Start with a couple of science assemblers and 3-6 labs. Verify the research
progress climbs, then queue the early tech you need (logistics, electronics,
steel processing, automation 2) and move on to green-science.
