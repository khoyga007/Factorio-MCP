# Factorio Engineer MCP

`factorio_goal_mcp.py` dùng FastMCP trong official Python SDK (`mcp` 1.x).
Codex chỉ thấy 3 tool: `observe`, `achieve`, `report`. 26 action chi tiết vẫn có
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

Nguồn: [MCP Python SDK 1.27.1](https://github.com/modelcontextprotocol/python-sdk/tree/v1.27.1),
[đăng ký MCP trong Codex](https://developers.openai.com/codex/mcp#configure-with-the-cli).

## Luồng ưu tiên

1. `observe(view="situation"|"deposits"|"nearby")` đọc tóm tắt khi cần.
2. `achieve(goal="first_iron_plates"|"first_copper_plates")` nhận diện cặp
   máy khoan → lò đá đang có, kiểm tra nhiên liệu và nạp lại nếu đủ than. Nếu
   chưa có, planner tìm mỏ, tự đào than bằng 1 gỗ ban đầu khi cần, xây cặp máy
   bằng item thật và bắt đầu audit. `dry_run=true` chỉ trả phương án/blocker.
3. `achieve(goal="coal_stockpile")` dựng hoặc dùng lại 1 khoan đốt nhiên liệu
   đổ than vào rương gỗ kề bên. Dùng nhiên liệu và máy thật, tự chuyển than từ
   rương sát khoan để cấp lại nhiên liệu, đo than tăng trong 1.800 tick và xuất
   blueprint. Thiếu vật tư thì trả blocker, không xây.
4. `achieve(goal="iron_smelting_row", target_per_minute=60)` dùng pattern dãy
   lò lớn. Một lượt gọi MCP tự plan rồi build nếu có vật tư, công nghệ, belt
   quặng–than và điện. Thiếu điều kiện thì trả blocker, không xây.
5. `observe(view="patterns")` liệt kê JSON catalog gọn, không gửi blueprint
   string vào ngữ cảnh AI. `achieve(goal="reuse_blueprint", pattern_id="bp-...",
   x=..., y=...)` nhập lại mẫu native bằng item thật; Lua kiểm tra công nghệ,
   vật tư và va chạm. Mẫu `bp-f30d8a84af3098ee` tự tìm chỗ trên mỏ than nếu
   không đưa tọa độ, thu nguyên liệu thật, chế máy, nhập blueprint, cấp nhiên
   liệu và audit cả hai khoan. Trả job `replica-*`, đọc bằng `report`. Với mẫu
   này `dry_run` kiểm tra thật mặt bằng và nguồn vật tư; thiếu thì không tiêu
   đồ. Những mẫu khác vẫn cần x/y, `dry_run` mới chỉ đọc metadata.
6. `report(job_id)` đọc audit của các pattern. Blueprint và receipt chi tiết
   nằm trong `script-output/starter/`, `script-output/coal/` hoặc
   `script-output/smelting/`.

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
python -m unittest discover -q
python contract_check.py
python verify_smelting_runtime.py
python verify_smelting_runtime.py --player-save 'C:\Users\user\AppData\Roaming\Factorio\saves\Legendary Seed.zip'
python verify_starter_runtime.py --player-save 'C:\Users\user\AppData\Roaming\Factorio\saves\Sandbox.zip'
python verify_coal_runtime.py --player-save 'C:\Users\user\AppData\Roaming\Factorio\saves\Sandbox.zip'
```

Lệnh cuối sao chép save vào `.runtime-test` để kiểm tra chuyển đồ với một player
có inventory; không ghi vào save gốc. Fixture chỉ được chèn vào mod thử nghiệm.
50 test Python (gồm 3 tool MCP và lớp chi tiết 26 action), 28 kiểm tra bản sửa,
74 kiểm tra nung dãy và 20 kiểm tra planner đầu game trong engine đã qua. Ở fixture,
planner sắt và đồng đều dùng 2 lượt gọi (khởi động + kết quả) và tạo 7 plate
trong cửa sổ đo. Không cài `test_*runtime.lua` vào mod thật.

Schema của 23 tool cũ dài 15.208 byte; 3 tool mới dài 2.581 byte (giảm 83%,
đo từ `list_tools` JSON cùng SDK). Đây là kích thước mô tả tool, không phải số
token/quota tài khoản đo trực tiếp. Giao diện mục tiêu hiện hỗ trợ năm goal ở
trên; các dây chuyền khác cần pattern đã thử engine trước khi thêm.
