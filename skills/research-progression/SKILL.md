---
name: research-progression
description: Use to plan and manage the Factorio technology tree from the start through to the rocket silo, ordering technologies by science-pack tier and keeping the research queue fed. Reference whenever deciding what to research next.
---

# Research progression to the rocket

The bridge has no tech-tree listing: check one technology at a time with
`research <name>` (state) and start it with `research --start <name>`. Track progress
by polling `research <name>`. Keep research running so labs never idle — start the next
tech as soon as the current one finishes.

## Rough order by science tier

**Red only (automation):**
- automation, logistics, electronics, steel-processing, automation-science-pack,
  fast-inserter, automation-2 (assembling-machine-2).

**Red + green (logistic):**
- logistic-science-pack, fluid handling, engine, oil-processing, electric-energy
  distribution, logistics-2 (red belts, etc.), advanced-material-processing
  (steel furnace).

**Red + green + blue (chemical):**
- plastics, advanced-electronics (red circuits), sulfur-processing, batteries,
  advanced-electronics-2 (processing units), modules, electric-furnace,
  productivity/speed modules.

**Toward the rocket (adds military/production/utility packs as required):**
- military-science-pack and utility/production-science-pack lines if the rocket techs
  require them, then:
- `rocketry`, `rocket-fuel`, `low-density-structure`, `rocket-silo`, and
  `space-science-pack` (for the satellite/space science).

## Strategy

- Prioritize techs that unlock the next science tier and better
  buildings/inserters first, since they accelerate everything after.
- Don't bottleneck on a single pack type — scale the lagging science pack
  (check `audit <pack-item>`).
- The terminal target is **rocket-silo**; everything above feeds it. Hand off to the
  rocket-launch skill once silo tech is in reach.
