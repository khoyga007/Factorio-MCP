---
name: red-science
description: Use to set up automation (red) science pack production in Factorio and the first lab-based research, through the MCP tools. Covers copper cable, iron gear wheels, the assembler recipe, and feeding labs.
---

# Red science (automation science pack)

Recipe: **1 copper plate + 1 iron gear wheel → 1 automation-science-pack**
(craft time 5s in an assembling-machine-1). Confirm numbers with
`observe(view="plan", query="automation-science-pack@N/min")`, which reads the live
recipes.

## Build

1. **Plan.** `observe(view="plan", query="automation-science-pack@30/min")` gives the
   gear and science assembler counts and the plates per minute they need.
2. **Chain.** One build row can lay the whole thing:
   `{"chain":"automation-science-pack@30/min", "x":…, "y":…, "power":true}` builds one
   cell per recipe (gears, then science) with the belt between them routed for you.
   Add `"feed":true` to the chain row and it also mines every ore its external ports
   want: drill columns on the nearest patches, belts routed into the ports, power run
   to the grid (electric drills only; world positions, no `x,y` on `achieve`). What is
   not ore stays in `ports.external` for you to feed by belt.
   Or build single cells: `{"cell":"iron-gear-wheel", "x":…, "y":…, "count":2}`.
   Dry-run first; cells set each assembler's recipe themselves.
3. **Plain assemblers.** If you place `assembling-machine-1` rows yourself, give each row
   a `recipe`, or commission empty ones with
   `achieve(goal="set_recipe", design=[{"x":…, "y":…, "recipe":"iron-gear-wheel"}])`.
   For a quick start, `achieve(goal="insert", design=[...])` puts plates straight into an
   assembler's input.
4. **Labs.** Build `lab`s with power, feed them packs (inserters from the science belt, or
   `insert` for a first batch), then
   `achieve(goal="research", tech="<name>")` on a cheap tech. Check with
   `observe(view="research")` that progress is above 0.

## Ratios (assembling-machine-1, rough)

- ~1.5 gear assemblers : 1 science assembler.
- 1 red-science assembler supplies ~3 labs.

Start with a couple of science assemblers and 3-6 labs. Confirm output with
`observe(view="flow", query="automation-science-pack@10m")`, then queue the early tech you
need (pick names from the `available` list in `observe(view="research")`) and move on to
green-science.
