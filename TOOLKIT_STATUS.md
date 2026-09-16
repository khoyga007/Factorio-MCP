# Toolkit Status — cập nhật 2026-09-16 (agent)

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
20 test offline, tất cả xanh:
`python -m unittest test_contract test_spec_loader test_model_from_spec test_factorio_model`

## Chưa làm / chờ maintainer
- **Bước 4** (engine giả chạy handler Lua offline) — đắt nhất, cần maintainer duyệt trước.
- **Bước 5-8** cần game chạy: diagnose/alerts, belt topology, zone bảo vệ mỏ, holdout threshold.
- STOP order vẫn active; chưa vào game, chưa đụng entity nào của agent.
