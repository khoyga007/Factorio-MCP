---
name: blue-science
description: Use to set up chemical (blue) science in Factorio, including the oil supply chain - pumpjacks, oil refining, plastic, sulfur, sulfuric acid, advanced/red circuits, and engine units. This is the most complex pre-rocket stage (fluids).
---

# Blue science (chemical science pack)

Recipe: **2 advanced-circuit + 3 engine-unit + 1 sulfur -> 2 chemical-science-pack**
(24s). This requires oil, so it is the biggest jump.

## Oil chain

1. Research `oil-processing`. Place `pumpjack`s on crude-oil patches
   (`factorio_scan_resources` shows them). Pump crude to an
   `oil-refinery` running `basic-oil-processing` (crude -> petroleum gas).
2. `chemical-plant`s convert:
   - petroleum-gas -> `plastic-bar` (with coal).
   - petroleum-gas -> `sulfur` (with water).
   - sulfur + water -> `sulfuric-acid`.
3. Fluids need pipes; connect pumpjack -> refinery -> plants with `pipe`/
   `pipe-to-ground`. Add storage tanks to buffer.

## Intermediates

- `advanced-circuit` (red circuit): plastic + copper-cable + electronic-circuit.
- `engine-unit`: steel + iron-gear + pipe.
- Then `chemical-science-pack` from advanced-circuit + engine-unit + sulfur.

## Tips

- Watch for `status` like "no_ingredients"/"fluid" issues via
  `factorio_scan_entities`.
- Sulfuric acid is also needed later for processing units and batteries.

Once blue packs flow, you can research most of the tech tree. Continue with
research-progression toward rocketry, and use mall-build-patterns to mass-produce
buildings.
