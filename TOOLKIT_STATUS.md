# Toolkit Status — cập nhật 2026-09-16 (agent)

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
