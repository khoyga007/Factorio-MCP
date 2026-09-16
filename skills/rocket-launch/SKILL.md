---
name: rocket-launch
description: Use in the Factorio end-game to build the rocket silo, produce rocket parts (low-density structures, rocket fuel, processing units), load a satellite, and launch the rocket to win. Reference once rocket-silo research is done or close.
---

# Rocket launch (win condition)

A rocket needs **100 rocket parts**; each part costs **10 low-density-structure +
10 rocket-fuel + 10 processing-unit**. Build the supply chains, then the silo.

## Prerequisites (see research-progression)

`rocket-silo`, `low-density-structure`, `rocket-fuel`, `processing-unit` (blue
circuit), and the satellite (`space-science-pack` line) researched. Confirm each with
`research <name>`.

## Component chains

- **low-density-structure**: steel + copper plate + plastic (in assembler).
- **rocket-fuel**: solid-fuel (from light oil / petroleum) -> rocket-fuel. Set up
  `chemical-plant`s for solid-fuel; consider `advanced-oil-processing` + cracking to
  balance light oil.
- **processing-unit**: electronic-circuit + advanced-circuit + sulfuric-acid.
- Scale steel, plastic, and circuits hard — these are the gating inputs.

## Build and launch

1. `place rocket-silo <x> <y>` with power and room; it is 9x9. Verify with `snapshot`.
2. Feed it low-density-structure, rocket-fuel, and processing-unit (belts +
   inserters, or `insert <item> <n> <x> <y>` for a manual push). It auto-crafts the
   100 rocket parts.
3. `craft satellite`, then `insert satellite 1 <x> <y>` into the silo.
4. When parts reach 100 the rocket is ready; the silo launches (auto-launch with a
   satellite loaded). Watch silo `status` via `snapshot`/`brief` and
   `audit rocket-part` for part production.
5. Confirm the launch via `snapshot` on the silo (rocket gone / launch state).
   **Launching the rocket is the win.**

If anything stalls, diagnose with `audit` and machine status, scale the lagging
input, and keep the silo fed.
