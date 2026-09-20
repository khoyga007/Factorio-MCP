# Factorio Mayor — AI chơi Factorio như một kỹ sư

Bộ công cụ cho một AI agent tự chơi **Factorio 2.0**: đọc bản đồ, tự thiết kế dây chuyền theo luật game, xây bằng **vật tư thật**, rồi đo xem dây chuyền có thực sự chạy không. Không spawn đồ, không cheat, không chạy Lua tùy ý.

- **Vạch đích giai đoạn học:** phóng rocket đầu tiên bằng nhà máy do agent xây và vận hành.
- **Sản phẩm cuối:** bộ tool và tài liệu, để bất kỳ AI nào tiếp quản cũng chơi tiếp được như một kỹ sư: đo trước khi xây, kiểm tra kết quả, sửa khi thực tế lệch dự đoán.

## Cách hoạt động

```
Agent (Claude / Codex / Gemini)
   │  MCP stdio: observe · achieve · report
   ▼
factorio_goal_mcp.py ── blueprint_library.py (catalog, encode thiết kế → blueprint string)
   │  UDP localhost:34198
   ▼
Mod factorio-ai-bridge (Lua, chạy trong game)
   ├─ control.lua   cổng action, kho vật tư, research
   ├─ executor.lua  executor blueprint dùng chung: tìm chỗ → gom/craft đồ → xây → nạp → audit
   └─ field.lua     tìm chỗ đặt bơm nước, thu hồi công trình
```

**Agent thiết kế, tool thực thi.** Agent tự tính layout (kích thước máy, vùng đào, tầm inserter, tỉ lệ) và khai báo một *contract*: cách tìm chỗ, yêu cầu mỏ, điện/nước, đồ nạp ban đầu, và chỉ số nghiệm thu. Executor kiểm tra, xây, rồi chạy **holdout audit**: đo theo từng cửa sổ thời gian, và window cuối phải đạt. Chỉ layout **tự duy trì** (window cuối không cần executor tiếp liệu) mới được lên `verified` trong catalog.

## Cài đặt

Yêu cầu: Factorio 2.0.77, Python ≥ 3.11, gói `mcp` ≥ 1.27.1.

1. **Mod:** chép thư mục `factorio-ai-bridge_0.1.0/` vào `%APPDATA%\Factorio\mods\`.
   > Game nạp **bản sao** chứ không phải repo. Sửa Lua xong phải chép lại và **khởi động lại Factorio**.
2. **Bật cổng UDP:** chạy `start-factorio-ai.bat`, hoặc tự thêm `--enable-lua-udp 34198` khi mở `factorio.exe`. Sửa đường dẫn exe trong file `.bat` nếu máy khác. Mở một map có bật mod.
3. **MCP server:**

   ```powershell
   python -m pip install -r requirements-mcp.txt
   claude mcp add factorio-engineer --scope user -- python E:\FactorioMayor\factorio_goal_mcp.py
   # hoặc Codex:
   codex mcp add factorio-engineer -- python E:\FactorioMayor\factorio_goal_mcp.py
   ```

   Host/port lấy từ `FACTORIO_HOST` / `FACTORIO_PORT`, mặc định `127.0.0.1:34198`. Sửa Python xong phải khởi động lại phiên agent để nạp schema tool mới.
4. **Kiểm tra:** gọi `observe(view="situation")`. Kết quả phải có tên build của mod (hiện tại `2026-09-19-ledger`).

## Ba tool MCP

| Tool | Dùng để |
|---|---|
| `observe(view=…)` | `situation` · `deposits` (mỏ) · `nearby` (1 lần gọi: lỗi lên đầu, máy, đoạn belt/ống gộp, cột điện) · `entities` (dữ liệu thô, debug) · `water` (chỗ đặt bơm) · `research` (tiến độ, hàng chờ, lab) · `patterns` (catalog, `pattern_id` để xem layout) |
| `achieve(goal=…)` | `build_design` (layout agent tự thiết kế) · `reuse_blueprint` (mẫu trong catalog) · `capture` (chụp vùng đã xây vào catalog) · `recall` (thu hồi công trình về túi) · `research` · `annotate` (ghi ý đồ vào ledger). Có `dry_run` để xem trước. |
| `report(job_id)` | Trạng thái job `exec-N`: vị trí, vật tư, từng window audit, `self_sustaining` |

Ví dụ minh họa cú pháp: 1 khoan than quay mặt về Bắc, đổ than vào rương ngay phía trên (layout lấy từ `tests/designs/coal-drill-chest.json`, đã test trong engine).

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

Layout này **không tự duy trì**: đốt hết than nạp ban đầu thì khoan tắt. Muốn tự duy trì phải có đường than quay về khoan, ví dụ vòng belt + inserter như mẫu `bp-888ab81fe7579dfd`.

Tọa độ là tâm entity: máy có cạnh lẻ đặt ở `.5`, cạnh chẵn đặt ở số nguyên. Hướng dùng hệ 16: `0` Bắc · `4` Đông · `8` Nam · `12` Tây. Chỉ số nghiệm thu gồm `container_gain`, `working_count`, `products_finished`, `research_units`, `electric_output_mw`, `fluid_temperature`, `fuel_min`. Đặc tả đầy đủ ở **[CONTRACT.md](CONTRACT.md)**.

## Tài liệu

| File | Nội dung |
|---|---|
| [CONTRACT.md](CONTRACT.md) | Đặc tả contract, executor, metric, điện/nước, research, field actions |
| [MCP.md](MCP.md) | Chạy MCP server, luồng ưu tiên, cache schema |
| [FIELD_NOTES.md](FIELD_NOTES.md) | Luật game đã đo thực tế và luật chơi của dự án |
| [LEARNING_PROGRESSION.md](LEARNING_PROGRESSION.md) | Nhật ký quan sát theo thời gian |
| [BLUEPRINTS.md](BLUEPRINTS.md) | Quy trình tạo và nghiệm thu blueprint |
| [NEXT_SESSION.md](NEXT_SESSION.md) | Checkpoint cho phiên làm việc tiếp theo |
| [docs/CLI.md](docs/CLI.md) | CLI `factorio_ai.py`, chỉ dùng để chẩn đoán |
| `skills/` | Hướng dẫn theo giai đoạn: khai cuộc, nung, science đỏ/xanh/lam, rocket |
| `blueprints/catalog/` | Mẫu đã lưu, kèm trạng thái `designed` → `built` → `verified` |
| `reference/` | Mã tham khảo bên ngoài (skyline624, có LICENSE riêng) |

## Kiểm thử

```powershell
python -m unittest discover -s tests                  # unit test + kiểm hợp đồng action
python tests\verify_metrics_runtime.py --player-save .runtime-test\saves\replica-player.zip
```

Mỗi `tests/verify_*_runtime.py` chạy Factorio headless (`--benchmark`) trên **bản sao** save với mod đã chép vào `.runtime-test/`. Thư mục này bị gitignore: cần tự tạo `config.ini` và một save. Đường dẫn `factorio.exe` đang viết cứng trong các script. `contract_check.py` giữ `actions.json`, bảng handler Lua và CLI khớp nhau.

## Luật chơi

- Mọi thao tác trong game đi qua MCP. CLI chỉ để chẩn đoán.
- Chỉ dùng vật tư thật lấy từ túi hoặc kho của người chơi, và mỗi lần chuyển đồ có receipt. Không spawn.
- Công nghệ chưa mở thì bị chặn. Không có lệnh Lua tùy ý.
- Cây, đá nằm trên ô công trình thì executor tự đào trước khi xây, gỗ/đá vào túi có receipt. Ngoài ô công trình không đụng tới (cây hút ô nhiễm). Vách đá (cliff) cần thuốc nổ nên không dọn: vị trí đó bị từ chối với lý do `cliff`.
