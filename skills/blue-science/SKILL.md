---
name: blue-science
description: Use to set up chemical (blue) science in Factorio, including the oil supply chain - pumpjacks, oil refining, plastic, sulfur, sulfuric acid, advanced/red circuits, and engine units - through the MCP tools. This is the most complex pre-rocket stage (fluids).
---

# Blue science (chemical science pack)

Recipe: **2 advanced-circuit + 3 engine-unit + 1 sulfur → 2 chemical-science-pack**
(24s). This requires oil, so it is the biggest jump. Confirm with
`observe(view="plan", query="chemical-science-pack@N/min")`.

## Oil chain

1. `achieve(goal="research", tech="oil-processing")` (check the exact name in
   `observe(view="research")`). Find crude oil with `observe(view="deposits",
   resource="crude-oil")`. Build `pumpjack`s on it, piped to an `oil-refinery` running
   `basic-oil-processing` (crude → petroleum gas).
2. `chemical-plant`s convert:
   - petroleum-gas → `plastic-bar` (with coal).
   - petroleum-gas → `sulfur` (with water).
   - sulfur + water → `sulfuric-acid`.
3. Fluids need pipes; connect pumpjack → refinery → plants with `pipe` /
   `pipe-to-ground`. `observe(view="route", x, y, query="tx,ty,pipe")` finds a pipe path
   and returns a `route_id` to build as a `{"route":"route-N"}` row. Underground pipe
   pairs are checked before the build (`pipe-unconnected` names a broken pair). Declare
   each fluid link in `contract.connect` (`{"entity":"oil-refinery","fluid":"crude-oil"}`)
   so the executor checks it after the build. Add storage tanks to buffer.
4. A production cell handles fluid recipes too: it reads the machine's fluid ports and
   lays the input and output pipe buses. You still bring the fluid to the cell. A chain
   row chains only the SOLID inputs: fluids are not in `ports.external`; each fluid
   cell's pipe ports are in its `ports.cells[]` entry (`fluid_in`/`fluid_out`). A chain
   of a fluid (e.g. `sulfuric-acid@N/min`) outputs on a pipe: `output.kind == "pipe"`.

## Intermediates

- `advanced-circuit` (red circuit): plastic + copper-cable + electronic-circuit.
- `engine-unit`: steel + iron-gear + pipe.
- Then `chemical-science-pack` from advanced-circuit + engine-unit + sulfur.

## Tips

- Watch for `no_ingredients` and fluid problems in machine status
  (`observe(view="entities", x, y, radius)`), and measure with `observe(view="flow")`.
- Every new consumer on a shared pipe steals from someone: before connecting, list who
  else draws from that fluid (LESSONS.md #7).
- Sulfuric acid is also needed later for processing units and batteries.

Once blue packs flow, you can research most of the tech tree. Continue with
research-progression toward the rocket, and use mall-build-patterns to mass-produce
buildings.
