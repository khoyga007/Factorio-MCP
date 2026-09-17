# Factorio AI Bridge — handoff: agent → agent, 2026-09-16

## Nung sắt — bàn giao cho người kế nhiệm (2026-09-17, agent)

agent hết quota ngay sau khi hoàn tất + kiểm chứng tool nung sắt. agent commit
checkpoint `b8e9e00` (12 file: `smelting.lua` mới + wiring `control.lua`/
`factorio_ai.py`/`actions.json` + test + `BLUEPRINTS.md` + viết lại `FIELD_NOTES.md`).

Đã kiểm chứng engine thật (benchmark 5700 tick kết thúc `SMELTING_TEST_PASS`):
3 ca audit `passed` — 2 lò 37/phút, 6 lò 112/phút, 3 lò xoay vừa dải hẹp 57/phút,
đều trên target. 42 test Python xanh; blueprint export/import xây bằng vật tư
thật, không cần robot. Bẫy đã sửa: tọa độ tay gắp API trả dạng mảng; vùng chụp
blueprint lấy thêm belt sát mép.

Còn treo:
- Chưa deploy lên save thật: live mod ở build `ore-marks`, thiếu `smelting.lua` +
  blueprint; save của maintainer chưa có belt/tay gắp điện để chạy mẫu.
- Giới hạn 6 lò/dãy (chủ ý validate trước); chưa mở lên quy mô cột nung thật.
- `README` đã doc `smelt-*`; `TOOLKIT_STATUS` có mục nung sắt.

## KHẨN CẤP — checkpoint bàn giao mới nhất (maintainer)

**2026-09-17, lệnh mới nhất: maintainer yêu cầu agent DỪNG và bàn giao cho agent vì hết quota.** agent không thao tác game sau lệnh này. **Ưu tiên khôi phục an toàn trước mọi xây phòng thủ:** ba fast-inserter xuất sắt đã bị mine tạm tại `(7.5,-33.5)`, `(10.5,-33.5)`, `(13.5,-33.5)`, cả ba hướng Bắc (0); item đã hoàn về player treasury, không rơi vãi. Chúng CHƯA được đặt trả. Ba stone-furnace tương ứng tại `(8,-35)`, `(11,-35)`, `(14,-35)` đang working, mỗi output có 13 iron-plate trong snapshot cuối và có thể tiếp tục đầy. agent cần kiểm tra thực địa, đặt trả 3 tay gắp đúng tọa độ/hướng khi maintainer cho phép, rồi nghiệm thu bus sắt. **Đừng tiếp tục kế hoạch gom 80 plate hoặc đặt tháp súng trước khi khôi phục ba tay gắp.** Chi tiết đã gửi agent trong thread `factorio-bridge`.

- Mục tiêu hoàn thành giai đoạn học hỏi: **phóng rocket đầu tiên** bằng tài nguyên thật, không spawn miễn phí. **Mục tiêu cuối dự án** là bộ công cụ + tài liệu bàn giao được cho bất kỳ AI nào để chơi như kỹ sư thực thụ; rocket là bài kiểm tra tích hợp, chưa đủ để tuyên bố toolkit hoàn tất. maintainer đã báo **sinh vật bản địa bắt đầu tấn công**, ra lệnh dừng xây công nghiệp và sau đó **cho phép thi công phòng thủ**. Ưu tiên hiện tại là phòng thủ; chưa quay lại Green Science.
- agent đã hết quota; agent tạm nhận lane xây + tool nhưng cũng hết quota tại checkpoint này. Không có thao tác game nào được thực hiện sau lệnh DỪNG của maintainer.
- Bridge live đã nạp build `2026-09-16-collect-paged-snapshot` (17 actions). `snapshot` phân trang 64 entity và `collect` từ đầu ra lò/máy đã kiểm chứng trên map thật. `luac -p` và 26 unittest đạt; mã nguồn và mod live đồng SHA-256 khi triển khai. Không cần reload mod cho hai tính năng này.
- Trước lệnh DỪNG, agent lấy vật phẩm thật: 1 copper plate và 19+2 iron plates; túi nhân vật theo các receipt cuối có khoảng **22 iron plates, 5 copper plates**. Một fast inserter ở `(13.5,-33.5)` đã được mine tạm rồi đặt trả đúng hướng Bắc; không có công trình mới được xây. Trạng thái save sau các thao tác này **chưa được xác nhận** — đừng khẳng định đã lưu.
- Điểm chưa giải quyết: nguồn sắt đang thiếu so với nhu cầu (audit 10 phút: 112.5 plate/phút sản xuất, 139.8 tiêu thụ); Green Science chưa được agent xây. **Phòng thủ hiện ưu tiên cao hơn**; maintainer đã cho phép xây phòng thủ nhưng chưa cho quay lại mở rộng công nghiệp.
- **Khảo sát read-only sau save/restart 2026-09-17:** build `2026-09-17-brief` live (18 actions). `brief` vùng trung tâm `(10,-28)` ±64 ô đọc 697 công trình trong 1 call, 0 địch ở vùng đó, 3 máy lắp ráp thiếu nguyên liệu. Quét tây nam thấy biter, spitter-spawner và worm quanh `(-105,-130)`, cách mỏ đồng khoảng 70–80 ô theo đường thẳng; đây là vị trí, **chưa chứng minh đang di chuyển/tấn công lúc đo**. Snapshot tìm thấy chỉ một gun turret tại `(13,24)` gần trạm điện, không có turret trong các vùng mỏ đồng/than đã quét.
- **Phương án phòng thủ đang chờ reload:** `insert` đã được vá offline để nhận `ammo-turret`/`turret_ammo` (build `2026-09-17-turret-ammo`, luac + 41 test xanh, source/live mod đồng hash), nhưng game RAM vẫn ở build `2026-09-17-brief`. Cần save/restart trước khi agent nạp đạn. Probe xác nhận chỗ cho hai tháp súng tại `(-52.5,-90.5)` (phía tây mỏ đồng, không đè mỏ trong quét 1 ô) và `(-59.5,-76.5)` (mỏ than). Hai tháp + 5 firearm-magazine mỗi tháp cần 80 iron plates, 20 iron gear wheels, 20 copper plates; lúc đo player có 3 iron plates, 20 gear, 21 copper. Chưa đặt tháp súng mới. Bridge hiện không trả lời dù tiến trình Factorio còn mở; trạng thái game/menu chưa xác nhận, không tự force quit.

agent out of quota mid-lane. maintainer's split: **agent = tool/bridge lane, agent = in-game building lane.** agent inherits the tool/bridge lane. Do not touch agent's entities.

---

## 1. State of the world (measured, tick ~520.9k)

Bridge alive on UDP 34198. Map loaded, 1 player.

Iron line (agent's, do not edit):
- 3 burner drills `#60 (4,-28)`, `#863 (7,-28)`, `#886 (10,-28)` → mixed ore+coal belt Y=-26.5
- 3 stone furnaces, 3rd added by agent at (20,-29) after the bottleneck below
- coal outpost drill `#398 (-52,-72)`, self-feeding dead-end loop, 92-belt trunk to buffer `#651 (2.5,-29.5)`
- `autofuel` OFF since tick ~190.5k. 100% physical fuel.
- ~1253 iron plates across 3 output chests

Ore fields swept (8 probes, radius 32):
- iron: (0,-40) 370k · (30,-40) 327k · (0,0) 254k
- coal: (-48,-72) 79k · (-56,-72) 82k
- **copper: (-40,-96) 70k, (-40,-96)/(-48,-96) full 64/56-tile bins** — 24 tiles north of the coal outpost, reuses its infrastructure
- stone: (-24,-40) 10k · (-32,-40) 9k

**`alien-biomes` is enabled** (`mod-list.json`). It adds many tile variants. Never hardcode tile names.

---

## 2. Shipped this session, NOT YET VERIFIED ON GROUND

Three READ-only actions added to `control.lua` (now 980 lines):

| action | returns | closes which wall |
|---|---|---|
| `tiles` | 8x8 bins of pumpable water + up to 200 individual tiles, **shore tiles ranked first** | no water visibility → no offshore pump → no steam power |
| `probe` | dry run of the exact gate `place` uses (position, item, tech, treasury); `blockers[]` + `would_build` | previously the only way to test a spot was to build then `mine` it back |
| `recipe` | ingredients + **how many you hold** + products; when locked, names the unlocking technology | could not read a recipe → had to guess → violates the no-guessing rule |

Also added: `ping` now returns `build` and the live `actions[]` list. `HANDLERS` forward-declared so `handle_ping` can see it.

**Verification status: `luac -p` green, 13/13 client unittests green. Neither proves a handler runs.** The live process still runs the OLD build (`ping` returns no `build` field). Precedent: TheoTown probe passed luac + pytest and died on first real call.

### The pending step — needs maintainer

Mod code only enters RAM on a Factorio restart. Sequence:
1. agent stops at a clean point and reports on bridge thread `factorio-bridge` (already asked, id `82705521`).
2. maintainer saves (Ctrl+S), quits Factorio fully.
3. maintainer relaunches via `E:\FactorioMayor\start-factorio-ai.bat` (carries `--enable-lua-udp 34198`; a plain launch has no bridge).
4. maintainer loads the save.
5. **Acceptance:** `python factorio_ai.py ping` must return `build="2026-09-16-tiles-probe-recipe"` and 12 actions. Then exercise each of the three for real, and only then promote them out of the "unverified" section of FIELD_NOTES.

Per maintainer's standing rule, this is the ONLY situation where you may ask him to save.

---

## 3. API facts verified from `runtime-api.json` 2.0.77 — do not re-derive

Path: `D:\Factorio-AnkerGames\Factorio\doc-html\runtime-api.json` (also `prototype-api.json`). Machine-readable, grep it instead of reading HTML.

- **`LuaTilePrototype.fluid`** — "The fluid offshore pump produces on this tile, if any." This is the correct, mod-proof water test. Build the tile-name list from `prototypes.tile` at runtime.
- **`LuaForce.get_item_production_statistics(surface)`** → `LuaFlowStatistics`, which has **`get_flow_count`** (value over a time frame), `get_input_count`, `get_output_count`. **This is the missing measurement primitive** — real production rate, no stopwatch. Nobody has used it yet.
- **`LuaTechnology` has NO `effects` field.** Use `tech.prototype.effects` and match `effect.type == "unlock-recipe"` against `effect.recipe`.
- `LuaSurface.find_tiles_filtered{area, name, collision_mask, ...}`, `LuaSurface.get_tile(x,y)`, `LuaSurface.can_place_entity{name, position, direction, force}` — all confirmed signatures.
- Numeric prototype fields that exist and are readable: `mining_speed`, `belt_speed`, `arm_speed_base`, `inserter_pickup_position`, `inserter_drop_position`, `inserter_stack_size_bonus`, `energy_usage`, `tile_width`, `tile_height`, recipe `energy`, `items_to_place_this`.
- `prototypes` is the 2.0 global (not `game.*_prototypes`). Existing code already uses it.
- `Product.amount` may be absent — `amount_min`/`amount_max` instead. Handled in `handle_recipe`.

---

## 4. The doctrine maintainer asked for — "how does an AI actually learn the rules / build like an engineer"

This is the substance of the session. maintainer asked it directly; answer it by building it, not by writing more prose.

### Rules come in three layers. The team only works layer 3.

1. **Layer 1 — what the game already declares. READ it, don't measure it.** Every rate, footprint, reach and recipe time is a number inside the prototypes. The team has been timing 20-second runs and counting plates to derive numbers the game states exactly. Wasteful and less precise.
2. **Layer 2 — the model. MISSING ENTIRELY.** Turn layer-1 numbers into predicting functions. `ore_rate(3 drills)=0.75/s` vs `smelt_rate(2 furnaces)=0.625/s` → 0.125/s surplus → guaranteed backup. Computable before a single entity is placed. agent built it, reported "running at max capacity", and the third drill was sitting in `waiting_for_space_in_destination`. Not carelessness — there was nothing to compute with.
3. **Layer 3 — real new rules: where the ground contradicts the model.** Rule 29 (burner inserter slips its cycle when coal rides an uncompressed belt) is genuinely undocumented; you only learn it by collision. **Only this layer belongs in FIELD_NOTES.** Today the file mixes all three layers, so a real discovery is indistinguishable from a restatement of the manual.

### Two structural failures behind "not yet a real engineer"

**(a) Nobody writes the predicted number BEFORE building, so nobody can ever be wrong, so nobody learns.** Scan the bridge log: "sạch bóng", "hoàn hảo", "sạch 100%", "chạy max công suất", "12/12 PASS". Adjectives. Unfalsifiable. The one report that carried numbers (rule 40: 0.75 vs 0.625) killed the bug the same day. An engineer bets first, in numbers: this cluster will yield 0.625 plate/s, draw 180kW, occupy 6x4. Then measures. Match → the model earns trust. Mismatch → *that* is the new rule.

**(b) A rule in Markdown rots; a rule in a function cannot.** Old rule 3 contradicted `control.lua` for two days and nobody noticed, because Markdown cannot run and therefore cannot fail. Same lesson as TheoTown: store `architect(terrain, physics, style)`, not the blueprint.

### The loop to implement

```
spec    read numbers straight out of the game
  -> model     pure predicting functions, offline-testable
  -> plan      design + PREDICTED NUMBERS + "done" defined numerically
  -> preflight probe the position, and let the model refuse an unbalanced design
  -> build
  -> audit     measure for real, diff against the prediction
                 match    -> model gains trust
                 mismatch -> new rule, write it down
```

The two missing steps are **`plan` writing the number first** and **`audit` diffing it back**. Without them the loop is open and everything else is just building then praising.

### Concrete build order for this lane

1. **`spec`** — dump prototype numbers to a machine-readable file (fields listed in §3). Retires stopwatch measurement.
2. **`model.py`** — pure functions over that spec: rates, capacity, reach, footprint, power, fuel burn. No game calls, unit-testable.
3. **`plan`** — a design is not accepted without predicted numbers attached.
4. **`probe`** (done) + a model check that refuses an unbalanced design *before* resources are spent.
5. **`audit`** — `get_item_production_statistics().get_flow_count` for true throughput, diffed against the plan.
6. **FIELD_NOTES shrinks.** It should only hold places the model was wrong. A file that keeps growing means the model is learning nothing.

Halt condition: **"done" must be a number, never "clean".** Same lesson as TheoTown `city_grow` — missing measurement means keep going, not pass.

---

## 5. Traps found today — already written as FIELD_NOTES rules 41-43

- **41. The mods folder is a COPY, not a junction.** The game loads `%APPDATA%\Factorio\mods\factorio-ai-bridge_0.1.0\control.lua`. Editing the repo and forgetting to copy means the game silently runs old code. Copy, then compare md5. (Checked before patching: both sides were identical, `9a27b54e...` — no drift had accumulated.)
- **42. `LuaTilePrototype.fluid` is the water test.** See §3.
- **43. `snapshot.autofuel.receipts` is a HISTORY LOG, not current activity.** Measured at tick 487,966 while the newest receipt sat at tick 190,500. Read `autofuel.enabled` for actual state.

Rule-number collision: agent wrote its own rule 40 into `FIELD_NOTES.md` while agent was writing hers. agent renumbered her block to 41-43; agent's 40 stands. File now runs 34→43 with no duplicates. **Two agents edit this file — announce before a big edit.**

---

## 6. Files touched, with backups

| file | change | backup |
|---|---|---|
| `factorio-ai-bridge_0.1.0/control.lua` | +3 handlers, ping build stamp, HANDLERS forward-decl | `control.lua.bak` |
| `%APPDATA%\...\mods\factorio-ai-bridge_0.1.0\control.lua` | deployed copy, md5 `0eb6a17c...` matches repo | — |
| `factorio_ai.py` | +3 subcommands | `factorio_ai.py.bak` |
| `test_factorio_ai.py` | +7 tests, 13/13 green | — |
| `FIELD_NOTES.md` | rewrote rules 2,3,10,22; added 39, 41-43; maturity gates re-marked | — |
| `README.md` | new command docs + deploy-trap warning | — |

Earlier in the session, per maintainer's rulings: the resource boundary collapsed to **one hard ban — never spawn items/resources cheat-style**; everything else is legal with receipts, and if short, ask the player to mine more. Rule 10 ("no mass building") is a learning device for unmeasured mechanics, not a permanent ceiling. Both decrees (Prototype-To-Clean-Rebuild, No-Bypass Refactor-First) apply **in-game only**, never to tool source — see rule 39 and nmem `bc72e884`.

---

## 7. Still owed by agent's lane, not Factorio

- review agent `bc4ac9a` (fleet false-green fix, 108 pytest green)
- review agent `e315286` + `cff8219` (`MAYOR_CITY=@open`)
- decide the fate of shared `mcp_config/*` (pinned id vs `@open` vs unset) and whether a write tool should hard-refuse a city that came from env/`@open`

nmem: `bc72e884` (decree scope + Factorio resource boundary) · `97f59c9d` (Ask-maintainer-When-Unclear, tier hot)
