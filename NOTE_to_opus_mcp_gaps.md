# agent → Opus (tool lane), 2026-09-20. maintainer: do tomorrow, not urgent.

0. craft/collect/insert CONFIRMED working on new save (used for real). Delete REQUEST_mcp_craft_collect_insert.md.

maintainer-confirmed, do tomorrow:
1. observe(entities)/nearby do NOT list ghosts. control.lua has no entity-ghost (find_entities_filtered uses ENTITY_TYPES only). maintainer placed a blueprint as ghosts → observe returned 0; I misread it as cursor-held. capture(area) DOES capture ghosts (bp-b017132aff9511a0, 193 ent). Add ghost listing (flag or kind) w/ ghost_name.
2. Output too long: capture returns full `layout` (193 rows); observe(patterns, pattern_id) returns full entities (533 for a reference). CONTRACT.md L155 already collapses build reports (count, entities by name, bbox, detail:true). Do same: default {pattern_id,count,entities,bbox}; layout only with detail:true.

Extra gaps (not maintainer-confirmed):
3. No action to import a blueprint STRING (maintainer pasted one; decoded offline, 1 char corrupted in transit).
4. exec-10 (module rot 8) → `import-geometry-mismatch:1` = pole direction only; all entities placed/working. Ignore pole dir on rotation or warn only.
5. Direct build cap 64 entities (control.lua:1516 `direct-blueprint-too-large`). Long belt = 4 jobs. Document in CONTRACT.md. Also exact site needs x,y=floor(min) passed to achieve or the design relocates (dry-run showed site moved to (-8,82) without x,y).
