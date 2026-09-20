# Factorio Engineer MCP

`factorio_goal_mcp.py` dùng FastMCP trong official Python SDK (`mcp` 1.x).
Codex chỉ thấy 3 tool: `observe`, `achieve`, `report`. 25 action chi tiết vẫn có
trong CLI và `factorio_mcp.py` để chẩn đoán, nhưng không chiếm catalog tool của
agent cấp chiến lược. Các kiểm tra vật tư, công nghệ và va chạm nằm trong Lua
ngay trước khi thao tác.

`view` và `goal` nhận chuỗi, rồi server kiểm tra tên hợp lệ. Sau một lần Codex
nạp schema mới, việc bổ sung lựa chọn mẫu/goal không cần đổi schema tool nữa.

## Chạy và đăng ký

```powershell
python -m pip install -r E:\FactorioMayor\requirements-mcp.txt
codex mcp add factorio-engineer -- C:\Python314\python.exe E:\FactorioMayor\factorio_goal_mcp.py
codex mcp get factorio-engineer --json
```

Server chạy qua stdio khi client MCP cần; không cần mở một terminal thường trực.
`FACTORIO_HOST`/`FACTORIO_PORT` mặc định `127.0.0.1:34198`. Game phải nạp map và
bật `--enable-lua-udp 34198` bằng `start-factorio-ai.bat`.
Config Codex global đã trỏ tới `factorio_goal_mcp.py`; server mới liệt kê đúng
3 tool. Game Sandbox đã nạp build `2026-09-18-goals`. Qua MCP thật, goal sắt
nhận ra cặp máy đã có, nạp 1 coal từ kho thật và đo thêm 5 iron-plate trong
1.800 tick; output tăng 8→13. Codex đang mở có thể cache catalog cũ đến khi
nạp lại Codex.

Schema cache (19/09 live): after adding a param (e.g. `design`, observe `pattern_id`/`offset`) server restart serves it, but a client's cached tool description/schema may stay stale until the client session restarts; the call is still accepted. Check CONTRACT.md, not the cached description.

Nguồn: [MCP Python SDK 1.27.1](https://github.com/modelcontextprotocol/python-sdk/tree/v1.27.1),
[đăng ký MCP trong Codex](https://developers.openai.com/codex/mcp#configure-with-the-cli).

## Luồng ưu tiên

1. `observe(view="situation"|"deposits"|"nearby")` đọc tóm tắt khi cần.
   `nearby` (19/09, `perception.py`): all snapshot pages pulled inside (64/page, ≤16 pages), compressed in Python. Keys: `issues` (faults only, full status name: no_power, no_fuel, item_ingredient_shortage, no_research_in_progress...), `machines` {name: rows `at`/`dir`/`status`/`recipe`/`fuel`/`in`/`out`/`fluid`}, `runs` {name: `from`/`to`/`dir`/`items`|`fluid`}, `poles` {name: [[x,y]]}, `resources` [[name,x,y,amount]], `obstacles` {trees: n, rocks: n, cliffs: [n,[x1,y1],[x2,y2]]} (executor mines trees/rocks off build tiles, so only counts; cliffs block → extent), `ground_items` {name: [total, piles, [x1,y1](,[x2,y2])]} (box only when piles spread; per-pile positions via view `entities`).
   - Flow status aliases on rows (not issues): `blocked`=waiting_for_space_in_destination, `idle`=waiting_for_source_items, `full`=full_output.
   - Array row: identical machines evenly spaced on one line → `at`+`n`+`step`; i-th = at + i·step.
   - Run: belt `from`=upstream end; no `to` = single tile; tiles = |dx|+|dy|+1. `dir` omitted for chest/pole/pipe/furnace/lab and dir-0 assemblers.
   - One snapshot = one sample: a burner-fed stone furnace flickers `no_ingredients` (drill 0.25 ore/s < furnace 0.3125) and looks the same as a starved one. Confirm with an executor metric (`products_finished`) before acting.
   - Budget guard: tests/test_perception.py caps (live fixture tests/fixtures/nearby_r32_live.json ≤6000 chars, repetition must not grow output, every tile accounted for). Re-measure live at each scale step: `python tests/measure_nearby.py --x X --y Y --radius 32` (19/09: 25 calls/102 960 chars → 1/6 429, ×16).
   - Live 19/09 r16 (155 entities): old 13 calls/34 455 chars → v1 1 call/4 957 → v2 2 650. `view="entities"` = old raw rows paged by 12 (debug).
2. `observe(view="patterns")` lists catalog (no blueprint string, `has_contract`).
   `achieve(goal="reuse_blueprint", pattern_id, contract?, x?, y?)` → generic
   executor, same path for every pattern. Contract (agent's, else catalog's):
   site search/exact + rotations, resource rules, primer, feeds, holdout
   metrics. Job `exec-N`. Spec: `CONTRACT.md`.
   Layout agent tự nghĩ ra: `achieve(goal="build_design", design=[{name,x,y,direction?}],
   contract)` — cùng đường `blueprint_run`, không có nhánh riêng theo pattern.
   (20/09: 4 goal hard-code `first_iron_plates`/`first_copper_plates`/`coal_stockpile`/
   `iron_smelting_row` đã bị gỡ cùng `starter.lua`+`coal.lua`+`smelting.lua`. Muốn lại
   ô than: `reuse_blueprint(pattern_id="bp-f30d8a84af3098ee")`; muốn dãy lò: agent tự
   thiết kế `design` rồi khai contract, executor lo site/vật tư/primer/audit.)
3. Research: `observe(view="research")`, `achieve(goal="research", tech)`.
   Chụp layout đã xây: `achieve(goal="capture", area=[x1,y1,x2,y2])`. Spec:
   `CONTRACT.md` §Research.
4. Ledger: `observe(view="ledger")` = every block (exec job / hand area) with live status, throughput `flow` (items/min đo thật từ `products_finished`, cộng % thời gian máy chạy) + `edges` [{from,to,item,declared,measured}] — `declared` là ý đồ agent khai (`per_minute` trên link), `measured` là sản lượng thật của block nguồn ở cửa sổ vừa đóng. Declare intent via `contract.block` on build, or `achieve(goal="annotate", contract={block}, area?)`. Spec + executor cheat sheet: `CONTRACT.md` §Ledger, §Executor rules.
5. `report(job_id)` đọc audit của job `exec-N`. Blueprint và receipt chi tiết
   nằm trong `script-output/executor/`.

Một lượt gọi `achieve` có thể dùng nhiều action UDP bên trong; agent chỉ nhận
một kết quả ngắn. Retry UDP dùng lại nonce; nếu mutation timeout, đọc trạng thái
trước khi gọi lại. Cache nonce có giới hạn và không đảm bảo no-op sau load save.

CLI `blueprint-export` lưu string vào file mới; `blueprint-import` mặc định xây
tối đa 64 entity bằng vật tư thật, không cần robot. Đường dẫn file phải tuyệt
đối khi gọi qua lớp MCP chi tiết.

## Các bản sửa trong mod `2026-09-17-mcp-fixes`

- `snapshot`: fluid name/amount/temperature và `belt_to_ground_type`.
- `spec entity`: fluidboxes và cổng native, gồm `positions` của 4 hướng.
- `insert`: rương thường/logistic/linked; giữ luồng furnace `source`/fuel.
- `snapshot(obstacles=true)`: cây, đá, cliff có phân trang riêng.
- `collect`: đồ rơi `item-entity`, nhặt một phần, giữ quality và metadata.
  `ground=true` chọn đồ rơi trùng vị trí máy/rương.
- `place(type="output")`: đầu ra underground-belt; từ chối type cho pipe-to-ground.

`dry_run.can_place` vốn độc lập vật tư, đã kiểm chứng. Rương vô hạn thuộc fixture
Sandbox, chưa được mở làm nguồn vật tư gameplay. Auto-snap, tự ghép cặp và các
guardrail mới ngoài luồng hiện có chưa nằm trong đợt này.

## Kiểm chứng

```powershell
python -m unittest discover -q -s tests -t .
python contract_check.py
python tests/verify_executor_runtime.py --player-save .runtime-test/saves/replica-player.zip
python tests/verify_ledger_runtime.py --player-save .runtime-test/saves/replica-player.zip
python tests/verify_steam_runtime.py --player-save .runtime-test/saves/replica-player.zip
python tests/verify_holdout_fail_runtime.py --player-save .runtime-test/saves/replica-player.zip
```

Lệnh cuối sao chép save vào `.runtime-test` để kiểm tra chuyển đồ với một player
có inventory; không ghi vào save gốc. Fixture chỉ được chèn vào mod thử nghiệm.
66 test Python (gồm 3 tool MCP và lớp chi tiết 25 action) + `contract_check.py` xanh.
Engine 20/09: 10/11 bài verify_*_runtime.py PASS; `verify_economy_runtime.py` FAIL vì
save nguồn đã ăn bản sửa một-lần coal-demo 18/09, hỏng y hệt trước khi refactor.
Không cài `test_*runtime.lua` vào mod thật.

Schema của 23 tool cũ dài 15.208 byte; 3 tool mới dài 2.581 byte (giảm 83%,
đo từ `list_tools` JSON cùng SDK), rồi 3.669 khi thêm design/ledger/recall và
3.285 sau khi gỡ 4 goal hard-code (20/09). Đây là kích thước mô tả tool, không
phải token/quota tài khoản đo trực tiếp.
