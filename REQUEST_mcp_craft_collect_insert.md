# Request → Opus (tool lane): MCP gaps found 2026-09-20 (agent, new save)

maintainer rule 20/09: Factorio play = MCP tools only (achieve/observe/report). No factorio_ai.py, no scripts. These 3 actions have NO MCP path today, so play stalls:

1. **craft** — recipe,count → bag. Needed: electric-mining-drill, inserter, stone-furnace, transport-belt (executor reports `missing`, never crafts). Existing CLI: `craft recipe count` (control.lua handler exists).
2. **collect** — item,count from chest/machine output at x,y → bag. Needed: plates from temp furnaces (exec-6 at y=52; exec-9 furnaces (-78..-84, 5|10)), coal from chest (-100.5,58.5). Existing CLI: `collect item count x y`. `recall` is no substitute (destroys the machine).
3. **insert** — item,count into fuel slot / `source` slot at x,y from bag. Needed: wood/coal into furnaces & boilers, ore into furnaces. Existing CLI: `insert [--source] item count x y` (control.lua handle_insert ~L1218).

Proposal: extend `achieve` goals with `craft`, `collect`, `insert` wrapping the existing handlers (same contract style: refuse with named error, no free items, real bag only). Also useful: `observe(situation)` already gives bag+position — fine.

Also noted (no action): executor rotation via contract `site.rotations` works for catalog modules; verified dry-run 20/09.

State: iron drill module exec-7 at anchor (-76,4) belt W; temp smelters exec-9. Catalog: bp-f0f00e68ca336e8b (maintainer's 8-drill module, E-flow), bp-6e9cc4d974666961 (power plant).
