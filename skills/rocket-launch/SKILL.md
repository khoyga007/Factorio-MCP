---
name: rocket-launch
description: Use in the Factorio end-game to build the rocket silo, produce rocket parts (low-density structures, rocket fuel, processing units), load the silo, and launch the rocket, through the MCP tools. Reference once rocket-silo research is done or close.
---

# Rocket launch (win condition)

A rocket needs **100 rocket parts**; each part costs **10 low-density-structure +
10 rocket-fuel + 10 processing-unit**. These counts were written from older game
versions: confirm them with `observe(view="plan", query="rocket-part@N/min")`, which reads
the live recipes. Build the supply chains, then the silo.

## Prerequisites (see research-progression)

`rocket-silo`, `low-density-structure`, `rocket-fuel`, `processing-unit` (blue
circuit), and the satellite line researched. Check the exact names and state with
`observe(view="research")`.

## Component chains

- **low-density-structure**: steel + copper plate + plastic (in assembler).
- **rocket-fuel**: solid-fuel (from light oil / petroleum) → rocket-fuel. Set up
  `chemical-plant`s for solid-fuel; consider `advanced-oil-processing` + cracking to
  balance light oil.
- **processing-unit**: electronic-circuit + advanced-circuit + sulfuric-acid.
- Scale steel, plastic, and circuits hard: these are the gating inputs. Size each line
  with `observe(view="plan")`.

## Build and launch

1. Build the `rocket-silo` with power and room (it is 9x9) with `build_design`, dry-run
   first. Check it with `observe(view="entities", x, y, radius)`.
2. Feed it low-density-structure, rocket-fuel and processing-unit with belts and
   inserters. For a manual push, `achieve(goal="insert", design=[{name, count, x, y}])`
   at the silo's centre: rocket-part ingredients go to its input, anything else to the
   rocket cargo. The silo crafts the rocket parts itself.
3. Base 2.0 has no satellite item: the rocket launches with empty cargo. Anything you
   want sent up goes in with the same `insert` (it lands in the rocket cargo).
4. Watch part production with `observe(view="flow", query="rocket-part@10m")` and the silo
   status with `observe(view="entities")`.
5. When the rocket is ready, `achieve(goal="launch", x=…, y=…)` launches the silo at that
   position. It answers `not-ready` (with the silo `status`) until the rocket is built.
   Before an irreversible visible milestone, tell the human where to look and wait for
   their go (LESSONS.md #16). **Launching the rocket is the win.**

If anything stalls, diagnose with `observe(view="flow")` and machine status, scale the
lagging input, and keep the silo fed. The real target after the first launch is a base
that keeps launching with no agent feeding it by hand.
