# Factorio Mayor

Tools that let an AI agent play **Factorio 2.0** like an engineer. The agent reads the map, designs
production lines from the game's own rules, builds them with **real items**, and then measures
whether they actually run. Nothing is spawned, there is no cheat mode, and there is no arbitrary
Lua console.

The project has two parts:

- **`factorio-ai-bridge`**: a Factorio mod (Lua) that listens on a localhost UDP port and carries
  out reads, builds and audits inside the game.
- **`factorio_goal_mcp.py`**: a Python [MCP](https://modelcontextprotocol.io) server that gives an
  agent (Claude Code, Codex or any MCP client) three tools: `observe`, `achieve` and `report`.

The first milestone, launching a rocket from a factory the agent built and ran, has been reached.
See [ROADMAP.md](ROADMAP.md) for what comes next and [LESSONS.md](LESSONS.md) for what it took.

## How it works

```
Agent (any MCP client)
   │  MCP stdio: observe · achieve · report
   ▼
factorio_goal_mcp.py ── blueprint_library.py   catalog, design → blueprint string
   │                    planner.py              recipe tree → machine counts per rate
   │                    cells.py / chain.py     production cells and chains
   │  UDP localhost:34198
   ▼
factorio-ai-bridge (mod, runs inside the game)
   ├─ control.lua   UDP entry point + handler table
   ├─ core.lua      state, responses, stock (treasury), entity views
   ├─ items.lua     mine / craft / collect / insert / autofuel, real items only
   ├─ survey.lua    snapshot / brief / spec / audit / flow / supply (read-only)
   ├─ build.lua     recipe / research / launch / place / blueprint import-export
   ├─ executor.lua  shared blueprint executor: find site → gather/craft → build → prime → audit
   │   ├─ site.lua      layout geometry, power / pipe / inserter checks, site search
   │   ├─ contract.lua  contract parsing
   │   └─ ledger.lua    base memory: blocks, edges, measured flow, clusters
   └─ field.lua     water spots, recall, belt/pipe routing
```

**The agent designs and the executor carries it out.** The agent works out a layout (machine sizes,
mining areas, inserter reach, ratios) and declares a *contract*: where to build, which ore patch it
needs, power and water, starting fuel, and the numbers that count as success. The executor checks
the site, gathers or crafts the materials from real stock, builds, primes, and then runs a
**holdout audit**, measuring over time windows where the last window must pass. A layout is marked
`verified` in the catalog only when it is **self-sustaining**, meaning the last window needed no
feeding from the executor.

Building blocks the agent can use:

- **Designs**: raw entity rows, or saved patterns from `blueprints/catalog/`.
- **Production cells**: `{cell: recipe}` expands to a row of machines with input/output belts and
  inserters.
- **Production chains**: `{chain: item@N/min}` plans the recipe tree and builds one cell per
  consumer, with the connecting belts routed between them.
- **Ghost mode**: paste a plan as ghosts and let it build itself as materials arrive, from declared
  supply chests or by construction robots.
- **Ledger**: records what was built, what feeds what, and measured output per minute, so the agent
  can find starved or blocked lines.

## Requirements

- Factorio **2.0** (developed against 2.0.77)
- Python **3.11+**
- Python package `mcp` ≥ 1.27.1 (see `requirements-mcp.txt`)

## Install

1. **Mod.** Copy `factorio-ai-bridge_0.1.0/` into your Factorio mods folder
   (`%APPDATA%\Factorio\mods\` on Windows, `~/.factorio/mods/` on Linux).
   The game loads that **copy**, not this repo. After you edit Lua, copy it again and restart
   Factorio.
2. **UDP port.** Start Factorio with `--enable-lua-udp 34198`. On Windows, set `FACTORIO_EXE` to
   your `factorio.exe` and run `start-factorio-ai.bat`. Then load a map with the mod enabled.
3. **MCP server.**

   ```sh
   python -m pip install -r requirements-mcp.txt

   # Claude Code
   claude mcp add factorio-engineer --scope user -- python /path/to/FactorioMayor/factorio_goal_mcp.py
   # Codex
   codex mcp add factorio-engineer -- python /path/to/FactorioMayor/factorio_goal_mcp.py
   ```

   Host and port come from `FACTORIO_HOST` / `FACTORIO_PORT` (default `127.0.0.1:34198`).
   After you edit the Python, restart the agent session so it picks up the new tool schema.
4. **Check.** Call `observe(view="situation")`. The reply should include the mod's build name.

## Quickstart

One burner drill facing north, dropping coal into a chest just above it. The layout is taken from
`tests/designs/coal-drill-chest.json` and has been tested in the engine.

```json
achieve(goal="build_design",
  design=[{"name":"burner-mining-drill","x":1,"y":2,"direction":0},
          {"name":"wooden-chest","x":0.5,"y":0.5}],
  contract={"site":{"mode":"search"},
            "resources":[{"entity":"burner-mining-drill","resource":"coal","min_total":500}],
            "primer":[{"entity":"burner-mining-drill","item":"coal","count":5}],
            "verify":{"window_ticks":1800,"max_windows":3,
                      "metrics":[{"key":"coal","kind":"container_gain","entity":"wooden-chest","item":"coal","min":10}]}})
```

Then poll `report(job_id="exec-N")` for the audit windows.

This layout is **not** self-sustaining: once the starting coal burns out, the drill stops. A
self-sustaining version needs a path that carries coal back to the drill, for example a belt loop
with inserters like pattern `bp-888ab81fe7579dfd`.

Coordinates are entity centres. Odd-sized entities sit on `.5`, even-sized ones on whole numbers.
Directions use 16 steps: `0` north, `4` east, `8` south, `12` west. Add `dry_run=true` to check a
plan without building it.

## Tools

| Tool | Purpose |
|---|---|
| `observe(view=…)` | Read the world: `situation`, `deposits`, `nearby`, `entities`, `water`, `research`, `flow`, `supply`, `route`, `plan` (rate planner), `ledger`, `patterns` / `references` (catalog), and more |
| `achieve(goal=…)` | Act: `build_design`, `reuse_blueprint`, `build_ghosts` / `drop_ghosts`, `capture`, `recall`, `research`, `set_recipe`, `craft` / `collect` / `insert`, `import`, `annotate`, `launch` |
| `report(job_id)` | Status of an `exec-N` job: site, materials, each audit window, `self_sustaining`. `resume=true` restarts a built job once its blocker is cleared |

More detail:

- [CONTRACT.md](CONTRACT.md): contracts, executor rules, metrics, power and water, ghost builds,
  the ledger, cells and chains
- [MCP.md](MCP.md): running the MCP server, schema caching
- [docs/CLI.md](docs/CLI.md): `factorio_ai.py`, a lower-level CLI for diagnostics only
- [BLUEPRINTS.md](BLUEPRINTS.md): how blueprints get created and verified
- [FIELD_NOTES.md](FIELD_NOTES.md) and [LEARNING_PROGRESSION.md](LEARNING_PROGRESSION.md): game
  rules measured in play (partly in Vietnamese)
- `skills/`: stage-by-stage guides for an agent, from bootstrap and smelting through science packs
  to the rocket

## Tests

```sh
python -m pytest tests -q        # Python unit tests, no game needed
python contract_check.py         # actions.json, the Lua handler table and the CLI agree
```

Engine tests (`tests/verify_*_runtime.py`) run Factorio headless (`--benchmark`) on a **copy** of a
save, with the mod mirrored into `.runtime-test/`:

```sh
export FACTORIO_EXE=/path/to/factorio    # or set it in PowerShell / cmd
python tests/verify_executor_runtime.py --player-save .runtime-test/saves/your-save.zip
```

`.runtime-test/` is git-ignored. Create it yourself with a `config.ini` and a save.

## Rules the agent plays by

- Every in-game action goes through MCP. The CLI is only for diagnostics.
- Only real items from the player's inventory or the force's storage are used, and every transfer
  leaves a receipt. Nothing is spawned.
- Locked technology is refused. There is no arbitrary Lua.
- Trees and rocks on a build's own tiles are mined first, and the wood and stone go to the
  inventory with a receipt. Cliffs and water are cleared only when cliff explosives or landfill are
  available. The player's own buildings are never mined.

## Repository layout

| Path | Contents |
|---|---|
| `factorio-ai-bridge_0.1.0/` | The mod |
| `factorio_goal_mcp.py` | MCP server (`observe` / `achieve` / `report`) |
| `blueprint_library.py`, `catalog_add.py` | Blueprint encoding and the pattern catalog |
| `planner.py`, `cells.py`, `chain.py` | Rate planner, production cells, production chains |
| `perception.py`, `survey.py`, `factorio_model.py`, `spec_*.py` | Read-side helpers and the game-data model |
| `factorio_ai.py`, `bridge_client.py` | Diagnostic CLI and the UDP client |
| `actions.json`, `contract_check.py` | Action registry and its consistency check |
| `blueprints/catalog/` | Saved patterns, each with a state: `reference` → `designed` → `built` → `verified` |
| `incoming/` | Raw community blueprint strings, not yet imported |
| `skills/` | Agent guides per game stage |
| `tests/` | Unit tests, engine tests and fixtures |
| `reference/` | Third-party design reference (see below) |

## License

MIT, see [LICENSE](LICENSE).

`reference/skyline624/` is third-party code vendored for reference under its own MIT license
(`reference/skyline624/LICENSE`). See `reference/PORTING.md` for how it is used.
