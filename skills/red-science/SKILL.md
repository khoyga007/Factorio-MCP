---
name: red-science
description: Use to set up automation (red) science pack production in Factorio and the first lab-based research. Covers copper cable, iron gear wheels, the assembler recipe, and feeding labs.
---

# Red science (automation science pack)

Recipe: **1 copper plate + 1 iron gear wheel -> 1 automation-science-pack**
(craft time 5s in an assembling-machine-1).

## Build

1. Iron gear wheels: `place assembling-machine-1`, then
   `set-recipe iron-gear-wheel <x> <y>` (2 iron plate -> 1 gear). Feed iron plates.
2. Red science: assembler with `set-recipe automation-science-pack <x> <y>`, fed copper
   plates + iron gears (belt/inserter, or for a quick start `insert` the items).
3. Labs: `place lab`, `insert automation-science-pack <n> <x> <y>` into each. Then
   `research --start <tech>` on a cheap tech and poll `research <name>` to confirm
   progress > 0.

## Ratios (assembling-machine-1, rough)

- ~1.5 gear assemblers : 1 science assembler.
- 1 red-science assembler supplies ~3 labs.

Start with a couple of science assemblers and 3-6 labs. Verify the research progress
climbs, then queue the early tech you need (logistics, electronics, steel processing,
automation 2) and move on to green-science.
