# Blueprint contract — generic executor

`achieve(goal="reuse_blueprint", pattern_id, contract?, x?, y?, radius?, dry_run?)` → Lua `executor.lua` (action `blueprint_run`). Agent designs + declares; executor checks, gathers real items, builds, primes, audits. No per-pattern code. Contract omitted → pattern's saved `contract` in `blueprints/catalog/<id>.json` → else `{}` (search around x,y, no primer, no audit).

Job id `exec-N`; read with `report(job_id)` (action `blueprint_job`). Receipt + audit + blueprint in script-output `executor/exec-N.*`. One active job at a time; repeat call returns the active job.

## Agent-authored design (`build_design`)

`achieve(goal="build_design", design=[{name,x,y,direction?,recipe?,type?}], contract, x?, y?, dry_run?)`. Agent designs from game rules (sizes, drill area/drop, inserter reach, ratios); no human template required. `design` = entity centers in tiles: odd-size entity on .5, even-size on integer (2x2 drill center `1,2`); direction 16-way 0N 4E 8S 12W. Python `encode_blueprint` → native string (≤500 entities, bad row → `invalid-design-entity:<i>`) → same `blueprint_run` path as reuse. Not dry → catalog pattern state `designed` + contract saved; report(exec-N) verified → upgraded to `verified`. Read any saved pattern's layout: `observe(view="patterns", pattern_id)` → entities shifted by whole tiles (parity kept) + contract; edit and resubmit as `design`. Human blueprint = optional reference only.

Engine PASS 2026-09-19 (tests/verify_design_runtime.py, tests/designs/coal-drill-chest.json): 2 burner drills facing N drop straight into own chest, feed chest→drill keep 2; 4 entities, windows coal 34/36/34, active 2/2, feed 12 total. Beats saved 10-entity coal pattern.

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

Unknown keys ignored (notes: `source`). Contract errors (refused, nothing built): `invalid-site`, `invalid-rotation`, `exact-site-needs-one-rotation`, `invalid-connect`, `invalid-declared-load`, `invalid-metric[-item|-fluid|-fraction|-load-fraction|-min]`, `declared-load-required`.

## Site

- Anchor = top-left tile of the rotated blueprint footprint. `exact`: anchor = `floor(x), floor(y)`. `search`: x,y = search center (default treasury player position), `radius` limit.
- Rotations 16-way units, default `[0]`. `exact` needs exactly ONE rotation (agent placed water/pole for that orientation; spinning would miss them). Rotation turns every entity position AND direction; W/H swap for east/west entities.
- Candidates, nearest first: with a resource rule → every anchor putting the rule's first matching entity's top-left tile on an ore tile; else square scan ≤64 tiles. Budget `max_checks` (≤20000) → `search-budget-exhausted`.
- Per candidate, reject reason counted: `out-of-area`, `occupied` (own-force entity inside footprint + `clearance`), `enemies` (within `enemy_radius`), `collision` (`can_place_entity` manual check, every entity), `foreign-resource`, `resource-cover`, `resource-reserve`.
- Resource rule area = `mining_drill_radius` of that entity (burner drill: its 2x2). `full_cover` (default): every tile in area holds `resource` ≥ `min_per_tile`. `exclusive` (default): other resource in area rejects. Sum ≥ `min_total`.
- None fits → `state=blocked, error=no-site, rejects={reason: n}, checks`. Agent picks a new area / relaxes contract.
- Water inlet, pole, load: NOT searched/provisioned (PORTING §2); agent builds them, executor checks via `connect`:
  - `{entity, power: true}`: pre-build, every matching entity inside supply area of an own pole, else reject `no-power`. Post-build, `electric_network_id` set.
  - `{entity, fluid}`: post-build, before primer: some fluidbox for that fluid (filter) connects to an entity NOT built by this job. Else `needs-attention: infra-missing:<fluid|power>:<entity>@x,y`; built entities stay, primer NOT spent.

## Materials

Cost = place items of every entity + primer item × matching entity count. Plan order: treasury (player) → own chests / furnace+assembler outputs in radius (`collect`) → trees/rocks for wood/stone (`mine`) → hand craft (enabled recipe, category in character `crafting_categories`, depth ≤6). Missing or tech-locked → `blocked` + `missing`/`locked`, nothing debited. `dry_run` = site + plan, no debit.

## Build

Re-check site + stock right before build. Exact landing of native `build_blueprint` found by a ghost probe (ghosts built then destroyed, zero items), then `blueprint_import` direct mode at the corrected position with rotation. Every entity must then sit at its planned position/direction or `import-geometry-mismatch`. Primer inserted from treasury (receipt per insert). Primer is the LAST executor mutation.

## Holdout audit (PORTING §5, stricter than FLE)

- After primer: wait `settle_ticks`, then windows of `window_ticks`. No executor action in windows except declared `feeds`.
- Samples every 60 ticks. Layout broken (entity missing/moved/rotated) → `needs-attention: layout-broken:<i>`.
- Metric kinds (all compare `value >= min`; `min` required unless `load_fraction`):
  - `container_gain` {entity,item} (item required): item count at window end − start, summed over matching chests. Net: feed withdrawals count against it.
  - `working_count` {entity, fraction=0.8}: number of matching entities with status `working` in ≥ fraction of samples.
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
