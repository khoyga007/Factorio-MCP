# Factorio Engineer Toolkit — thiết kế cấu kiện + nguồn từng phần

Bản nháp để anh maintainer duyệt. Căn cứ: README.md (vạch đích rocket + định nghĩa kỹ sư),
HANDOFF.md §3-§4 (doctrine + build order), RECON_AI_FACTORIO_LANDSCAPE.md (4 dự án + FLE).
Mọi "mình đã có / chưa có" đều đối chiếu `control.lua` (17 handler) + `factorio_ai.py`.

## 0. Định nghĩa "tool hoàn chỉnh"

Không phải "nhiều handler hơn". Hoàn chỉnh = **vòng kỹ sư khép kín và tự kiểm chứng được**:

```
spec → model → plan(có số dự đoán) → preflight → build → audit(đối số) → [khớp: tin model | lệch: ghi luật mới]
                                                              ↘ sự cố: alert → chẩn đoán → sửa → đo lại
```

Vòng này KHÔNG được đứt ở hai chỗ mà HANDOFF §4 đã chốt: `plan` phải ghi số trước, `audit` phải
đối số lại. Mọi cấu kiện dưới đây phục vụ đóng kín hai chỗ đó.

## 1. Cái gì MÌNH ĐÃ CÓ (không lấy gì thêm)

| Cấu kiện | Hiện trạng | Chứng cứ |
|---|---|---|
| Đọc số prototype từ game (`spec`) | có | `handle_spec` control.lua:870 |
| Preflight vị trí (`probe`) | có | `handle_probe` control.lua:722 |
| Recipe + số đang có (`recipe`) | có | `handle_recipe` control.lua:788 |
| Đo throughput thật (`get_flow_count`) | có, nhưng chưa làm thành holdout | control.lua:954-958, HANDOFF §3 |
| Đọc ruột từng belt (`get_transport_line`) | có, nhưng là phẳng | control.lua:210-214 |
| Trạng thái từng entity (`status`) | có, nhưng không ai đọc | control.lua:190-205 |
| Xây/mine/fuel/collect/insert/research | có (17 handler) | HANDLERS control.lua:1205-1221 |

→ **Không được làm lại những cái này.** Khiếm khuyết của chúng là THIẾU TẦNG ĐÁNH GIÁ, không phải thiếu dữ liệu.

## 2. Lấy thẳng (bản đã có người viết, đặt tên sẵn) — từ factorioctl

MarkMcCaskey đã viết và chạy thật các hàm này. Mình **không cần nghĩ lại tên và thuật toán**:

| Cấu kiện cần thêm | Lấy từ factorioctl | Lấp lỗ nào |
|---|---|---|
| **Belt topology** | `analyze_belt_networks`, `analyze_belt_gaps`, `trace_belt_sources`, `get_belt_lane_contents`, `detect_sushi_belts`, `analyze_inserters` | Lỗ lớn nhất: mình thấy "belt chở gì", không thấy "đi từ đâu tới đâu, kẹt ở đâu" |
| **Route belt có A*** | `route_belt` (có underground + zone-aware) | "đừng bắt LLM tìm đường" — đúng HANDOFF §4 |
| **Cảnh báo sự cố** | `get_alerts` (drill rỗng / hết nhiên liệu / **enemy**) | Ứng phó sự cố = 0 hiện nay |
| **Vị trí máy trên belt** | `get_machine_belt_positions` | Tiền đề để nối belt đúng làn |

## 3. Chuyển thể ý tưởng (không copy code, lấy cơ chế)

| Cấu kiện | Nguồn ý | Mình sẽ làm thành |
|---|---|---|
| **Contract một nguồn** | companion `commands.json` + FLE "API schema tự sinh từ client+server" | 1 file khai báo: args + bounds + precondition + doc. Sinh ra: `HANDLERS`, subcommand `factorio_ai.py`, doc. Xoá 3 chỗ khai tay lệch nhau |
| **Zone / vùng bảo vệ mỏ** | factorioctl `create_zone`/`scan_resources`/`get_protected_resources` (memory ngoài game) | Chặn agent bịt mỏ quặng. Có tiền lệ bên TheoTown (`zone`/`dezone`) |
| **Trần chờ / trần chạy** | FLE "programs that take too long are terminated" | Giới hạn `waiting_for_space_in_destination` — máy đứng chờ vô hạn phải báo, không im lặng |
| **Predicate trạng thái** | FLE dùng `entity.status` + factorioctl `diagnose_area` | Biến `status`/`status_name` (đã có) thành "máy nào đứng, vì sao". KHÔNG phải thêm dữ liệu — thêm phép đánh giá |
| **Holdout theo ngưỡng** | FLE: throughput ≥ ngưỡng VÀ giữ được 60s | `audit` hiện là ảnh chụp; thêm "đạt ngưỡng và giữ" để "done = số, không phải tính từ" |

## 4. Test offline bằng engine giả — lấy cơ chế từ factorio-ai-companion

Họ chạy Lua production trong **Fengari** (Lua-in-JS) với "deterministic engine doubles" — không mở game.
HANDOFF §2 đã ghi: `luac -p` + unittest **không chứng minh handler chạy**. Đây là khoảng trống cần đóng.

Mình sẽ dùng cái gì tương đương về nguyên lý, không nhất thiết Fengari:
- **`model.py`** = pure Python, test bằng pytest (đã có tiền lệ `test_factorio_model.py`).
- **`factorio_ai.py`** = test contract, không test game.
- **Tầng Lua handler** = đây mới cần engine giả: mock `game`/`script`/`prototypes` để gọi `handle_*` thật
  và kiểm tra giá trị trả về. Đây là phần tốn công nhất và đáng làm NHẤT, vì nó là thứ duy nhất
  bắt được lỗi kiểu "probe xanh luac rồi chết ở lần gọi thật".

## 5. Bỏ (đã quyết, không tranh luận lại)

- **GraphRAG index wiki + mod, paper Minecraft memory** (arXiv 2305.16291) — nhồi luật vào context,
  ngược "luật nằm trong hàm".
- **Điều khiển nhân vật / walk_to / tầm tay** (FactoMCP, factorioctl) — mình bỏ cả tầng đó vì đã gọi API.
- **Partial observability / fog-of-war** (FLE) — che map chỉ phục vụ eval, làm mình mù lúc debug.
- **REPL tự viết Python / `run_lua`** (FLE, FactoMCP, factorioctl) — mở cửa sau cho cheat. Cấm.
- **CV/YOLO nhìn màn hình** (airi-factorio) — chậm, mờ, mình có số chính xác rồi.

## 6. Thứ tự xây (mỗi bước độc lập, offline được ngoài bước 5-6 cần game)

| # | Bước | Cần game? | Giải quyết gì |
|---|---|---|---|
| 1 | `spec` → dump số prototype ra file máy đọc được | không (đọc runtime-api.json + code có sẵn) | nghỉ đo stopwatch |
| 2 | `model.py` pure + pytest | không | layer 2 — dự đoán trước khi xây |
| 3 | Contract một nguồn (khai báo 17 handler + args/bounds) | không | hết lệch 3 chỗ |
| 4 | Engine giả cho handler Lua + test sống | không | đóng lỗ "luac xanh nhưng chết thật" |
| 5 | Predicate trạng thái → `diagnose`/`alerts` | cần | drill #863 kiểu im lặng |
| 6 | Belt topology (trace/network/lane/gaps) | cần | đọc được dòng chảy |
| 7 | Zone + chặn bịt mỏ | cần (đọc map) | hết đập đi xây lại |
| 8 | Holdout ngưỡng cho `audit` + `plan` ghi số | cần | "done = số" |

→ **Bước 1-4 làm được NGAY, không cần anh save, không đụng entity nào của agent.** Bước 5-8
chỉ cần map chạy khi tới lượt, và mỗi bước là một lần ping/đọc, không phải sửa save.

## 7. Ranh giới không được vượt (giữ nguyên)

- Không spawn item/resource. Không `run_lua` tùy ý. Không điều khiển nhân vật.
- Luật thật sự mới → `FIELD_NOTES.md`, còn số prototype/recipe → hàm, không phải markdown.
- Mọi dự đoán ghi số TRƯỚC khi xây; mọi "done" là số.
