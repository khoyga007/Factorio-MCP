# Porting notes — external designs → Factorio-MCP

Approved 2026-09-19. Take DESIGN, not code. Sources vendored read-only under `reference/`; MIT, keep LICENSE + attribution in any file that ports logic.

- `skyline624/` = skyline624/factorio_llm @ SOURCE_COMMIT. C#, vanilla 2.0.77, RCON, walking character. We: Lua+Python, Space Age + alien-biomes, UDP, no character (treasury model). Their "reach / approach / route" logic = irrelevant for us; drop.
- FLE = JackHopkins/factorio-learning-environment (MIT). Only the holdout rule taken; not vendored.

Status of all: NOT verified on our save. Skyline itself never launched a rocket (docs/validation.md: component tests + fixtures + one normal-economy chain, seed 424242).

## 1. Site search for blueprint — `PlacementPlanner.FindCandidates` → generic executor (NOW)

Their algorithm (single entity):
- For direction in {0,4,8,12} (16-dir scale): swap tile W/H when direction%8≠0.
- Candidate centers tile-aligned: `x = ceil(minX) + (W%2)*0.5`, step 1; same for y with H. Odd size → half-tile center, even → integer.
- Keep if placement clear (native collision masks, oriented boxes incl. cliffs at 0.125 turn).
- Score = distance to preferred point; tie-break y, x, direction. Cap 100 candidates.

Our port (Lua, whole blueprint, native checks — no C# collision field needed):
- Blueprint footprint = union of entity boxes relative to anchor. Candidate anchors on the tile-aligned grid inside agent-declared area (center+radius or bbox), ring order by distance to preferred point.
- Per candidate: every entity `surface.can_place_entity{name,position,direction,force,build_check_type=manual}`; plus declared resource constraints (e.g. each mining drill's mining area must contain `resource` ≥ min amount; offshore pump source tile must be `fluid`).
- Rotation: only if agent allows (`rotations: [0,4,8,12]`); default = as-authored. Rotating a blueprint rotates every entity position AND direction.
- Budget: cap candidates evaluated per tick (spread over ticks via job) — site search on radius 192 is expensive; skyline caps 100 results, we cap evaluations.
- Blocker when none: `no-site` + counts of rejects by reason (collision / resource / fluid / out-of-area). Agent decides next area.

## 2. Power — `PowerGridPlanner` + `OffshoreSupplyPlanner` (NEXT, unblocks powered smelting rows)

Pole choice: among obtainable pole items with wire_distance>0 and supply_area>0, prefer already-carried, then longest wire, then name.

Grid extension = best-first search from existing powered poles (have electric network id):
- If any source pole supply square (±supply_area) overlaps target box → `connected`, nothing to build.
- Nodes = candidate pole positions within wire range of node, tile-aligned by pole size parity, must be placement-clear and must NOT overlap target box.
- Priority = cost(poles placed) + max(0, dist(point,targetCenter) − supply_area)/wire.
- Budget 8192 expansions → `search-budget-exhausted`. Returns only FIRST pole of path; build, re-observe, repeat (incremental, tolerant of world change).
- Remote target (outside observed area): accept node that cuts distance by min(16, d0/2).

Offshore: enumerate pump candidates near target by site search; keep those whose rotated `fluid_source_offset` tile holds the wanted fluid; then pipe-route pump output port → target input port. First routable wins. Port positions come from native fluidbox `positions[4]` (we already export these in `spec entity`, build 2026-09-17-mcp-fixes).

## 3. Defense without LLM — `DefenseDeploymentPlanner` (after power)

- Anchors = own entities of type mining-drill, furnace, assembling-machine, lab, boiler, generator, rocket-silo, container, storage-tank.
- Turret "ready" = active AND ammo rounds ≥ 100 AND range>0. Goal "N ready turrets": complete / service nearest not-ready turret (refill) / build new.
- Placement score for candidate = Σ over anchors within 0.9×range of 1/(1+current coverage of that anchor). Pick max score → fills least-covered anchors first.
- Ammo choice: compatible ammo category; prefer in stock, else cheapest enabled deterministic recipe (Σ ingredient amounts / product amount).
- Our fit: a periodic Lua on_nth_tick service (refill ammo from treasury/chests, report threats) — no model call. Must obey real-items rule: ammo moved, never created.

## 4. Rocket — `RocketPlanner` + `SiloResearchDependencies` (last)

- Research graph: techs whose effects unlock a recipe producing an item that places `rocket-silo`; walk prerequisites (cycle check, cap 256). Output remaining / available / disabled. It is dependency data, NOT a readiness proof.
- Silo supply step: status `rocket_ready` (+ rocket entity present) → launch. Status not `building_rocket` or parts==required → WAIT (engine can reset parts during opening/launch — never refill then). Else cycles = ceil((required−parts)/product_amount); ingredients needed = unstarted cycles × amount − already loaded; deliver ≤5 cycles per batch, ≤ insertable, ≤1000.
- Launch proof = `force.rockets_launched` increments. A ready rocket ≠ launch. Space Age note: silo semantics differ (rocket carries cargo to platform) — recheck on our save before trusting any of this.

## 5. Holdout audit — FLE throughput_task.verify

FLE: after agent stops, loop { sleep 60 s, read production in window }; continue while throughput increases; score = max window; pass if max ≥ quota. No agent interaction during windows.

Our rule (stricter): audit window only after job's last mutation; no refuel/insert by the job during window except declared self-sustaining feeds; repeat windows until non-increasing; PASS needs the LAST window ≥ target (max alone can be inflated by input buffers draining). Record every window in receipt.
