---
name: green-science
description: Use to set up logistic (green) science pack production in Factorio, building inserters and transport belts as the inputs, through the MCP tools. Assumes red science and basic logistics research are done.
---

# Green science (logistic science pack)

Recipe: **1 inserter + 1 transport-belt → 1 logistic-science-pack** (6s in an
assembling-machine-1). Confirm with `observe(view="plan", query="logistic-science-pack@N/min")`.

## Build

1. Intermediate parts:
   - `transport-belt`: 1 iron plate + 1 iron gear → 2 belts.
   - `inserter`: 1 iron plate + 1 iron gear + 1 electronic-circuit → 1 inserter.
   - So you also need `electronic-circuit` (1 iron plate + 3 copper cable) and
     `copper-cable` (1 copper plate → 2 cable).
2. `observe(view="plan", query="logistic-science-pack@30/min")` for the machine counts,
   then build it as a chain row
   (`{"chain":"logistic-science-pack@30/min", "x":…, "y":…, "power":true}`) or as
   separate cells for copper-cable, electronic-circuit, inserter, transport-belt and
   logistic-science-pack. A chain feeds 1-2 ingredient recipes by belt; anything it
   cannot make itself comes back in `ports.external` for you to feed. Dry-run first.
3. Feed the green-science output to the same labs as red science (labs consume each pack
   type they hold).

## Notes

- Electronic circuits are needed everywhere from here on; overbuild them.
  `{"chain":"electronic-circuit@60/min", …}` has been built and verified live.
- Keep both red and green packs flowing to labs; many techs need both.

Confirm output with `observe(view="flow", query="logistic-science-pack@10m")`, keep the
research queue fed (see research-progression), then build toward blue science (oil).
