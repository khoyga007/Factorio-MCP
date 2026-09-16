---
name: early-game-bootstrap
description: Use at the very start of a Factorio game (empty treasury, no automation) to go from hand-mining to the first automated iron/copper smelting. Covers locating resources, hand-mining starter materials, and placing burner miners and stone furnaces.
---

# Early-game bootstrap

Goal: get from nothing to a self-sustaining trickle of iron and copper plates.

## Steps

1. **Survey.** `brief` (base state) then `index` to find iron ore, copper ore, coal and
   stone across the map; note each patch's `x`/`y` bin. Use `snapshot --x --y --radius`
   for a close-up of one patch.
2. **Hand-mine starters.** `mine <name> <x> <y>` to gather:
   - ~10 stone -> `craft stone-furnace 4`.
   - some coal (fuel) and a little iron/copper ore to kickstart.
3. **First smelting by hand.** `place stone-furnace <x> <y>` near the iron patch,
   `insert coal <n> <x> <y>` into its fuel slot and `insert iron-ore <n> <x> <y>` into
   its input. Pull plates with `collect iron-plate <n> <x> <y>`.
4. **Automate mining.** `craft burner-mining-drill`, then `place` them on ore patches
   facing a furnace (drill output drops in front). `insert coal <n> <x> <y>` the drills
   (insert puts coal in a burner's fuel slot).
   A burner drill feeding a furnace you also fuel gives passive plates.
5. **Coal supply.** Put a burner drill on coal too so you can keep fueling everything.
   This is the classic early bottleneck.

## Target end-state

- A handful of plates accumulating without manual mining.
- Enough plates to craft the next tier: `electric-mining-drill`, `assembling-machine-1`,
  `lab`, power (boiler + steam engine + offshore pump), and copper cable / iron gear
  wheels.

Verify with `brief` (treasury contents, machine status) and `snapshot` (furnace/drill
status). Then move on to the smelting-setup skill to scale up with electricity.
