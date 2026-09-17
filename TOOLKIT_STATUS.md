# Toolkit Status — cập nhật 2026-09-16 (agent)

## Nung sắt 2026-09-17 (agent; agent commit bàn giao)
- Thêm `smelt-plan`/`smelt-build`/`smelt-status`: tính dãy lò đá (tối đa 6 lò), tìm
  chỗ + hướng, nối belt cấp liệu quặng–than, preflight rồi xây bằng vật tư thật có
  receipt, audit đo sản lượng thật. Kèm `blueprint-export`/`blueprint-import` xây
  trực tiếp bằng item thật, không cần robot.
- Kiểm chứng engine thật (benchmark `.runtime-test`, 5700 tick): `SMELTING_TEST_PASS`;
  3 ca audit `passed` — 2 lò 37/phút, 6 lò 112/phút, 3 lò xoay vừa dải hẹp 57/phút.
  42 test Python + 74 check runtime xanh (4 ca từ chối đúng: thiếu item, khoá tech,
  site đổi).
- Bẫy đã sửa khi thử engine thật: API trả tọa độ tay gắp dạng mảng; vùng chụp
  blueprint có thể lấy thêm belt sát mép.
- Chưa deploy lên save thật: live mod vẫn build `ore-marks`, thiếu `smelting.lua`;
  save của maintainer chưa có belt/tay gắp điện. Giới hạn 6 lò/dãy, chưa mở lên cột nung thật.

## Dấu mỏ 2026-09-17 (agent)
- `index` nay lưu mọi vùng tài nguyên 32×32 ô đã quét vào storage của save, giữ dấu cả khi mỏ cạn. `ore-marks` đọc lại theo loại quặng và phân trang; `index` báo tổng dấu đã lưu.
- Đã qua `luac -p`, 27 test Python và contract 18 actions; bản mod đã được chép sang thư mục Factorio và khớp SHA-256. Game đang chạy build cũ, nên chức năng mới cần save/restart/load và live-check build `2026-09-17-ore-marks`.

## Bổ sung blueprint 2026-09-17 (agent)
- Bridge và CLI có `blueprint-export` (chụp vùng đã xây, lưu blueprint string) và `blueprint-import` (mặc định xây trực tiếp bằng item thật trong treasury; `--ghosts` để dành cho robot). Blueprint không tạo công trình hay vật tư miễn phí.
- Mã đã kiểm tra bằng `luac -p`, 26 test Python và contract 17 actions; bản mod trong thư mục Factorio khớp SHA-256 với source. Trên map mới, ping xác nhận build `2026-09-17-blueprint-direct`; xuất vùng trống trả `empty-blueprint`; nhập blueprint hợp lệ cần 2 burner drills khi chỉ có 1 trả `insufficient-items` trước khi đặt gì (snapshot vùng đích rỗng, inventory vẫn còn 1 drill). Chưa nghiệm thu xuất cụm thật và xây trực tiếp thành công vì map mới chưa có cụm để sao chép.

## Bổ sung 2026-09-17 (agent)
- `survey.py` nay đọc hết các trang snapshot rồi tóm tắt máy/trạng thái/vật tư trong một lệnh; `--details` mới in từng entity. Có test phân trang.
- Read-only `brief` đã thêm vào mod + CLI + `actions.json` (18 action): tóm tắt máy lỗi và địch gần nhất trong một gói UDP. **Đã live-verified sau khi maintainer save/restart/load**: ping build `2026-09-17-brief`, vùng trung tâm có 697 entity và `brief` trả trong 1 call thay vì 11 trang snapshot; vùng tây nam phát hiện biter/spawner/worm. Chỉ quan sát, lệnh DỪNG xây/khai thác/chuyển vật phẩm của maintainer vẫn còn hiệu lực.
- maintainer đã cho phép chuyển sang phòng thủ. `insert` được mở rộng cho kho đạn gun turret với item thật và kiểm tra sức chứa; build `2026-09-17-turret-ammo` **đang staged, chưa live-verified**. Cần save/reload an toàn trước khi tự nạp đạn bằng bridge.

## Đã xong (offline, không cần game)
- **Bước 0**: git init + backup toàn bộ hiện trạng (root commit `9280c62`).
- **Bước 1 — spec dump**: `spec_loader.py` (schema + loader đọc `spec.json`),
  `spec_export.py` (gom prototype từ game, chạy khi có map), `spec_sample.json`
  (fixture số từ test cũ), `test_spec_loader.py`. Commit `f638909`.
- **Bước 2 — model**: `factorio_model.py` (đã có sẵn 101 dòng) bổ sung
  `mining_to_crafting_from_spec` + `belt_capacity_from_spec` đọc số từ `spec.json`.
  `test_model_from_spec.py`. Commit `ef7ceeb`.
- **Bước 3 — contract một nguồn**: `actions.json` (17 action + args),
  `contract_check.py` so khớp 3 nơi (HANDLERS trong `control.lua` + subparser/command_body
  trong `factorio_ai.py`), `test_contract.py`. Commit `2d1b197`.

## Test
42 test offline xanh:
`python -m unittest test_contract test_factorio_ai test_factorio_model test_model_from_spec test_spec_loader`
Kiểm chứng runtime nung sắt: `python verify_smelting_runtime.py` chạy lại bài test
`test_smelting_runtime.lua` trong engine benchmark và kết thúc `SMELTING_TEST_PASS`.

## Chưa làm / chờ maintainer
- **Bước 4** (engine giả chạy handler Lua offline) — đắt nhất, cần maintainer duyệt trước.
- **Bước 5-8** cần game chạy: diagnose/alerts, belt topology, zone bảo vệ mỏ, holdout threshold.
- STOP order vẫn active; chưa vào game, chưa đụng entity nào của agent.
