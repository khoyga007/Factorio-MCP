---
name: early-game-bootstrap
description: Use at the very start of a Factorio game (starting kit only, no automation) to go from the Freeplay kit to the first automated iron/copper smelting. Covers locating resources, gathering stone and wood, and placing burner miners and stone furnaces through the MCP tools.
---

# Early-game bootstrap

Goal: get from nothing to a self-sustaining trickle of iron and copper plates.

There is no MCP goal for hand-mining ore. You start from the Freeplay kit in your
character's inventory (the treasury) and let drills do the mining. The executor mines
trees and rocks by itself when a build or craft needs wood or stone.

## Steps

1. **Survey.** `observe(view="situation")` for the treasury and nearby ore, then
   `observe(view="deposits")` (or `resource="coal"` etc.) to find iron ore, copper ore,
   coal and stone. For a close-up of one patch use `observe(view="nearby", x, y, radius)`.
2. **Place the starting drill and furnace.** One burner mining drill on iron ore, facing
   a stone furnace so the drill drops ore straight into it. Build it with
   `achieve(goal="build_design", design=[...], contract=...)`, `dry_run=true` first.
   Use a `resources` rule so the drill really sits on ore, and a `primer` so the
   executor fuels it:

   ```json
   contract={"site":{"mode":"search"},
             "resources":[{"entity":"burner-mining-drill","resource":"iron-ore","min_total":500}],
             "primer":[{"entity":"burner-mining-drill","item":"coal","count":5},
                       {"entity":"stone-furnace","item":"coal","count":5}]}
   ```

   The primer needs coal in the treasury; `observe(view="situation")` shows how much you
   have. `tests/designs/coal-drill-chest.json` is a tested drill-into-chest layout to
   copy positions from.
3. **Fuel and feed by hand while it starts.** `achieve(goal="insert", design=[{"name":"coal",
   "count":5, "x":…, "y":…}])` tops up a fuel slot. `"source": true` puts ore into a
   furnace's ingredient slot. Pull plates with
   `achieve(goal="collect", design=[{"name":"iron-plate", "count":n, "x":…, "y":…}])`.
4. **More drills.** `achieve(goal="craft", design=[{"name":"burner-mining-drill", "count":2}])`
   (crafting only starts the queue; watch the treasury with `observe(view="situation")`),
   then build more drill-into-furnace pairs on iron and copper.
5. **Coal supply.** Put a burner drill on coal too, dropping into a chest, so you can keep
   fuelling everything. This is the classic early bottleneck. Two burner drills facing
   each other on coal fuel each other.

## Target end-state

- A handful of plates accumulating without manual work.
- Enough plates to craft the next tier: `electric-mining-drill`, `assembling-machine-1`,
  `lab`, power (boiler + steam engine + offshore pump), copper cable and iron gear
  wheels.

Verify with `observe(view="situation")` (treasury contents, issues) and
`observe(view="entities", x, y, radius)` (furnace and drill status). A layout you keep
refuelling by hand is not self-sustaining yet; that is fine for the bootstrap. Then move
on to the smelting-setup skill to scale up with electricity. Automatic ore feeding
(`{"mine":...}` rows, chain `"feed":true`) needs electric mining drills, so it starts
there, not here.
