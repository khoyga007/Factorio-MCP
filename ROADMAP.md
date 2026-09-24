# Roadmap

Where the project stands and what is still open. The gaps below come from the working notes up to
2026-09-21. Some may have been fixed since, so check the code before you rely on one.

## Direction

1. **A base that runs itself.** The first rocket was launched, but with hand-kitted, chest-fed cells
   (see [LESSONS.md](LESSONS.md) #2). The next test for the toolset is a base that keeps launching
   rockets with no agent in the loop.
2. **Oil by train.** A remote oil field reached by rail, not by hauling.
3. **Simulate before build** (idea, not scheduled). Two tiers: an analytic ratio/throughput pass
   to prune many layouts, then a shadow build on a copy of the save (the `tests/verify_*_runtime.py`
   harness already does this) that returns measured throughput before the real build. The harness
   exists but the agent can't reach it during play.

## Known gaps

### Executor
- A resume after a failed audit does not re-prime. Refuel by hand first. This is by design.
- `blueprint_import` refuses blueprints that carry tiles (`blueprint-tiles-not-supported`).
  Landfill now covers plans over water, so this is a cosmetic limit.
- With the cliff-explosives recipe locked and not enough in the bag, a ghost job parks forever.
  `ground` names the missing item, but nothing gives up.
- Space Age lava and other non-water fluid tiles count as fillable water. `landfill-refused`
  catches this after the fact, not at plan time.
- Ghost mode with an `exact` site can build over a foreign ghost of a *different* name.
- Underground **belts** have no pairing validator. Underground pipes do (`pipe_gaps`).
- The narrowed geometry check (direction compared only when the prototype supports direction) has
  not been confirmed in the engine against the build that first tripped it.
- Bots mode (`build.revive=false`): the engine test revives ghosts itself; real robot flight has
  not been engine-tested.

### Ledger
- `flow.made` can't tell starved input from blocked output. It needs a measured consumption (`eats`).
- Edges are declared by the agent. `measured` edges from real belt and inserter links would be better.
- No change history per block.
- `feeds.block` accepts an unknown block id at declare time. It only shows up later as `missing_block`.
- A primer row such as `{wooden-chest, iron-ore, 50}` applies to every matching entity in the
  layout. It needs a per-entity or per-position target.

### Items and recall
- `craft`, `collect` and `insert` have no `dry_run`.
- `craft` has no completion signal. Poll `observe` for the bag.
- Recall slices large areas into 64x64 pieces. A single slice holding more than 200 entities still
  answers `too-many-entities`. Recall that one by `design`.

### Bridge core
- `core.lua` resolves the treasury chest through `game.get_entity_by_unit_number`. The ledger
  measured that call returning nil for a valid entity. Here a false nil would clear
  `treasury_unit_number` for good. The path only runs when the stored entity reference is lost.
  Unverified in the engine.

### MCP surface
- The three tool schemas are held under a 4000-byte budget (`tests/test_factorio_goal_mcp.py`) and
  sit close to it. A new parameter needs a cut somewhere else, or a fourth tool.

### Tests
- `tests/verify_economy_runtime.py` fails `repair-debits-exact-ingredients` on a save that already
  had the one-time demo repair applied (`already_done`). It needs a pre-repair source save, or the
  test should be retired.
