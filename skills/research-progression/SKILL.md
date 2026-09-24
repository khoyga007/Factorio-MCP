---
name: research-progression
description: Use to plan and manage the Factorio technology tree from the start through to the rocket silo, ordering technologies by science-pack tier and keeping the research queue fed, through the MCP tools. Reference whenever deciding what to research next.
---

# Research progression to the rocket

`observe(view="research")` returns the current technology, its progress, the `queue`,
lab status counts, and `available`: every technology whose prerequisites are met and
that is not researched yet. Start one with `achieve(goal="research", tech="<name>")`, or
queue several at once with `tech="a,b,c"`. A tech whose prerequisites are neither
researched nor queued is refused `cannot-queue` with `missing_prerequisites`. Keep the
queue non-empty so labs never idle.

Technology names changed between Factorio versions. **Pick exact names from `available`**
rather than from the list below, which is a rough order by tier.

## Rough order by science tier

**Red only (automation):**
- automation, logistics, electronics, steel processing, automation science pack,
  fast inserter, automation 2 (assembling-machine-2).

**Red + green (logistic):**
- logistic science pack, fluid handling, engine, oil processing, electric energy
  distribution, logistics 2, advanced material processing (steel furnace).

**Red + green + blue (chemical):**
- plastics, advanced circuits, sulfur processing, batteries, processing units, modules,
  electric furnace, productivity and speed modules.

**Toward the rocket (adds military/production/utility packs as required):**
- military, production and utility science pack lines if the rocket techs require them,
  then rocketry, rocket fuel, low density structure, rocket silo, and space science pack
  (for the satellite).

## Strategy

- Prioritise techs that unlock the next science tier and better buildings and inserters
  first, since they accelerate everything after.
- Don't bottleneck on a single pack type: scale the lagging science pack (check
  `observe(view="flow", query="<pack>@10m")`).
- The terminal target is **rocket-silo**; everything above feeds it. Hand off to the
  rocket-launch skill once silo tech is in reach.
