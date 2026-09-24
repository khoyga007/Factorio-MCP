# Blueprint contract — generic executor

`achieve(goal="reuse_blueprint", pattern_id, contract?, x?, y?, radius?, dry_run?)` → Lua `executor.lua` (action `blueprint_run`). Agent designs + declares; executor checks, gathers real items, builds, primes, audits. No per-pattern code. Contract omitted → pattern's saved `contract` in `blueprints/catalog/<id>.json` → else `{}` (search around x,y, no primer, no audit).

Job id `exec-N`; read with `report(job_id)` (action `blueprint_job`). Receipt + audit + blueprint in script-output `executor/exec-N.*`. One active job at a time; repeat call returns the active job.

`report(job_id, resume=true)` (action `blueprint_job`, optional `resume`) restarts a job that already imported and then stopped: the failure happened AFTER the build, so real machines are standing and a recall + rebuild would pay for the block twice.
- Refused: `job-not-resumable` (state is not `needs-attention`) / `job-not-built` (never imported successfully — rerun the identical `blueprint_run` instead, the executor regathers).
- Re-entry is idempotent: site re-check, tree clearing, stock debit, ghost aim and `blueprint_import` are ALL skipped once `j.imported` is set (`j.placed` can legitimately be `0`, which Lua reads as true — the flag, not the count, is the guard). The `connect` checks re-run, the primer resumes from `j.primed` (a flat index over primer×matching entities), and the holdout clock restarts.
- Use after fixing the cause: a pole run built to the job, a pipe connected, a fuel problem. A failed audit is resumable too, but the primer will NOT re-fuel — put fuel in by hand first.

## Executor rules (cheat sheet)

- Inserter `direction` = pickup side (dir 0 N: picks from north, drops south). Both ends must hold a receiver or `inserter-unconnected` (see §Site).
- `pipe-to-ground` pairs need `dirB == (dirA+8)%16`, same row/column, ≤10 tiles apart, else `pipe-unconnected` (see §Site). Checked at dry_run.
- Each entity's tiles + `clearance` must contain NO own-force entity → `occupied` (per entity, not the design bounding box). `character` = a player (human or agent) stands in it: move the player, not the site.
- Trees/rocks in footprints auto-mined (products to bag). Cliffs blasted (1 `cliff-explosives` each), water tiles filled (1 `landfill` each) — see **Ground clearing**.
- Items come from bag → own chests / furnace+assembler outputs → mining → hand craft. NOT from belts.
- Job `needs-attention` with `insufficient-items` mid-build: rerun the IDENTICAL call; the executor regathers (live 19/09).
- Job `needs-attention` AFTER the import (`infra-missing:*`, a primer insert with no room, a failed audit): fix the cause, then `report(job_id, resume=true)`. Never recall + rebuild for this.
- World coords of what gets built = `placed_at`, never recompute from anchor+rotation.
- Every job is a ledger block; declare intent with `contract.block` (§Ledger).

## Ground clearing — cliffs and water

`site.mode` search rejects a cliff or a water tile ONLY when the base cannot pay to clear it. `affordable(force,stock,item)` = the item is in the treasury OR its recipe is unlocked. Otherwise the blocker is priced into the job and cleared before the build.

- Price: **1 `cliff-explosives` per cliff entity** in a footprint (the real capsule clears several cliffs per throw, so paying per cliff can never underpay), **1 `landfill` per fluid tile** under a footprint. A cliff under two footprints is paid once.
- The counts land in `materials` at plan time and in `site.blast` / `site.fill`, so `prepare()` collects and crafts them with everything else. They are added AFTER the site is chosen — `locked` is computed before that and does not cover them.
- Clearing runs after the tree/rock mine, inside the `not j.imported` block: debit first, then `cliff.destroy{do_cliff_correction=true}` / `surface.set_tiles`. Both engine calls are free, so the debit order IS the no-free-items rule, same as ghost revive.
- Landfill is read back off the ground. Tiles still fluid after `set_tiles` are refunded; a fill that moved NOTHING raises `landfill-refused:N` (a surface that cannot take landfill never becomes buildable, so waiting on it would not end).
- A short bag **parks** a ghost job (`ground` = {item: needed}, re-scan every `SCAN_TICKS`); a direct job fails with `ground-not-clear`.
- Report fields: `blasted`, `filled` (counts, omitted when 0), `ground` (what the clear step is short of).
- Water detection is `tile.prototype.fluid`, same as `survey.lua` `fluid_tile_names` and `field.lua` `M.water`. `decode` (`site.lua`) still refuses a blueprint that CARRIES tiles — a plan over water no longer needs one.
- Own-force entities are still never mined. Clearing means nature, not the base.
- Engine PASS tests/verify_ghostbuild_runtime.py (63 checks): pond under plan + landfill recipe locked → `water` reject; unlocked → `site.fill=1`, `materials.landfill=1`, job parks with `ground={landfill:1}` and the pond stays wet; landfill delivered → tile filled, neighbour tile still water, pole built, `filled=1`. Cliff with recipe locked and empty bag → `cliff` reject; one explosive in the bag → `site.blast=1`, cliff destroyed, `blasted=1`, bag charged, job `verified`.

## Ledger (base memory, build `2026-09-21-ledger-zoom`)

Stored in mod `storage` → travels with the save, survives restarts/handoffs. Only intent stored; live state recomputed per read.
- `contract.block = {id?, name, role, feeds:[{item?,block?,via?,per_minute?}], eats:[...], notes}` (name/id ≤40, role ≤120, notes ≤400, ≤12 links, link needs ≥1 field; `per_minute` = the rate the agent INTENDS that link to carry, >0 and <1e6). Bad → refused `invalid-block[-feeds|-eats]`, nothing built. Carried on job summary (`report.block`).
- Macro zoom (build `2026-09-21-ledger-zoom`). One read is never the whole base: at ~390 B/block the old flat dump is ~58 kB at 150 blocks, past a readable reply and near the datagram ceiling. Three levels, one view:
  - `observe(view="ledger")` → ROLL, size independent of block count: `{detail:"roll", blocks: n, by_status {status: n}, clusters [{id, name?, box, blocks, attention?, makes {item: per min}, machines {entity: n}}], attention [{id, cluster, error?, missing?}], edges {total, problems? [edge]}, flow_ticks}`. `attention` lists ONLY broken blocks; `edges.problems` only edges that are `missing_block`, `uncounted`, or `measured < declared/2`.
  - `observe(view="ledger", query="status:attention"|"cluster:c@x,y"|"item:iron-plate")` → ROWS: `{detail:"rows", total, blocks [row], edges? (only links touching this page), next_offset?}`, 12 rows/page, `offset` pages.
  - `observe(view="ledger", query="exec-10")` → ONE: `{detail:"one", block: row, edges: [links touching it]}`. Unknown id → `block-not-found`. Bad filter key → refused client-side.
  - Cluster = union-find over the boxes of SITE blocks only, ≤8 tiles of slack; id is `c@<left>,<top>` of the merged box, name is the first declared block `name` inside it. A block whose entities are ≥90% belts/pipes/poles/rails is a CARRIER: it attaches to the nearest cluster (counted in `blocks`, surfaced as `carriers`) but never merges two clusters and never widens a cluster box. Measured 21/09: geometry alone put 13 of 14 blocks in one cluster (a 160-tile belt spine touches everything it serves); purity alone still left that spine a site, because it carried two burner inserters, and its box stretched the cluster 160 tiles wide. With the share rule the same base reads 3 clusters, boxes tight to the machines (8+4+2 blocks, 5+1+1 carriers). Nothing to declare, but clusters DO renumber as boxes grow into each other — treat a cluster id as this-read-only, a block id as durable.
  - Row (rows/one): {id, name, role, feeds, eats, notes, status, box [x1,y1,x2,y2], n {entity: planned count}, cluster, missing?, error?, pattern_id, tick, flow?}. Edge: {from, to, item?, declared?, measured?, uncounted?, missing_block?}.
  - Rows trim flow to `{made?, active?, counted, samples}`; `ticks` is the reply-level `flow_ticks`. `counted: 0` is KEPT — it means "no machine here can count", which is not "made nothing".
  - Block identity is the entity, not the tile (build `2026-09-20-block-identity`). Each planned row is stamped with its built entity's `unit_number`; a row counts as present only when the tile holds an entity of that name AND that unit. A job whose planned entities are ALL gone (recalled, destroyed) leaves the ledger entirely, so its declared links stop reading as starved edges, and it stops being sampled for throughput.
    - `game.get_entity_by_unit_number` is NOT usable for this lookup: measured 20/09 it returns nil for an entity the mod holds, valid, in the same tick it read that entity's own `unit_number`. Hence tile-lookup-then-confirm. (`core.lua` `treasury()` still resolves the treasury chest through that call — unverified there, suspect.)
    - Belts, pipes and rails have no `unit_number`, so those rows are confirmed by tile alone; a job made purely of them can still be fooled by a rebuild on the same tiles.
  - `missing_block` on an edge: an endpoint is not a live block — a typo in `feeds.block`/`eats.block`, or a block that has since gone. Without it a link to nothing reads exactly like a producer that made nothing.
  - Job blocks: every exec job that placed anything. `status`: `verified` (audit passed), `unverified` (verified, no passing audit), `attention` (needs-attention OR any planned entity gone: `missing`=count), else raw job state.
  - Hand blocks `hand-N`: `status=declared`, `n` = live own-force entities in box (characters skipped).
  - Edges from both sides: A.feeds{block=B} and B.eats{block=A} both give {from=A,to=B,item}, deduped. "What breaks if I remove X" = every edge with X as producer.
  - `declared` = the link's `per_minute` (intent). `measured` = what the PRODUCER block actually finished in its last closed window, 0 when the window saw nothing. `declared` > `measured` is the starvation signal; both absent means nobody declared a rate and no window has closed yet.
  - `uncounted: true` REPLACES `measured` when the producer block holds no counting machine (`flow.counted == 0`: drills, belts, chests, poles). Live 20/09 the drill block exec-99 read `declared 150 / measured 0` while its drills were 84% active — a false starvation signal, because `products_finished` exists on no entity in that block. A block that CAN count and made none of that item still reports `measured: 0`, and that 0 means what it says.
- Throughput (`flow`, build `2026-09-20-flow-truth`): each block carries `{ticks, samples, made {item: per minute}, active {entity: MEAN percent of that entity's samples spent working}, counted}` from its last CLOSED window (default 3600 ticks; `storage.ledger_flow_window` overrides, tests use 300). Absent until the first window closes.
  - `active` is a mean PER MACHINE, 0..100. Until 20/09 it summed one point per working entity per sample and divided by the sample count alone, so a block of 8 furnaces read `{stone-furnace: 300}` — reported live, read as 300%. Denominator is now that name's own presence count, so an entity removed mid-window does not drag the rest down.
  - `counted` = how many machines in the block have a `products_finished` counter. `counted: 0` means `made` is empty because NOTHING here counts, not because the block produced nothing.
  - `made` is the delta of the engine's own `products_finished` over the window, mapped through each machine's current recipe — assembling machines, furnaces and silos only. A mining drill has NO per-entity counter, so a drill block reports `active` and `counted: 0`, never a `made` rate; read its output from the chest it fills, or from the machine downstream. Its outgoing edges carry `uncounted`, not `measured: 0`.
  - Known distortions, all deliberate: a machine added or removed mid-window carries its lifetime count in or out (negative deltas are dropped, so a removal reads as a quiet window, never a negative rate); a furnace whose recipe changed mid-window attributes the whole window to the recipe it ends on.
  - Sampling rides the 60-tick executor tick, ≤600 entities per tick across all blocks, resuming where the budget ran out so a big base cannot starve the last blocks in the list.
- `achieve(goal="annotate", contract={block:{id,...}})` merges given fields into block `id` (exec or hand); unknown → `block-not-found`. No id + `area=[x1,y1,x2,y2]` → registers new hand block, returns id. Neither → `block-id-or-area-required`.
- Engine PASS tests/verify_ledger_runtime.py (40 checks, re-run 21/09): bad feeds refused; `per_minute=-3` refused; character in site → `character` reject; 2 jobs + eats → edge carrying `declared=30`; note merges keep other fields; hand chest counted live + edge; chest destroyed → `attention` missing 1; report carries block; fed furnace → window `{ticks 300, samples 6, made {iron-plate 12}, active {stone-furnace 83}}` and edge `measured=12` against `declared=30`; a second hand block of TWO fed furnaces reads `active {stone-furnace: 100}` and `counted 2` (the old sum read 200), while the chest-only hand block reads `counted 0`, no `made`, and its outgoing edge carries `uncounted` instead of `measured: 0`; block a then wiped off the ground → its row leaves the ledger, b survives, and b's link to it comes back `missing_block`. Macro zoom on the same board: roll accounts for all 3 live blocks with no row (cluster counts partition them, status tally adds back up, `edges.problems` carries both the `missing_block` and the `uncounted` link), `detail="one"` returns the block plus its links, an unknown id is refused `block-not-found`, and a `cluster` filter returns only that cluster's rows.

## Reference imports (community blueprints, `catalog_add.py`)

Human-made strings enter the catalog as `state=reference`: material to READ, never something
the executor picks up on its own.
- `python catalog_add.py <file> [--url U] [--note N] [--screen-only] [--offline]`. `--screen-only`
  reports what the string is and writes nothing.
- Refused, nothing written: `not-a-2.0-blueprint:<version>` (version stamp's major field),
  `space-age-entities:<names>` (static list in `blueprint_library.SPACE_AGE`, INCOMPLETE by
  construction), `entities-not-in-this-game:<names>`.
- The authoritative compat check is the running map: every distinct entity name goes through
  `spec entity`, and the bridge build string lands in `origin.checked_against`. With `--offline`,
  or when the game is unreachable, that key is absent — the record is then UNCHECKED, say so
  rather than treating it as compatible.
- `origin = {kind: "community", url?, note?, label?, game_version, checked_against?}`. `RANK`
  puts `reference` below `designed`/`captured`/`built`/`verified`: agent work always promotes a
  reference record, and a re-import never demotes one.
- Reference records carry NO contract. `achieve(goal="reuse_blueprint")` on one is refused
  `reference-pattern-needs-contract` (reply carries `origin`) until the agent passes its own
  `contract` — that is how imported material graduates: it must be run and audited here.
- Entity cap: the executor builds ≤1000 (`BUILD_ENTITY_LIMIT` in `blueprint_library.py`, same number in `build.lua`
  `handle_blueprint_import` and `site.lua` `decode`); reference records are only read, so they parse up to 2000
  (`REFERENCE_ENTITY_LIMIT`) and report `over_build_limit`. Measured: a 508-entity starter base
  is one ghost job; the reply digests it (§Reply size), the receipt on disk keeps every row.
- `observe(view="patterns", query=?, offset=?)` pages exactly like `references`: 40 rows,
  `total` + `next_offset`, `query` matched against the pattern id, the state and the ENTITY
  NAMES (a designed pattern has no label; its entity names are the label). Null columns are
  dropped from the rows. Measured 20/09: 162 own patterns unpaged = 27 495 chars every call,
  5 762 paged (-79%); `query="stone-furnace"` = 14 rows, 2 548 chars. Rows carry `origin`
  (the kind) when a pattern has one.
- Books: `--book` flattens a blueprint-book string (nested books included) and imports every
  leaf that passes both screens, reporting the rest by reason instead of refusing the whole
  file over a few DLC pages. `origin.path` keeps the chain of book labels. `--screen-only
  --book` is a dry run over the whole book. Identical layouts across books collapse onto one
  `pattern_id` (dedup is by content).
- Reading them back: `observe(view="references", query=?, offset=?)` → compact rows
  `{pattern_id, label, book, entity_count}`, 40 per page, `total` + `next_offset`. Reference
  records are NOT in `observe(view="patterns")`: a library of hundreds would drown the reply
  (measured 20/09: 259 reference rows = 74 KB in the old shape, 5.7 KB paged).
- Raw drops live in `incoming/` — not the catalog, not verified, safe to delete.
- String/payload caps split by purpose: build strings ≤24 000 chars / 1 MB inflated (UDP),
  reference ≤200 000 chars / 20 MB, a book ≤40 MB inflated.

## Agent-authored design (`build_design`)

`achieve(goal="build_design", design=[{name,x,y,direction?,recipe?,type?}], contract, x?, y?, dry_run?)`. Agent designs from game rules (sizes, drill area/drop, inserter reach, ratios); no human template required. `design` = entity centers in tiles: odd-size entity on .5, even-size on integer (2x2 drill center `1,2`); direction 16-way 0N 4E 8S 12W. Python `encode_blueprint` → native string (≤1000 entities, bad row → `invalid-design-entity:<i>`) → same `blueprint_run` path as reuse. Not dry → catalog pattern state `designed` + contract saved; report(exec-N) verified → upgraded to `verified`. Read any saved pattern's layout: `observe(view="patterns", pattern_id)` → entities shifted by whole tiles (parity kept) + contract; edit and resubmit as `design`. Human blueprint = optional reference only.

Engine PASS 2026-09-19 (tests/verify_design_runtime.py, tests/designs/coal-drill-chest.json): 2 burner drills facing N drop straight into own chest, feed chest→drill keep 2; 4 entities, windows coal 34/36/34, active 2/2, feed 12 total. NOT self-sustaining: no physical return path, feed moved 4 every window; live exec-2 (19/09) drills went no_fuel after job end with coal still in chests. Proves the build_design path only, not a good layout. Physical closed loop found live by an agent session: belt ring + 2 burner inserters feeding drills (pattern bp-888ab81fe7579dfd, exec-3).

`report(exec-N)` → `self_sustaining` = last window `feed_moved`==0. Catalog upgrade on verified: self-sustaining → `verified`, fed → `built` only.

## Rate plan + production cells (23/09, step 3)
- `observe(view="plan", query="item@rate/min[;recipe=item:name,...]")` (`planner.py`): recipe tree from live read-only `spec` → per-recipe machine + exact/ceil count, raw per min (drills/pumps), kW, belt lanes per edge, surplus. No LP: multi-product recipes via `recipe=` override, byproducts = surplus.
  - A save running a mod that changes PROTOTYPES breaks the counts: one live save carried a separate speed mod (rocket-silo crafting_speed 1e6, asm2 750k), so every count ceiled to 1. That is not part of this project, which plays vanilla prototypes with no cheats; on such a save the real limit is inserters/belts, so size cells by `flow` and widen (count) when an output belt saturates.
- `build_design` row `{cell:recipe, x, y, count?, machine?, belt?, inserter?, long_inserter?, pole?}` (`cells.py`): `count` machines in a row, x,y = top-left TILE. Top→bottom: [belt B] belt A, input row (long|fast|pole per machine), machines, output row (-|fast|pole), output belt. All belts run east; inserters dir 0.
  - 1-2 solid ingredients: one item per belt (A = 1st, B = 2nd via long inserters), so a feed needs no lane planning. 3-4 solids: two items per belt, lane order = `items` (left = north). Fluid recipes read the machine's `fluid_ports` from `spec entity`: north inputs and south outputs connect to separate pipe buses, with matched pipe-to-ground pairs passing under solid belts. Up to two solids can share a fluid cell. Fluid ports appear in `fluid_in`/`fluid_out` as `{kind:"pipe",x,y,fluid}`; output item belt appears only when the recipe makes items.
  - Machine default = cheapest UNLOCKED machine for the category (first live try picked locked asm3).
  - 2-wide machine (furnace): per machine [fast | pole], 1 ingredient only. Furnace rows carry no `recipe` (ghost refuses it; input decides). Burner machine → `fuel` (default coal) rides belt A's 2nd lane, same inserter fuels it; chain external `per_min` = null for fuel. Live 23/09: iron-plate x3 cell planned; iron-gear-wheel@60 chain = furnace cell + gear cell, 1 edge, external [iron-ore, coal].
  - Reply carries `ports`: `in_a`/`in_b` west-end belt tile + lane items, `out` east-end tile + items, `box`. Ports are in the DESIGN frame: world only when build_design has no x,y (absolute mode) — use that, then `observe(route)` belts from/to the ports.
  - Poles connect inside the cell only. Row `power:true` (cell or chain; `pole` picks the type) adds a pole line: nearest own pole within 64 of the bbox, belt router A* from the free tile outside the box edge to a tile beside it (avoid cell boxes, belts, external feed tiles), a pole every <=7 path tiles. Live-ness is still the executor's check: `unpowered` = the reached pole has no source. Live 23/09: gear chain + gear x2 cell → +3 poles, `unpowered` null.
  - Live dry-run 23/09: gear x2 at (-236,96) absolute → `planned`, 0 unconnected inserters.
- `build_design` row `{chain:item@N/min, x, y}` (`chain.py`): plan → one producer cell PER consumer (no splitters), stacked in a column (gap 4), post-order (leaves on top). Each internal edge = routed belt child `out` → parent `in` via Lua `route` with `avoid` (cell boxes + reserved port tiles) + `planned_belts` (cell + earlier route belts, so no route sideloads into them).
  - Chain can't make it (fluid, furnace/2x2, pre-merged 3-4 ingredient belt) → `ports.external` {items, x, y, dir, cell, per_min}: agent feeds those. `output` = tile east of root out belt.
  - Live dry-run 23/09 absolute (-236,96): electronic-circuit@60 → planned, 2 cells, 1 edge, 10 route belts, 0 unconnected; fast-transport-belt@30 → planned, 4 cells, 3 edges, 56 route belts, 0 unconnected, 3 iron-plate externals.
  - LIVE BUILD 23/09 new save (tick ~50k, from vanilla start): electronic-circuit@60 at (-62,28), exec-16 ghost mode → verified; circuits on output belt row 66.5. Feeds = agent-made: electric drills (search + resource rule exclusive) → `observe(route)` → `{route:id}` rows. External port tile = EMPTY tile west of cell belt; agent puts a belt there (dir E) and side-loads ore from N (north lane) + coal from S (south lane). Two side inputs, no rear → belt stays straight (checked by `lanes`: N iron-ore, S coal). Build ore routes first, coal routes after, port belts LAST (one side input alone = curve → mixed lanes).
  - Chain routes may cross the external port's west approach (here x -63.5 column) → feed from N/S with underground; route tool finds it once chain is BUILT (router sees entities, not dry-run rows).
  - Gaps hit live 23/09, fixed 24/09 (engine suite 14/15; live 24/09 exec-19: electronic-circuit@60 anchored + power:true, 101 rows ghost, 2 bridge poles, verified, assemblers powered; replan + connect-wait not triggered live yet): >64-row designs default to ghost even with an anchor (was: anchored chain went direct → `direct-blueprint-too-large`). `power:true` tries up to 8 start tiles within wire reach of a cell pole (was: one start beside a chain belt → `power-route:from-blocked`), then adds one bridge pole per pole island no wire joins to the grid (was: cells 8 apart needed a hand pole); a gap one pole cannot bridge → `power-bridge:x,y`. `prepare` claims each planned item so later crafts cannot eat it (was: steam-engine ate the pipes); a direct job whose bag changed replans and returns to `preparing`, max 3 rounds, then `materials-changed:<item>`. `connect` checks re-run once a second for 10 s before `infra-missing` (was: boiler read dry in its build tick).

## Field actions (live play, `field.lua`)

- `observe(view="water", x?, y?, radius≤2048, offset)` → action `water_sites`. Scans every generated chunk in radius holding fluid tiles (not the capped survey index), nearest first. Shore spots tried ×4 directions, center snapped to pump footprint. `candidates` (≤12/page, `next_offset`): `can_place_entity` manual true → `{x,y,direction,output,distance}`; `output` = tile the pump's pipe must occupy (from prototype pipe_connections; engine-checked: pipe there connects). `blocked` (≤12): placeable only with `forced` ghost check → `obstacles` [{name,x,y}] trees/rocks/cliffs to clear by hand. `clusters` (≤12): chunk, tiles, per-tile-type counts. Budget 40000 checks → `truncated`.
- `achieve(goal="recall", area=[x1,y1,x2,y2] (ANY size) | design=[{name,x,y}], dry_run, force_active)` → action `recall`. Own force only, minable, no characters; trees/rocks never. Each entity `mine`d into a buffer then player bag: contents come along (chest, furnace, belt items). Bag full → spilled on ground, listed. Refuses `active-job:<id>` when a target sits in the layout of an executor job in preparing..auditing unless `force_active`. Reply: receipts per entity {items}, `delta` of bag.
  - The Lua handler still caps ONE recall at 64×64 tiles and 200 entities (`field.lua` `M.recall`, `MAX_RECALL`) — deliberately, as the safety net against an accidental base-wide recall. `factorio_goal_mcp.py` slices a bigger `area` into ≤64 pieces and sends one bridge call each, so a long pipe or belt run is one agent intent again. Reply gains `slices` / `slices_done`; receipts, `delta` and `spilled` are merged, rows deduped by name+position (an entity straddling a cut is returned by both slices; in a real run the first slice already mined it, so only a dry_run can see the duplicate). An empty slice answers `nothing-to-recall` and is skipped; any other slice error stops the sweep and returns what had already been recalled — recall is destructive, so partial progress is reported, never swallowed. A per-slice `too-many-entities` (>200) still means that 64×64 piece is too dense: recall it by `design` instead.
- Engine PASS 2026-09-19 tests/verify_field_runtime.py: pond + tree-lined shore → candidates on free shore, tree spots in blocked with obstacles, pump at candidate + pipe at output connects; recall chest(10 plates)+belt(1 coal)+furnace(7 ore)+inserter → exact delta, tree untouched, active job refused.

## Schema

```json
{
  "site": {"mode": "search|exact|absolute", "ref": {"x": 0.5, "y": 0.5}, "rotations": [0,4,8,12], "clearance": 1,
           "enemy_radius": 16, "max_checks": 20000},
  "build": {"mode": "ghost|direct"},
  "resources": [{"entity": "burner-mining-drill", "resource": "coal",
                 "min_per_tile": 100, "min_total": 800, "full_cover": true, "exclusive": true}],
  "primer": [{"entity": "burner-mining-drill", "item": "coal", "count": 5}],
  "feeds":  [{"from": "wooden-chest", "to": "burner-mining-drill", "item": "coal", "keep": 2}],
  "connect": [{"entity": "boiler", "fluid": "water"}, {"entity": "steam-engine", "power": true}],
  "declared_load_mw": 0.3,
  "verify": {"window_ticks": 3600, "max_windows": 5, "settle_ticks": 0,
             "metrics": [{"key": "coal_gained", "kind": "container_gain",
                          "entity": "wooden-chest", "item": "coal", "min": 20}]}
}
```

Unknown keys ignored (notes: `source`). Contract errors (refused, nothing built): `invalid-build-mode`, `invalid-site`, `absolute-site-needs-ref`, `invalid-rotation`, `exact-site-needs-one-rotation`, `invalid-connect`, `invalid-declared-load`, `invalid-metric[-item|-fluid|-fraction|-load-fraction|-min]:<metric key>`, `declared-load-required:<metric key>`.

## Site

- Three site modes:
  - `absolute` (**recommended for `build_design`**): the design rows ARE world entity centres and are built where they stand. `site.ref = {x, y}` is the world position of the FIRST design row; the executor derives the anchor from it, so the agent does no floor/min-corner math. Missing or non-finite `ref` → `absolute-site-needs-ref`. Every `exact` rule applies (one rotation, no search). `build_design` with no `x,y` AND no `contract.site` fills this in by itself (`ref` = row 1's `x,y`).
  - `exact`: anchor = `floor(x), floor(y)` of the `x,y` passed to `achieve` (see the last bullet of this section for what that `x,y` must be).
  - `search`: `x,y` = search centre (default: the treasury player's position), `radius` limit.
- Anchor = top-left TILE EDGE of the rotated blueprint footprint (`min(entity.x - tile_width/2)`), NOT an entity centre.
  - Two frames, build `2026-09-21-exact-anchor`: every `bbox` the bridge reports (`plan.bbox`, a pattern's `layout.bbox`) is measured in entity CENTRES, while the anchor is a tile EDGE. They differ by half a footprint, and the half differs per prototype: a 3x3 drill centres on `.5`, a 2x2 furnace on an integer, a 1x1 pole on `.5`. So NO floor() of a bbox is the anchor. Measured 21/09 (exec-21..24): a peer session floored the centre bbox, every rebuilt row landed one tile east of the ghosts a human had placed, and the job revived its own second set.
  - `capture(area)` and `build_ghosts(area)` therefore return `site {x,y}` — the exact anchor, computed in Lua from `create_blueprint`'s blueprint-index -> source-entity mapping, so it covers exactly the entities the blueprint holds, ghosts included. Hand that back to `reuse_blueprint` with `site.mode="exact"`; never re-derive it. Engine PASS tests/verify_ghostbuild_runtime.py: three mixed footprints (drill 3x3 at `.5`, furnace 2x2 at integer, pole 1x1 at `.5`) export anchor `(-29,-11)`, the anchor round-trips through `blueprint_run`, and the planned centres come back exactly where the ghosts stand.
- Rotations 16-way units, default `[0]`. `exact` needs exactly ONE rotation (agent placed water/pole for that orientation; spinning would miss them). Rotation turns every entity position AND direction; W/H swap for east/west entities.
- Candidates, nearest first: with a resource rule → every anchor putting the rule's first matching entity's top-left tile on an ore tile; else square scan ≤64 tiles. Budget `max_checks` (≤20000) → `search-budget-exhausted`.
- Per candidate, reject reason counted: `out-of-area`, `occupied` (own-force entity inside SOME entity's own tiles + `clearance` — NOT the design bounding box: a layout whose pole run reaches 10 tiles away does not claim the base in between; the bbox is only a fast path, one count query, and only a non-zero count triggers the per-entity pass), `character` (only own characters there: player in the way), `enemies` (within `enemy_radius`), `collision` (`can_place_entity` manual check, every entity; a failure whose footprint holds only trees/rocks passes if a `forced` blueprint_ghost check passes → clearable), `cliff` (cliff inside footprint AND no explosives in bag, recipe locked), `water` (fluid tile under footprint AND no landfill in bag, recipe locked), `foreign-resource`, `resource-cover`, `resource-reserve`.
- Resource rule area = `mining_drill_radius` of that entity (burner drill: its 2x2). `full_cover` (default): every tile in area holds `resource` ≥ `min_per_tile`. `exclusive` (default): other resource in area rejects. Sum ≥ `min_total`.
- None fits → `state=blocked, error=no-site, rejects={reason: n}, checks`. `rejects.at` carries up to 8 `[name,x,y]` of what actually stood in the way (added 20/09: `occupied: 1` with no tile is a treasure hunt). Agent picks a new area / relaxes contract.
- `build.mode="ghost"` + `site.mode="exact"` (or `absolute`): `occupied` and `collision` stop counting as rejects. The agent named the tiles; the engine gets to decide per entity, and drain() reports the ones it refuses. Every other reject (`character`, `enemies`, `cliff`, `water`, resources, `no-power`) still stands.
- Inserter ends (after site found, before any debit, dry_run too): every inserter's pickup AND drop tile (prototype `inserter_pickup_position`/`inserter_drop_position`, dir 0 = pickup north, rotated by dir) must hold a receiver: planned entity of a receiver type (belt/underground/splitter/loader, chest, furnace, assembler, lab, drill, boiler, turret, wagon, silo...) or an existing own-force one. Else `state=blocked, error=inserter-unconnected, unconnected=[{inserter:[x,y], side:pickup|drop, tile:[x,y], hint?}]`. `hint={entity, from, to, design_shift:[dx,dy]}` only when exactly one planned receiver one tile away covers the tile, the move clashes with no planned entity AND lowers total gaps; `design_shift` is in the agent's design frame (rotation undone). Never auto-moved: agent edits design and resubmits (19/09: pre-build check + hint over post-build snap — no wasted build, catalog blueprint = what was built, no guessing when a machine serves several inserters). Engine PASS tests/verify_inserter_runtime.py: lab 1 tile off → drop gap + shift [-1,0] (also under rotation 4), fixed → planned, pickup from existing belt counts, engine pickup/drop positions match.
- Underground pipes (after the inserter check, before any debit, dry_run too), build `2026-09-20-pipe-pairs`: every `pipe-to-ground` in the layout must have a partner. MEASURED in the engine, not assumed: the prototype carries a `normal` connection facing the entity's own direction and an `underground` connection 8 (180 degrees) away, `max_underground_distance` 10 — centres exactly 10 apart link, 11 do not. So a pair needs `dirB == (dirA+8)%16`, same row/column, distance ≤ 10. Partners may be planned in this layout OR already built (own force). Else `state=blocked, error=pipe-unconnected, unconnected=[{pipe:[x,y], dir, reason}]`, nothing built.
  - `no-partner` (+`within`): nothing of that name down its tunnel inside range — run one tile too long, or the other end missing.
  - `wrong-facing` (+`at`, `found_dir`, `expected_dir`): the first same-name underground down the ray does not face back. It steals the pairing, so reporting "no partner" would send the agent looking in the wrong place.
  - Both ends report independently, so a too-long run comes back as two rows.
  - Engine PASS tests/verify_pipe_runtime.py (7 checks): the prototype facts are pinned (a future Factorio changing them fails here, not silently in play), paired run planned, 12-tile run refused at both ends, mirrored-direction pair refused `wrong-facing`.
- Reply size, build `2026-09-20-plan-digest`: every plan and job reply carries `plan`
  `{count, entities:{name:n}, bbox:[x1,y1,x2,y2]}`, NOT a row per entity. MEASURED on exec-45
  (508 entities): `placed_at` 15829 chars, `plan` 272 — 98.3% cut, and `report` used to repeat
  those 15829 on every poll. `placed_at` [[name,x,y,dir]] world coords is still there behind
  `detail:true` (bridge + `--detail` on `blueprint-run`/`blueprint-job`), and the artifact
  receipt on disk always holds the full rows. The MCP `report` tool has no `detail` flag: the
  three-tool schema is ~4 bytes under its 4000-byte budget, so read the receipt instead.
- Direct build caps at 64 entities (`build.lua` handle_place, `direct-blueprint-too-large`,
  `{entities, limit}`); ghost mode caps at 1000. A 194-belt run is four direct jobs — that
  cap is a reason to PREFER `build.mode="ghost"`, not a reason to hand-cut a plan.
- To build at a known place, prefer `absolute` (above): write the design in world centres and
  pass no `x,y`. An `exact` site needs `x,y` on `achieve` AND `site.mode="exact"`; without x,y
  the executor searches and the design lands somewhere else entirely (measured 20/09: a dry
  run moved a site to (-8,82)). That `x,y` is the footprint's top-left TILE EDGE:
  `x = floor(min over rows of (entity.x - tile_width/2))`, same for `y` with `tile_height`.
  NOT `floor(min x)` of the centres: that is off by up to half a footprint whenever the
  extreme row is wider than one tile (a 3x3 drill centred at `1.5` has its edge at `0`).
- Ghosts in reads, build `2026-09-20-ghosts-visible`: ghosts are plans, not machines, and
  `ENTITY_TYPES` never listed them — a pasted blueprint read back as an empty field (20/09:
  a human pasted one, `observe` returned 0 entities, only `capture(area)` saw it). Now
  `observe(view="entities")` carries `ghosts` / `ghosts_total` / `ghosts_next_offset`
  (rows `{ghost=true, name, type, x, y, direction, bounding_box}`, paged like entities) and
  `observe(view="nearby"|"situation")` carries `ghost_total`, `ghost_counts` (per name) and
  `ghost_box`. Built machines stay in `counts`; the two are never mixed.
- Geometry check, build `2026-09-20-ghosts-visible`: `import-geometry-mismatch:<i>:<why>`
  and `layout-broken:<i>:<why>` now name the row — `name@x,y missing` or
  `name@x,y dir D built E`. An index alone sent the agent hunting (exec-10). An entity
  whose prototype has `supports_direction=false` (electric poles) is compared on presence
  only: the engine drops a direction that prototype cannot hold, so a rotated layout plans
  dir 4 and the ground honestly reports 0. Position, name and every directional entity stay
  strict — this check is still the guard against a bad paste.
- Several live jobs, build `2026-09-20-multi-job`: `blueprint_run` no longer hands back
  whatever job is running. Up to `MAX_LIVE_JOBS` = 8 jobs may be preparing/building/
  settling/auditing at once, so parked ghost plans do not block the next build.
  - Same blueprint + same surface + same requested x,y as a live job = that job's summary,
    not a second one. Polling `blueprint_run` is still safe; a different anchor is a
    different build.
  - Tiles a live job's layout claims are not a site: `check_site` rejects them (`rejects.job`),
    so a search finds another spot and an exact site comes back `blocked`. Ghosts do not
    collide, so nothing else would have caught two plans overlapping.
  - Over the cap: `state=blocked, error=too-many-live-jobs, jobs=[ids], max`.
  - A job that revived nothing on its pass is re-scanned every `SCAN_TICKS` = 60 instead of
    every tick (it is waiting on materials, not on CPU); that also stops 8 parked jobs from
    rewriting 8 receipt files 60 times a second.
- `supply` [{x,y}] (max 8), build `2026-09-20-supply-chests`: the chests a job may take from.
  - `prepare()` gathers from THESE chests only when the list is set; with no list it keeps
    scanning every container/furnace/assembling-machine inside `radius` (default 192).
  - A parked ghost job restocks itself every 600 ticks: for each item in `waiting` it reads
    the declared chest and collects `min(short, in_chest)` (a plain `collect` refuses a
    partial pull, so asking for the full shortfall would take nothing). Counts land in
    `restocked {item:n}`; a short chest is NOT a job failure -- waiting is the state.
  - No `supply` = the loop takes NOTHING. Engine-checked: an undeclared chest holding the
    exact item the job waits for is still full afterwards (`undeclared-chest-untouched`).
  - Receipts for restock pulls stop at 200 rows so an hours-long wait cannot grow the file
    without bound.
- `prepare()` plans every item in the cost, not just the ones before the first shortfall
  (it used to `break`); `missing` still names whatever came up short.
- Water inlet, pole, load: NOT searched/provisioned (PORTING §2); agent builds them, executor checks via `connect`:
  - `{entity, power: true}`: pre-build, every matching entity inside the supply area of a pole that REACHES A LIVE GRID (§Poles), else reject `no-power`. Post-build, `electric_network_id` set with a source on it.
  - `{entity, fluid}`: post-build, before primer: some fluidbox for that fluid (filter) connects to an entity NOT built by this job. Else `needs-attention: infra-missing:<fluid|power>:<entity>@x,y`; built entities stay, primer NOT spent. Connect the pipe, then `report(job_id, resume=true)`.

## Materials

Cost = place items of every entity + primer item × matching entity count. Plan order: treasury (player) → own chests / furnace+assembler outputs in radius (`collect`) → trees/rocks for wood/stone (`mine`) → hand craft (enabled recipe, category in character `crafting_categories`, depth ≤6). Missing or tech-locked → `blocked` + `missing`/`locked`, nothing debited. `dry_run` = site + plan, no debit.

## Build

Re-check site + stock right before build. Then trees/rocks inside any entity footprint (tile box, not margin) `mine`d → products to bag, receipt each, `cleared` = count on the job (once). `dry_run`/job `site.clear` = count to clear. Nature outside footprints untouched (trees absorb pollution). Engine PASS 2026-09-19 tests/verify_clear_runtime.py: chest+furnace in forest + big-rock → 6 cleared, footprints empty, tree outside kept, wood+stone in bag; cliff under site with no explosives and the recipe locked → `cliff` reject, cliff intact; with explosives in the bag the same site quotes `cliff-explosives` in `materials`. Exact landing of native `build_blueprint` found by a ghost probe (ghosts built then destroyed, zero items), then `blueprint_import` direct mode at the corrected position with rotation. Every entity must then sit at its planned position/direction or `import-geometry-mismatch`. Primer inserted from treasury (receipt per insert). Primer is the LAST executor mutation.

## Poles and power

- Blueprint import = ghost `revive`: no hand-style auto-wire (live 19/09 exec-15/16: 4 poles isolated, 5 inserters `no_power`). Fix build `2026-09-19-pole-wiring`: each revived pole copper-wired to every own pole within min(both max_wire_distance), nearest first, ≤5. Receipt row `wires`=count. Poles built before this build stay isolated: recall + rebuild.
- Pre-build `connect power` (build `2026-09-20-resume-power`): the entity must be covered by a FED pole. Nodes = the layout's own poles + every own-force pole whose position is inside the layout bbox grown by 32. A node is fed when (a) its `electric_network_id` is a live network, (b) its supply area covers a producer THIS layout brings (a steam build powers its own substation), or (c) wire reach `min(a.max_wire_distance, b.max_wire_distance)` links it to a fed node — spread to a fixed point.
  - Live network = some own-force producer on this surface (generator, burner-generator, solar, EEI, fusion, accumulator with `energy>0`) sits on that `electric_network_id`. Whole-surface scan, memoised per tick, computed only when a power rule exists.
  - BEFORE: any pole in the layout satisfied the pre-check, so a design carrying its own pole always passed — including `dry_run` — and died AFTER the build on `infra-missing:power`, machines already on the ground. Solar counts even at night (deterministic); an accumulator at 0 J does not.
- Post-build `connect power`: entity network must hold a source (same list) — island of poles → `infra-missing:power:<entity>@x,y`.
- Engine PASS tests/verify_metrics_runtime.py: 2 layout poles chain to pre-placed pole+EEI, same network, lab verified; same layout far away → refused pre-build with `no-power`, nothing built.
- Engine PASS tests/verify_power_runtime.py (14 checks): lab + near pole + pole 7 tiles out — a chest parked in the empty middle of the bbox does NOT read `occupied`, a chest on the lab's own tiles does; same design out of wire reach → `no-power`, same design where the far pole reaches a live grid → `planned`; resume (below).

## Research (`build.lua` handle_research)

- `observe(view="research")` → current, progress, `queue`, `labs` {status→count on surface}, `available` (enabled, unresearched, prerequisites met).
- `achieve(goal="research", tech)` → `force.add_research`: starts or appends to queue; 2.0 accepts a tech whose prerequisites are researched OR already queued. Refused → `cannot-queue` + `missing_prerequisites`, `current`. Unknown → `technology-not-found`.
- `achieve(goal="set_recipe", design=[{x,y,recipe}])` → one `set_recipe` bridge call per row, in order. Fills BLANK assemblers only: the Lua handler (`build.lua` `handle_set_recipe`) refuses a machine that already holds a different recipe (`recipe-already-set` + `current`) or any item in input/output/dump/trash (`assembler-not-empty`); same recipe → ok with `unchanged: true`. Also refused: `recipe-not-found`, `technology-locked`, `recipe-category-not-supported`, `assembler-not-found` (radius 0.1 around x,y, own force).
  - Reply `{set:[...], failed:[{x,y,recipe,error,current}]}`, `ok` false if ANY row failed — partial work is kept and named, never rolled back. Per-row calls exist so a failing target identifies itself; a batch of 6 costs 6 UDP round trips.
  - `design` rows carry `recipe`; no top-level recipe arg (schema byte budget). No `dry_run`: the handler has none.
- `achieve(goal="craft"|"collect"|"insert", design=[{name,count,x?,y?,source?}])` — hand work
  with no blueprint behind it, added 20/09 because the MCP-only rule left no path to feed a
  furnace or stock the bag. One bridge call per row, in order, at most 8 rows. Reply
  `{rows:[{name, ok, error?, count, requested?, slot?, remaining?, source_remaining?,
  player_total?, have?, need?, craftable?}]}`, `ok` false if ANY row failed; partial work is
  kept and named, never rolled back (same shape as `set_recipe`).
  - Rows reuse `design` instead of new `recipe`/`item`/`count`/`source` parameters: the
    three-tool schema has single-digit bytes of headroom under 4000. Row `x`/`y` fall back to
    the call's own `x`/`y`; `craft` ignores both.
  - `craft` wraps `handle_craft`: it only STARTS the hand-craft queue (`crafting-started`), so
    the items appear in the bag over the following ticks — read them back with `observe`.
    Cheat mode is forced off for the call, so a receipt always debits the inputs. Refusals:
    `insufficient-ingredients` (+`need`,`craftable`), `technology-locked`, `recipe-not-found`,
    `crafting-requires-player-treasury`.
  - `collect` wraps `handle_collect`: chest/furnace/assembler output (or ground items) at
    radius 0.1 around x,y → bag. Refusals: `insufficient-items` (+`have`,`need`),
    `player-inventory-full`, `entity-not-found`. `recall` is NOT a substitute: it destroys
    the machine.
  - `insert` wraps `handle_insert`: bag → fuel slot by default; `source: true` picks the
    furnace ore slot (lab/assembler/ammo-turret get their input slot, chests storage).
    Refusals: `insufficient-items`, `fuel-not-accepted`/`input-rejects-item`,
    `insufficient-input-capacity`, `insert-failed-refunded`.
  - No Lua change: all three handlers have existed since the CLI days and are in
    `actions.json`. An MCP restart is enough; the game does NOT need restarting.
- `achieve(goal="capture", area=[x1,y1,x2,y2], contract?)` → blueprint_export of a built area → catalog `captured` + `layout` (design rows). Resubmit via build_design/reuse_blueprint to verify.
- Engine PASS 2026-09-19 tests/verify_metrics_runtime.py: queue automation→logistics, unknown refused; drill→furnace products_finished 7/window verified; 1 powered lab 40 packs research_units 9.8/window ≤ speed cap, verified.

## Ghost build (`build.mode="ghost"`, build `2026-09-20-ghost-build`)

`achieve(goal="build_ghosts", area=[x1,y1,x2,y2])` builds the ghosts that are ALREADY on the
ground (build `2026-09-21-exact-anchor`). Ghosts a human pasted had no goal that adopted them;
the workaround was `capture` then `reuse_blueprint`, which re-derived the frame and laid a
second ghost set beside the first. This goal exports the area, hands the export's own anchor
straight back to the run with `site.mode="exact"` + `build.mode="ghost"`, so every layout row
lands on the ghost already there and drain() adopts it. Returns `site_requested` and
`ghosts_captured`. Normal ghost-mode payment rules apply: nothing is built free.

The plan goes on the ground first and pays for itself as stock arrives, instead of being
refused for what is missing at the moment it is submitted.

- No native paste. MEASURED `tests/verify_ghost_runtime.py`: `build_blueprint` over a FOREIGN
  entity overlapping one planned tile returns ZERO ghosts — the engine refuses the whole
  paste (`paste_foreign_entity_overlaps` 0 vs `paste_clean` 3). It skips quietly only when an
  IDENTICAL entity already sits there (`paste_same_entity_present` 2). So ghost mode sets one
  `entity-ghost` per layout row itself; `aim()` is unused (the layout is already absolute).
- Per executor tick, ≤12 entities: tile already holds the right entity → done; ghost missing →
  re-placed (no ghost-expiry field exists in this API build, so lifetime is not trusted,
  `replaced` counts it); tile unbuildable (`can_place_entity` manual false) → `blocked`;
  stock short → `waiting`; otherwise **debit `stock.remove` FIRST, then `revive`**. `revive()`
  builds for free (measured), so that order IS the no-free-items rule. Refund on any failure.
- Job stays in `building` while anything is pending — no new state, so every guard, ledger row
  and report path that knows `building` keeps working. `report` gains `pending`, `waiting`
  {item: count}, `blocked` [{name,x,y}], `replaced`.
- Nothing pending but something blocked → `needs-attention`, `error=blueprint-blocked:<n>`, the
  tiles named. Free the tile, `report(resume=true)` continues from there.
  - `blocked` rows carry `by` (build `2026-09-21-exact-anchor`): the names of what actually
    stands on that tile, deduped. `blueprint-blocked:23` and nothing else made the caller list
    ghosts by hand to find out (21/09, exec-24, where the blocker was the job's OWN drill).
  - `report` passes through what the executor already knew and the MCP whitelist used to drop:
    `blocked`, `pending`, `waiting`, `standing`, `built`, `existing`, `replaced`, `replaced_at`,
    `drift`. Adding a field in Lua is half the change; the Python whitelist is the other half.
  - `drift` (≤8 rows `{name,x,y,found_x,found_y}`): a ghost of the same name sits within a tile
    of a planned row but not ON it, and this job did not put it there. That means the layout is
    anchored off by that much and the job is about to lay a second ghost set beside someone
    else's. It is reported, not silently merged.
  - `achieve(goal="drop_ghosts", pattern_id="exec-N", dry_run?)` / action `drop_ghosts {job_id, dry_run?}`
    removes the ghosts THIS job laid and nothing else. Ownership: `ghost_units` (unit_number of
    every ghost drain() placed, recorded since build 2026-09-21-drop-ghosts) → `ownership:"recorded"`;
    older jobs → `ownership:"legacy-floor"`, floor = lowest unit_number still standing at the job's
    `replaced_at` tiles, and a ghost at a planned tile with the planned name counts as the job's
    when unit >= floor (unit numbers rise with creation, a human's earlier ghosts stay below).
    No recorded units and nothing standing at `replaced_at` → `ghost-ownership-unknown`, nothing
    touched. Refuses a live job (preparing/settling/auditing) with `job-still-live`; a parked
    `building` job is fine. Reply: `removed`, `removed_by_name`, `removed_at` (≤40), `kept_foreign`
    (adopted human ghosts left alone), `ownership`, `floor`. After a real drop the job is
    `needs-attention`/`ghosts-dropped` and `resume` answers `job-ghosts-dropped`. Always dry_run first.
  - `contract.build.skip_locked=true`: items whose recipe is not unlocked leave the plan instead of
    blocking it (default still: any locked item → `blocked`, nothing debited). Their ghosts stay
    standing, untouched; reply + report carry `skipped_locked {entity:n}`. All locked → `blocked`
    `nothing-unlocked`. With an exact site the anchor is moved by the min-corner shift the dropped
    rows cause, so kept rows land on their own tiles (engine: locked chest as left-most row, the
    un-moved anchor built a wooden chest OVER the human's iron-chest ghost). build_ghosts passes
    the caller's `contract.build` options through; only `mode` is forced to ghost.
  - Inserter-ends check: a standing own-force GHOST of a receiver type on the end tile counts as
    connected (it will exist). This is what lets a feed layer build while its skipped
    assembling-machine-2 ghosts wait. Nothing planned, nothing standing, no ghost → still
    `inserter-unconnected`. Blocked replies carry `skipped_locked` too.
  - `roboport` is a receiver type (inserter ends), and `insert` into a roboport routes robots to
    `roboport_robot` (slot "robot") and repair-tool items to `roboport_material` (slot "material").
  - Bots mode: `contract.build={"mode":"ghost","revive":false}` (also through build_ghosts). The job
    lays/adopts ghosts and NEVER revives: no preparing steps (`steps:0`), no restock, no bag debit.
    Construction robots build from the logistic network; the job stays `building` until every row
    holds its entity, then audits as usual. A row whose ghost this job saw and that now holds the
    entity counts as `built`, not `existing`. `uncovered` = planned rows outside every roboport's
    construction area (warning only). `revive:false` without ghost mode → `revive-false-needs-ghost-mode`.
- A blueprint entity's `recipe` rides through decode → orient → place_list → ghost, and is set
  again after revive if the ghost lost it (receipt `recipe_lost` when even that fails).
- Ghost report counts, measured in `tests/verify_ghostbuild_runtime.py`: `placed` = tiles that
  hold the right entity NOW (includes what was already standing), `built` = the ones this job
  revived and paid for, `existing` = the ones that were already there. A re-run over a finished
  site reads `built:0 existing:N`. `replaced` (+ `replaced_at` [[name,x,y]], max 8) = ghosts
  drain() had to set again because they were missing — never an upgrade in place.
  `step` is clamped to the number of steps.
- In ghost mode the `preparing` steps (collect/mine/craft) are best-effort: a step that fails
  at run time (the chest emptied, an ingredient the base does not make yet) is skipped and
  named in `skipped` [[action,item,error],...] instead of ending the job. Direct mode still
  fails on the step. A shortfall that survives preparing comes back as `waiting` in building.
- A character never refuses a ghost site: `check_site` reports `rejects.characters` and plans
  anyway (direct mode still rejects `character`), and a tile a character is parked on comes back
  in `standing` (name + x,y), counted as pending, NOT in `blocked` — it walks away by itself.
  A tile blocked by a character AND anything else is still `blocked`.
- Missing materials do NOT block the run (locked technology still does). Entity cap for the
  whole blueprint is 1000 (`build.lua` + `site.lua`), not the old 64.
- Engine PASS `tests/verify_ghostbuild_runtime.py` (18 checks): 70-entity blueprint planned;
  1-of-2 affordable chests built, rest ghosted with `waiting` naming the item; stock inserted
  → finishes with no new call; blocked assembler named with coords and NOT charged; blocker
  removed + resume → built, recipe intact, charged exactly once.

## Holdout audit (PORTING §5, stricter than FLE)

- After primer: wait `settle_ticks`, then windows of `window_ticks`. No executor action in windows except declared `feeds`.
- Samples every 60 ticks. Layout broken (entity missing/moved/rotated) → `needs-attention: layout-broken:<i>`.
- Metric kinds (all compare `value >= min`; `min` required unless `load_fraction`):
  - `container_gain` {entity,item} (item required): item count at window end − start, summed over matching chests. Net: feed withdrawals count against it.
  - `working_count` {entity, fraction=0.8}: number of matching entities with status `working` in ≥ fraction of samples. Wrong for rate-limited consumers: stone furnace 0.3125 ore/s > burner drill 0.25 → idles ~20%, fails 0.8. Use `products_finished`.
  - `products_finished` {entity furnace|assembling-machine}: Σ `products_finished` window end − start over matching entities. Crafts, not item count (1 craft may yield >1).
  - `research_units` {entity lab}: Σ over job labs with status `working` of Δtick × researching_speed × (1+force.laboratory_speed_modifier) × (1+module speed) / current research_unit_energy. Own labs only (force research_progress would count every lab on the map — first draft did, 10.6 units/window from 1 lab, dropped). Estimate at 60-tick sample grain.
  - `electric_output_mw` {entity}: mean over samples of Σ `energy_generated_last_tick`×60 /1e6. Real output, zero without load. Alt to `min`: `load_fraction` (+opt `capacity_mw`) → min = load_fraction×min(`declared_load_mw`, capacity_mw); top-level `declared_load_mw` then required.
  - `fluid_temperature` {entity, fluid="steam"}: min over samples of max fluid temperature in entity fluidboxes (0 if absent).
  - `fuel_min` {entity}: min over samples of fuel-inventory items + 1 if still burning.
- Stop when windows ≥ `max_windows` (≤8), or ≥2 windows and the FIRST metric did not increase vs previous window. PASS iff the LAST window meets every metric. Max alone never passes (buffers draining inflate early windows).
- Every window stored: ticks, samples, values, passed, `feed_moved`.

## Feeds

Declared local loop: move real `item` from this job's own `from` chest into each `to` entity's fuel slot, topping to `keep`. Runs only while the job settles/audits; stops at verified. `feed_moved` per window + total `feed` in report show how much the design leans on it. A design that needs a feed forever is not self-sustaining — agent should design fuel logistics (e.g. drills facing each other) or rely on autofuel, knowingly.

## Saved contracts

- `bp-f30d8a84af3098ee` (2 coal drills): LEARNING_PROGRESSION §8.2. Engine PASS 2026-09-19: windows coal 35 → 32, active 2/2, feed 0 → 4.
- `bp-985eb5fc230538b4` (steam 1:2): §8.3. `exact`, rotation [0] saved (agent overrides for its site). No saved load: agent MUST pass `declared_load_mw` (≥0.1) → power min 0.95×min(load,1.8). `connect`: boiler water, engines power. Rotation 0 footprint 3×14, boiler water inlets (anchor −0.5, +11.5) and (+3.5, +11.5). Engine PASS 2026-09-19 (tests/verify_steam_runtime.py): real water pipe, radar 0.3 MW → windows 0.3 MW, 165°C, fuel 5; no-water job stops `infra-missing:water`, coal untouched.

## Resume (build `2026-09-20-resume-power`)

Engine PASS tests/verify_power_runtime.py: a verified job is forced to `needs-attention` (stands in for `infra-missing`), `resume` on it returns `state=building` and it re-verifies; the chest is still ONE entity and still holds exactly ONE coal, `j.primed` unchanged. `resume` on a verified job → `job-not-resumable`; on an unknown id → `executor-job-not-found`.
