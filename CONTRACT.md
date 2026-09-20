# Blueprint contract — generic executor

`achieve(goal="reuse_blueprint", pattern_id, contract?, x?, y?, radius?, dry_run?)` → Lua `executor.lua` (action `blueprint_run`). Agent designs + declares; executor checks, gathers real items, builds, primes, audits. No per-pattern code. Contract omitted → pattern's saved `contract` in `blueprints/catalog/<id>.json` → else `{}` (search around x,y, no primer, no audit).

Job id `exec-N`; read with `report(job_id)` (action `blueprint_job`). Receipt + audit + blueprint in script-output `executor/exec-N.*`. One active job at a time; repeat call returns the active job.

`report(job_id, resume=true)` (action `blueprint_job`, optional `resume`) restarts a job that already imported and then stopped: the failure happened AFTER the build, so real machines are standing and a recall + rebuild would pay for the block twice.
- Refused: `job-not-resumable` (state is not `needs-attention`) / `job-not-built` (never imported successfully — rerun the identical `blueprint_run` instead, the executor regathers).
- Re-entry is idempotent: site re-check, tree clearing, stock debit, ghost aim and `blueprint_import` are ALL skipped once `j.imported` is set (`j.placed` can legitimately be `0`, which Lua reads as true — the flag, not the count, is the guard). The `connect` checks re-run, the primer resumes from `j.primed` (a flat index over primer×matching entities), and the holdout clock restarts.
- Use after fixing the cause: a pole run built to the job, a pipe connected, a fuel problem. A failed audit is resumable too, but the primer will NOT re-fuel — put fuel in by hand first.

## Executor rules (cheat sheet)

- Inserter `direction` = pickup side (dir 0 N: picks from north, drops south). Both ends must hold a receiver or `inserter-unconnected` (see §Site).
- Each entity's tiles + `clearance` must contain NO own-force entity → `occupied` (per entity, not the design bounding box). `character` = a player (maintainer's or agent's) stands in it: move the player, not the site.
- Trees/rocks in footprints auto-mined (products to bag). Cliffs → `cliff`, never cleared.
- Items come from bag → own chests / furnace+assembler outputs → mining → hand craft. NOT from belts.
- Job `needs-attention` with `insufficient-items` mid-build: rerun the IDENTICAL call; the executor regathers (Sonnet live 19/09).
- Job `needs-attention` AFTER the import (`infra-missing:*`, a primer insert with no room, a failed audit): fix the cause, then `report(job_id, resume=true)`. Never recall + rebuild for this.
- World coords of what gets built = `placed_at`, never recompute from anchor+rotation.
- Every job is a ledger block; declare intent with `contract.block` (§Ledger).

## Ledger (base memory, build `2026-09-20-block-identity`)

Stored in mod `storage` → travels with the save, survives restarts/handoffs. Only intent stored; live state recomputed per read.
- `contract.block = {id?, name, role, feeds:[{item?,block?,via?,per_minute?}], eats:[...], notes}` (name/id ≤40, role ≤120, notes ≤400, ≤12 links, link needs ≥1 field; `per_minute` = the rate the agent INTENDS that link to carry, >0 and <1e6). Bad → refused `invalid-block[-feeds|-eats]`, nothing built. Carried on job summary (`report.block`).
- `observe(view="ledger")` → `blocks` [{id, name, role, feeds, eats, notes, status, box [x1,y1,x2,y2], n {entity: planned count}, missing?, error?, pattern_id, tick, flow?}] + `edges` [{from, to, item?, declared?, measured?, missing_block?}].
  - Block identity is the entity, not the tile (build `2026-09-20-block-identity`). Each planned row is stamped with its built entity's `unit_number`; a row counts as present only when the tile holds an entity of that name AND that unit. A job whose planned entities are ALL gone (recalled, destroyed) leaves the ledger entirely, so its declared links stop reading as starved edges, and it stops being sampled for throughput.
    - `game.get_entity_by_unit_number` is NOT usable for this lookup: measured 20/09 it returns nil for an entity the mod holds, valid, in the same tick it read that entity's own `unit_number`. Hence tile-lookup-then-confirm. (`control.lua:95` still resolves the treasury through that call — unverified there, suspect.)
    - Belts, pipes and rails have no `unit_number`, so those rows are confirmed by tile alone; a job made purely of them can still be fooled by a rebuild on the same tiles.
  - `missing_block` on an edge: an endpoint is not a live block — a typo in `feeds.block`/`eats.block`, or a block that has since gone. Without it a link to nothing reads exactly like a producer that made nothing.
  - Job blocks: every exec job that placed anything. `status`: `verified` (audit passed), `unverified` (verified, no passing audit), `attention` (needs-attention OR any planned entity gone: `missing`=count), else raw job state.
  - Hand blocks `hand-N`: `status=declared`, `n` = live own-force entities in box (characters skipped).
  - Edges from both sides: A.feeds{block=B} and B.eats{block=A} both give {from=A,to=B,item}, deduped. "What breaks if I remove X" = every edge with X as producer.
  - `declared` = the link's `per_minute` (intent). `measured` = what the PRODUCER block actually finished in its last closed window, 0 when the window saw nothing. `declared` > `measured` is the starvation signal; both absent means nobody declared a rate and no window has closed yet.
- Throughput (`flow`, build `2026-09-20-flow`): each block carries `{ticks, samples, made {item: per minute}, active {entity: percent of samples working}}` from its last CLOSED window (default 3600 ticks; `storage.ledger_flow_window` overrides, tests use 300). Absent until the first window closes.
  - `made` is the delta of the engine's own `products_finished` over the window, mapped through each machine's current recipe — assembling machines, furnaces and silos only. A mining drill has NO per-entity counter, so a drill block reports `active` and never a `made` rate; read its output from the chest it fills, or from the machine downstream.
  - Known distortions, all deliberate: a machine added or removed mid-window carries its lifetime count in or out (negative deltas are dropped, so a removal reads as a quiet window, never a negative rate); a furnace whose recipe changed mid-window attributes the whole window to the recipe it ends on.
  - Sampling rides the 60-tick executor tick, ≤600 entities per tick across all blocks, resuming where the budget ran out so a big base cannot starve the last blocks in the list.
- `achieve(goal="annotate", contract={block:{id,...}})` merges given fields into block `id` (exec or hand); unknown → `block-not-found`. No id + `area=[x1,y1,x2,y2]` → registers new hand block, returns id. Neither → `block-id-or-area-required`.
- Engine PASS tests/verify_ledger_runtime.py (28 checks): bad feeds refused; `per_minute=-3` refused; character in site → `character` reject; 2 jobs + eats → edge carrying `declared=30`; note merges keep other fields; hand chest counted live + edge; chest destroyed → `attention` missing 1; report carries block; fed furnace → window `{ticks 300, samples 6, made {iron-plate 12}, active {stone-furnace 83}}` and edge `measured=12` against `declared=30`; block a then wiped off the ground → its row leaves the ledger, b survives, and b's link to it comes back `missing_block`.

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
- Entity cap: the executor builds ≤500 (`BUILD_ENTITY_LIMIT`); reference records are only read,
  so they parse up to 2000 (`REFERENCE_ENTITY_LIMIT`) and report `over_build_limit`. A 533-entity
  community array stores fine and still cannot be built in one job.
- `observe(view="patterns")` rows carry `origin` (the kind) when a pattern has one.
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

`achieve(goal="build_design", design=[{name,x,y,direction?,recipe?,type?}], contract, x?, y?, dry_run?)`. Agent designs from game rules (sizes, drill area/drop, inserter reach, ratios); no human template required. `design` = entity centers in tiles: odd-size entity on .5, even-size on integer (2x2 drill center `1,2`); direction 16-way 0N 4E 8S 12W. Python `encode_blueprint` → native string (≤500 entities, bad row → `invalid-design-entity:<i>`) → same `blueprint_run` path as reuse. Not dry → catalog pattern state `designed` + contract saved; report(exec-N) verified → upgraded to `verified`. Read any saved pattern's layout: `observe(view="patterns", pattern_id)` → entities shifted by whole tiles (parity kept) + contract; edit and resubmit as `design`. Human blueprint = optional reference only.

Engine PASS 2026-09-19 (tests/verify_design_runtime.py, tests/designs/coal-drill-chest.json): 2 burner drills facing N drop straight into own chest, feed chest→drill keep 2; 4 entities, windows coal 34/36/34, active 2/2, feed 12 total. NOT self-sustaining: no physical return path, feed moved 4 every window; live exec-2 (19/09) drills went no_fuel after job end with coal still in chests. Proves the build_design path only, not a good layout. Physical closed loop found live by Sonnet-agent: belt ring + 2 burner inserters feeding drills (pattern bp-888ab81fe7579dfd, exec-3).

`report(exec-N)` → `self_sustaining` = last window `feed_moved`==0. Catalog upgrade on verified: self-sustaining → `verified`, fed → `built` only.

## Field actions (live play, `field.lua`)

- `observe(view="water", x?, y?, radius≤2048, offset)` → action `water_sites`. Scans every generated chunk in radius holding fluid tiles (not the capped survey index), nearest first. Shore spots tried ×4 directions, center snapped to pump footprint. `candidates` (≤12/page, `next_offset`): `can_place_entity` manual true → `{x,y,direction,output,distance}`; `output` = tile the pump's pipe must occupy (from prototype pipe_connections; engine-checked: pipe there connects). `blocked` (≤12): placeable only with `forced` ghost check → `obstacles` [{name,x,y}] trees/rocks/cliffs to clear by hand. `clusters` (≤12): chunk, tiles, per-tile-type counts. Budget 40000 checks → `truncated`.
- `achieve(goal="recall", area=[x1,y1,x2,y2] (≤64) | design=[{name,x,y}], dry_run, force_active)` → action `recall`. Own force only, minable, no characters; trees/rocks never. Each entity `mine`d into a buffer then player bag: contents come along (chest, furnace, belt items). Bag full → spilled on ground, listed. Refuses `active-job:<id>` when a target sits in the layout of an executor job in preparing..auditing unless `force_active`. Reply: receipts per entity {items}, `delta` of bag.
- Engine PASS 2026-09-19 tests/verify_field_runtime.py: pond + tree-lined shore → candidates on free shore, tree spots in blocked with obstacles, pump at candidate + pipe at output connects; recall chest(10 plates)+belt(1 coal)+furnace(7 ore)+inserter → exact delta, tree untouched, active job refused.

## Schema

```json
{
  "site": {"mode": "search|exact", "rotations": [0,4,8,12], "clearance": 1,
           "enemy_radius": 16, "max_checks": 20000},
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

Unknown keys ignored (notes: `source`). Contract errors (refused, nothing built): `invalid-site`, `invalid-rotation`, `exact-site-needs-one-rotation`, `invalid-connect`, `invalid-declared-load`, `invalid-metric[-item|-fluid|-fraction|-load-fraction|-min]:<metric key>`, `declared-load-required:<metric key>`.

## Site

- Anchor = top-left tile of the rotated blueprint footprint. `exact`: anchor = `floor(x), floor(y)`. `search`: x,y = search center (default treasury player position), `radius` limit.
- Rotations 16-way units, default `[0]`. `exact` needs exactly ONE rotation (agent placed water/pole for that orientation; spinning would miss them). Rotation turns every entity position AND direction; W/H swap for east/west entities.
- Candidates, nearest first: with a resource rule → every anchor putting the rule's first matching entity's top-left tile on an ore tile; else square scan ≤64 tiles. Budget `max_checks` (≤20000) → `search-budget-exhausted`.
- Per candidate, reject reason counted: `out-of-area`, `occupied` (own-force entity inside SOME entity's own tiles + `clearance` — NOT the design bounding box: a layout whose pole run reaches 10 tiles away does not claim the base in between; the bbox is only a fast path, one count query, and only a non-zero count triggers the per-entity pass), `character` (only own characters there: player in the way), `enemies` (within `enemy_radius`), `collision` (`can_place_entity` manual check, every entity; a failure whose footprint holds only trees/rocks passes if a `forced` blueprint_ghost check passes → clearable), `cliff` (cliff inside footprint: never cleared, needs explosives), `foreign-resource`, `resource-cover`, `resource-reserve`.
- Resource rule area = `mining_drill_radius` of that entity (burner drill: its 2x2). `full_cover` (default): every tile in area holds `resource` ≥ `min_per_tile`. `exclusive` (default): other resource in area rejects. Sum ≥ `min_total`.
- None fits → `state=blocked, error=no-site, rejects={reason: n}, checks`. Agent picks a new area / relaxes contract.
- Inserter ends (after site found, before any debit, dry_run too): every inserter's pickup AND drop tile (prototype `inserter_pickup_position`/`inserter_drop_position`, dir 0 = pickup north, rotated by dir) must hold a receiver: planned entity of a receiver type (belt/underground/splitter/loader, chest, furnace, assembler, lab, drill, boiler, turret, wagon, silo...) or an existing own-force one. Else `state=blocked, error=inserter-unconnected, unconnected=[{inserter:[x,y], side:pickup|drop, tile:[x,y], hint?}]`. `hint={entity, from, to, design_shift:[dx,dy]}` only when exactly one planned receiver one tile away covers the tile, the move clashes with no planned entity AND lowers total gaps; `design_shift` is in the agent's design frame (rotation undone). Never auto-moved: agent edits design and resubmits (maintainer 19/09: pre-build check + hint over post-build snap — no wasted build, catalog blueprint = what was built, no guessing when a machine serves several inserters). Engine PASS tests/verify_inserter_runtime.py: lab 1 tile off → drop gap + shift [-1,0] (also under rotation 4), fixed → planned, pickup from existing belt counts, engine pickup/drop positions match.
- `placed_at` [[name,x,y,dir]] world coords: in dry_run/blocked replies and every job report.
- Water inlet, pole, load: NOT searched/provisioned (PORTING §2); agent builds them, executor checks via `connect`:
  - `{entity, power: true}`: pre-build, every matching entity inside the supply area of a pole that REACHES A LIVE GRID (§Poles), else reject `no-power`. Post-build, `electric_network_id` set with a source on it.
  - `{entity, fluid}`: post-build, before primer: some fluidbox for that fluid (filter) connects to an entity NOT built by this job. Else `needs-attention: infra-missing:<fluid|power>:<entity>@x,y`; built entities stay, primer NOT spent. Connect the pipe, then `report(job_id, resume=true)`.

## Materials

Cost = place items of every entity + primer item × matching entity count. Plan order: treasury (player) → own chests / furnace+assembler outputs in radius (`collect`) → trees/rocks for wood/stone (`mine`) → hand craft (enabled recipe, category in character `crafting_categories`, depth ≤6). Missing or tech-locked → `blocked` + `missing`/`locked`, nothing debited. `dry_run` = site + plan, no debit.

## Build

Re-check site + stock right before build. Then trees/rocks inside any entity footprint (tile box, not margin) `mine`d → products to bag, receipt each, `cleared` = count on the job (once). `dry_run`/job `site.clear` = count to clear. Nature outside footprints untouched (trees absorb pollution). Engine PASS 2026-09-19 tests/verify_clear_runtime.py: chest+furnace in forest + big-rock → 6 cleared, footprints empty, tree outside kept, wood+stone in bag; cliff under site → `cliff` reject, cliff intact. Exact landing of native `build_blueprint` found by a ghost probe (ghosts built then destroyed, zero items), then `blueprint_import` direct mode at the corrected position with rotation. Every entity must then sit at its planned position/direction or `import-geometry-mismatch`. Primer inserted from treasury (receipt per insert). Primer is the LAST executor mutation.

## Poles and power

- Blueprint import = ghost `revive`: no hand-style auto-wire (live 19/09 exec-15/16: 4 poles isolated, 5 inserters `no_power`). Fix build `2026-09-19-pole-wiring`: each revived pole copper-wired to every own pole within min(both max_wire_distance), nearest first, ≤5. Receipt row `wires`=count. Poles built before this build stay isolated: recall + rebuild.
- Pre-build `connect power` (build `2026-09-20-resume-power`): the entity must be covered by a FED pole. Nodes = the layout's own poles + every own-force pole whose position is inside the layout bbox grown by 32. A node is fed when (a) its `electric_network_id` is a live network, (b) its supply area covers a producer THIS layout brings (a steam build powers its own substation), or (c) wire reach `min(a.max_wire_distance, b.max_wire_distance)` links it to a fed node — spread to a fixed point.
  - Live network = some own-force producer on this surface (generator, burner-generator, solar, EEI, fusion, accumulator with `energy>0`) sits on that `electric_network_id`. Whole-surface scan, memoised per tick, computed only when a power rule exists.
  - BEFORE: any pole in the layout satisfied the pre-check, so a design carrying its own pole always passed — including `dry_run` — and died AFTER the build on `infra-missing:power`, machines already on the ground. Solar counts even at night (deterministic); an accumulator at 0 J does not.
- Post-build `connect power`: entity network must hold a source (same list) — island of poles → `infra-missing:power:<entity>@x,y`.
- Engine PASS tests/verify_metrics_runtime.py: 2 layout poles chain to pre-placed pole+EEI, same network, lab verified; same layout far away → refused pre-build with `no-power`, nothing built.
- Engine PASS tests/verify_power_runtime.py (14 checks): lab + near pole + pole 7 tiles out — a chest parked in the empty middle of the bbox does NOT read `occupied`, a chest on the lab's own tiles does; same design out of wire reach → `no-power`, same design where the far pole reaches a live grid → `planned`; resume (below).

## Research (`control.lua` handle_research)

- `observe(view="research")` → current, progress, `queue`, `labs` {status→count on surface}, `available` (enabled, unresearched, prerequisites met).
- `achieve(goal="research", tech)` → `force.add_research`: starts or appends to queue; 2.0 accepts a tech whose prerequisites are researched OR already queued. Refused → `cannot-queue` + `missing_prerequisites`, `current`. Unknown → `technology-not-found`.
- `achieve(goal="capture", area=[x1,y1,x2,y2], contract?)` → blueprint_export of a built area → catalog `captured` + `layout` (design rows). Resubmit via build_design/reuse_blueprint to verify.
- Engine PASS 2026-09-19 tests/verify_metrics_runtime.py: queue automation→logistics, unknown refused; drill→furnace products_finished 7/window verified; 1 powered lab 40 packs research_units 9.8/window ≤ speed cap, verified.

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
