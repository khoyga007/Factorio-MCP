# Lessons — road to first rocket (17/09 → 23/09/2026)

**First rocket = end of the learning phase, not end of the game.** Next test for the toolset: a base that launches rockets continuously with no agent intervention; then space platforms / planets.

Meta-lessons for any agent driving this bridge. Mechanics live in FIELD_NOTES.md / LEARNING_PROGRESSION.md; tool contract in CONTRACT.md. Each line = a mistake paid for or a pattern that worked.

## Planning
1. **Walk the end goal's recipe tree from game data before building mid-tier.** `python factorio_ai.py spec recipe|entity X`. 23/09: planned purple science "for the silo tech" — tech was already researched, Space Age recipes differ from wiki memory. A day of purple block for nothing needed.
2. **Chest-fed + remote hauling is a SHORTCUT, not play.** Rocket 1–2 were hand-kitted: chest-fed cells, agent `collect`/`insert` real items batch by batch. Reached the finish line in ~1h, but the base CANNOT launch rocket 3 on its own — silo stops when the agent stops. Factorio's point is automation: a factory that runs without hands. Use the shortcut only for a one-off bootstrap (a silo, a first batch of a new item); the real deliverable is a self-running line (the maintainer agreed 23/09: not the spirit of the game).
3. **Plan by numbers, measure by `flow`.** Belt density / snapshots show stock, not rate; one bottleneck call guessed from density was wrong. `observe(flow, query=a,b@10m)` before any "X is the bottleneck" claim.
4. **Extend, don't clone.** More capacity = widen existing strip.

## Building
5. **Unknown mechanic → one small build, read back, then scale.** Chem plant fluid inputs are on the FACING side; built dir 8 on assumption, had to recall + rebuild.
6. **Read the ground back after every write; the return value lies.** Executor re-placed ghosts name-only → every ug exit came out "input", inserter filters lost, sulfur leaked onto a plastic belt. Only a lanes/entities read-back caught it.
7. **Every new consumer on a shared segment/belt steals from someone.** Battery plant drained the acid meant for PU; cracker ate all light oil meant for solid fuel. Before connecting, list who else draws from that fluid segment / belt lane; recall or isolate the thief.
8. **Cheat crafting speed moves the bottleneck to inserters and their insertion limit.** Limit scales with crafting speed → one inserter dumps ALL of the first ingredient into the machine before touching the next (594 copper in an LDS asm). Load mixed chests with exact recipe totals; expect serial, not parallel, loading.
9. **Treasury (player bag) full silently blocks jobs** (`player-inventory-full` mid-prepare). Keep a junk chest; dump before big collects.
10. **Split big jobs, use exact sites** (CONTRACT.md §Site: exact site = tile-edge anchor, not a centre bbox).

## Tooling
11. **When work gets heavy, stop and improve the tool — then resume.** Wins: A* `route` for belts and pipes (300-tile acid pipe in one call), `{file:}` design rows, `flow` view, `launch` goal. Each paid back within the same day.
12. **A gap in the tool is a gap, not a reason to cheat.** Silo had no insert path → native chest + inserter; no launch path → added `launch` goal. Never Lua-console, never spawn.
13. **Restart discipline:** `luac -p` → copy mod → `cmp` → ask the maintainer to restart Factorio (Lua) and MCP (Python). Lua fix is dead until restart; note it as pending.
14. **Jobs die on transient state** (nil main inventory right after restart). `report(resume=true)` a built job; patch the executor to wait a tick instead of erroring.

## Working with the human
15. **Engineer, not observer:** remote real items are correct; numbers over feel.
16. **Spectacle moments need the human watching.** Rocket 1 launched while the human wasn't looking — had to build rocket 2. Before an irreversible visible milestone, say where to look and wait for "go".
17. **Report mistakes on sight, pivot fast.** The purple-science error was admitted and pivoted in one message; the maintainer approved immediately.
