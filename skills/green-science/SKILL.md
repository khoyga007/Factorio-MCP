---
name: green-science
description: Use to set up logistic (green) science pack production in Factorio, building inserters and transport belts as the inputs. Assumes red science and basic logistics research are done.
---

# Green science (logistic science pack)

Recipe: **1 inserter + 1 transport-belt -> 1 logistic-science-pack** (6s in an
assembling-machine-1).

## Build

1. Intermediate parts:
   - `transport-belt`: 1 iron plate + 1 iron gear -> 2 belts.
   - `inserter`: 1 iron plate + 1 iron gear + 1 electronic-circuit -> 1 inserter.
   - So you also need `electronic-circuit` (1 iron plate + 3 copper cable) and
     `copper-cable` (1 copper plate -> 2 cable).
2. Set assemblers with `factorio_set_recipe` for copper-cable, electronic-circuit,
   inserter, transport-belt, then logistic-science-pack.
3. Feed the green-science assemblers and route packs to the same labs as red
   science (labs consume each pack type they have).

## Notes

- Electronic circuits are needed everywhere from here on — overbuild them.
- Keep both red and green packs flowing to labs; many techs need both.

Confirm logistic-science-pack output via `factorio_get_production_stats`, keep
the research queue fed (see research-progression), then build toward blue
science (oil).
