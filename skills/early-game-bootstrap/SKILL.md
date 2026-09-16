---
name: early-game-bootstrap
description: Use at the very start of a Factorio game (empty inventory, no automation) to go from hand-mining to the first automated iron/copper smelting. Covers locating resources, hand-mining starter materials, and placing burner miners and stone furnaces.
---

# Early-game bootstrap

Goal: get from nothing to a self-sustaining trickle of iron and copper plates.

## Steps

1. **Survey.** `factorio_get_player_state`, then `factorio_scan_resources`
   (radius ~64) to find iron ore, copper ore, coal, and stone. Note each
   patch's `center`.
2. **Hand-mine starters.** Use `factorio_mine_resource` to gather:
   - ~10 stone -> craft `stone-furnace` x2-4 (`factorio_craft`).
   - some coal (fuel) and a little iron/copper ore to kickstart.
3. **First smelting by hand.** Place a `stone-furnace` near the iron patch
   (`factorio_place_entity`), insert coal into its `fuel` inventory and ore into
   its input (`factorio_insert_items`). Pull plates with `factorio_remove_items`.
4. **Automate mining.** Craft `burner-mining-drill`s and place them on ore
   patches facing a furnace (drill output drops in front). Fuel the drills with
   coal. A burner drill feeding a furnace that you also fuel gives passive
   plates.
5. **Coal supply.** Put a burner drill on coal too, so you can keep fueling
   everything. This is the classic early bottleneck.

## Target end-state

- A handful of plates accumulating without manual mining.
- Enough plates to craft the next tier: `electric-mining-drill`, `assembling-machine-1`,
  `lab`, power (boiler + steam engine + offshore pump), and copper cable / iron
  gear wheels.

Verify progress with `factorio_get_inventory` and `factorio_scan_entities`
(check furnace/drill `status`). Then move on to the smelting-setup skill to scale
up with electricity.
