# Blueprint contract — generic executor

`achieve(goal="reuse_blueprint", pattern_id, contract?, x?, y?, radius?, dry_run?)` → Lua `executor.lua` (action `blueprint_run`). Agent designs + declares; executor checks, gathers real items, builds, primes, audits. No per-pattern code. Contract omitted → pattern's saved `contract` in `blueprints/catalog/<id>.json` → else `{}` (search around x,y, no primer, no audit).

Job id `exec-N`; read with `report(job_id)` (action `blueprint_job`). Receipt + audit + blueprint in script-output `executor/exec-N.*`. One active job at a time; repeat call returns the active job.

## Schema

```json
{
  "site": {"mode": "search|exact", "rotations": [0,4,8,12], "clearance": 1,
           "enemy_radius": 16, "max_checks": 20000},
  "resources": [{"entity": "burner-mining-drill", "resource": "coal",
                 "min_per_tile": 100, "min_total": 800, "full_cover": true, "exclusive": true}],
  "primer": [{"entity": "burner-mining-drill", "item": "coal", "count": 5}],
  "feeds":  [{"from": "wooden-chest", "to": "burner-mining-drill", "item": "coal", "keep": 2}],
  "verify": {"window_ticks": 3600, "max_windows": 5, "settle_ticks": 0,
             "metrics": [{"key": "coal_gained", "kind": "container_gain",
                          "entity": "wooden-chest", "item": "coal", "min": 20}]}
}
```

Unknown keys ignored (use for notes: `source`, `declared_load_mw`).

## Site

- Anchor = top-left tile of the rotated blueprint footprint. `exact`: anchor = `floor(x), floor(y)`. `search`: x,y = search center (default treasury player position), `radius` limit.
- Rotations 16-way units, default `[0]`. Rotation turns every entity position AND direction; W/H swap for east/west entities.
- Candidates, nearest first: with a resource rule → every anchor putting the rule's first matching entity's top-left tile on an ore tile; else square scan ≤64 tiles. Budget `max_checks` (≤20000) → `search-budget-exhausted`.
- Per candidate, reject reason counted: `out-of-area`, `occupied` (own-force entity inside footprint + `clearance`), `enemies` (within `enemy_radius`), `collision` (`can_place_entity` manual check, every entity), `foreign-resource`, `resource-cover`, `resource-reserve`.
- Resource rule area = `mining_drill_radius` of that entity (burner drill: its 2x2). `full_cover` (default): every tile in area holds `resource` ≥ `min_per_tile`. `exclusive` (default): other resource in area rejects. Sum ≥ `min_total`.
- None fits → `state=blocked, error=no-site, rejects={reason: n}, checks`. Agent picks a new area / relaxes contract.
- Water inlet, pole reach, load: NOT searched yet (PORTING §2). Use `exact` where agent already verified them.

## Materials

Cost = place items of every entity + primer item × matching entity count. Plan order: treasury (player) → own chests / furnace+assembler outputs in radius (`collect`) → trees/rocks for wood/stone (`mine`) → hand craft (enabled recipe, category in character `crafting_categories`, depth ≤6). Missing or tech-locked → `blocked` + `missing`/`locked`, nothing debited. `dry_run` = site + plan, no debit.

## Build

Re-check site + stock right before build. Exact landing of native `build_blueprint` found by a ghost probe (ghosts built then destroyed, zero items), then `blueprint_import` direct mode at the corrected position with rotation. Every entity must then sit at its planned position/direction or `import-geometry-mismatch`. Primer inserted from treasury (receipt per insert). Primer is the LAST executor mutation.

## Holdout audit (PORTING §5, stricter than FLE)

- After primer: wait `settle_ticks`, then windows of `window_ticks`. No executor action in windows except declared `feeds`.
- Samples every 60 ticks. Layout broken (entity missing/moved/rotated) → `needs-attention: layout-broken:<i>`.
- Metric kinds (all compare `value >= min`):
  - `container_gain` {entity,item}: item count at window end − start, summed over matching chests. Net: feed withdrawals count against it.
  - `working_count` {entity, fraction=0.8}: number of matching entities with status `working` in ≥ fraction of samples.
  - `electric_output_mw` {entity}: mean over samples of Σ `energy_generated_last_tick`×60 /1e6. Real output, zero without load.
  - `fluid_temperature` {entity, fluid="steam"}: min over samples of max fluid temperature in entity fluidboxes (0 if absent).
  - `fuel_min` {entity}: min over samples of fuel-inventory items + 1 if still burning.
- Stop when windows ≥ `max_windows` (≤8), or ≥2 windows and the FIRST metric did not increase vs previous window. PASS iff the LAST window meets every metric. Max alone never passes (buffers draining inflate early windows).
- Every window stored: ticks, samples, values, passed, `feed_moved`.

## Feeds

Declared local loop: move real `item` from this job's own `from` chest into each `to` entity's fuel slot, topping to `keep`. Runs only while the job settles/audits; stops at verified. `feed_moved` per window + total `feed` in report show how much the design leans on it. A design that needs a feed forever is not self-sustaining — agent should design fuel logistics (e.g. drills facing each other) or rely on autofuel, knowingly.

## Saved contracts

- `bp-f30d8a84af3098ee` (2 coal drills): LEARNING_PROGRESSION §8.2. Engine PASS 2026-09-19: windows coal 35 → 32, active 2/2, feed 0 → 4.
- `bp-985eb5fc230538b4` (steam 1:2): §8.3. `exact` only. Agent MUST override power `min` = 0.95×min(declared_load_mw, 1.8) and pick a site where boiler water input + pole + load already exist. Saved min 0.095 = floor for 0.1 MW load.
