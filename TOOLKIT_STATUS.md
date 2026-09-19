# Toolkit Status

## Nhân bản tự động cụm 2 khoan

- `achieve(reuse_blueprint, pattern_id="bp-f30d8a84af3098ee")` không cần
  tọa độ: Lua tự tìm ô than trống, lập kế hoạch thu/chế vật tư từ inventory,
  rương và đầu ra máy trong bán kính tìm kiếm; có thể lấy gỗ/đá từ vật thể tự
  nhiên. Không tự nung thêm sắt nếu không có plate; sẽ báo thiếu trước khi làm.
- Job thực hiện từng bước trong game, giữ receipt, dùng craft có trừ nguyên
  liệu, nhập blueprint và cấp 3 than mồi. Audit sau 1.800 tick yêu cầu cả hai
  vùng khai thác giảm quặng, 10 công trình nguyên vẹn và than trong rương tăng.
- Engine trên bản sao Sandbox qua 12 kiểm tra: mẫu cũ được giữ, thêm đúng
  10 entity, nguyên liệu thực giảm 30 plate/10 stone/2 wood, +12 coal trong
  audit, thiếu nguyên liệu và dry_run không tiêu đồ, job đang chạy không trùng.
  52 test Python và contract 26 action qua. Build `2026-09-18-autonomous-replica`.
- Live sau khi maintainer lưu và cho nạp lại game: một MCP `achieve` chỉ truyền goal
  và ID mẫu, tự chọn (-97,60), thực hiện 13 bước chuẩn bị. `report(replica-1)`
  verified, placed=10, active_drills=2, layout_intact=true, +12 coal/1.800 tick.
  Hai phản hồi dài tổng 507 byte. Receipt ở `script-output/replica/replica-1`;
  đã thu 21 plate thật từ lò, tận dụng drill/rương đang có, chế phần thiếu.
- Luồng live dùng client MCP stdio mới vì tiến trình trong task cache mã cũ;
  game đã đúng build. Đã nhắc maintainer lưu kết quả và reload riêng MCP. JSON mẫu
  tự nâng lên verified sau report và vẫn giữ cùng ID.

## Catalog blueprint JSON 2026-09-18 (agent)

- CLI/MCP tự ghi JSON mẫu theo hash khi import trực tiếp thành công; lệnh
  export ghi `captured`, goal status với audit đạt ghi `verified`. Mẫu giữ native
  blueprint string, loại/số máy, vật tư từng biết và bằng chứng audit; tọa độ
  save không nằm trong template. Ghi file nguyên tử và loại trùng theo hash.
- Giao diện MCP vẫn chỉ 3 tool: `observe(patterns)` trả danh sách ngắn;
  `achieve(reuse_blueprint, pattern_id, x, y)` nhập mẫu bằng item thật, trả
  số công trình và vật tư đã trừ. `dry_run` mới đọc metadata, báo rõ chưa kiểm
  tra vị trí; lần import thật được Lua kiểm tra va chạm, công nghệ và kho.
- Đã seed 2 mẫu từ Sandbox: `bp-f30d8a84af3098ee` (dây 2 khoan, 10 entity),
  `bp-733960267c618197` (ô 1 khoan+rương, audit +6 than). 51 test Python
  qua, gồm ghi tự động sau import/goal audit, loại trùng, MCP 3 tool và
  reuse bằng pattern ID. Client MCP mới live liệt kê 2 mẫu và đọc dry-run.
- Live xuất lại cụm 2 khoan từ tọa độ khác ban đầu tạo hash chuỗi khác nhau.
  ID nay chuẩn hóa vị trí tương đối và thứ tự entity; hai lần xuất cùng layout
  có cùng `bp-f30d8a84af3098ee`. Blueprint có dây mạch đặc biệt giữ hash
  chuỗi gốc để tránh gộp nhầm khi chưa chuẩn hóa các liên kết.

## Cụm 2 khoan–belt–tay gắp 2026-09-18 (agent — đã dựng trên Sandbox)

- Bản sao Sandbox: 2 burner drills → 6 transport belts → 1 burner inserter →
  wooden chest. Bài thử engine chứng minh rương nhận 17 coal sau 2.400 tick;
  blueprint xuất native rồi nhập lại 10/10 entity, trừ đủ 10 item thật của fixture.
- Blueprint tái dùng tại `blueprints/coal-line-v1.blueprint.txt` (354 byte).
  Live import tại gốc (-104,64) dựng 10/10 entity bằng item thật; cấp 3 coal
  thật cho 2 drill và inserter. Snapshot đầu có coal trên belt và 3 coal trong
  rương; sau 30 giây rương tăng lên 29 coal, cả hai drill và tay gắp working.
- Phát hiện `player.cheat_mode=true` làm `begin_crafting` miễn phí/tức thì.
  Đã sửa action `craft` tạm tắt cheat mode trong lúc chế, khôi phục setting
  sau đó; fixture engine chứng minh 4 wood → 2 wood khi chế rương. Action sửa
  một lần đã trừ đúng phần nguyên liệu không bị trừ trong demo ô than cũ:
  9 iron-plate, 5 stone, 2 wood, 3 iron-gear-wheel, 1 stone-furnace. Live
  `repair_demo_economy` có biên nhận và idempotent. Bản build đang chạy là
  `2026-09-18-coal-line-economy`, 26 action; 46 test Python/contract qua.
- Lợi ích đã đo ở khâu xây: 10 lệnh đặt công trình gộp thành 1 lần nhập
  blueprint. Chuẩn bị vật tư và 3 lệnh cấp than vẫn riêng; chưa là một goal
  khép kín cho toàn chuỗi. maintainer đã lưu Sandbox sau demo: ZIP sửa lúc
  2026-09-18 09:56:32 (Asia/Saigon), kiểm tra toàn bộ 54 entry không lỗi.

## Ô khai thác than 2026-09-18 (agent — kiểm chứng trên bản sao Sandbox)

- `achieve(goal="coal_stockpile")` giữ giao diện MCP ở ba tool. Pattern dùng 1
  burner mining drill, 1 wooden chest và 1 gỗ/than thật; chọn ô trên mỏ than,
  kiểm tra va chạm và công nghệ, xây và ghi biên nhận. Than rơi vào rương sát
  khoan; mod cấp lại nhiên liệu từ chính rương đó bằng chuyển item có biên nhận.
- Engine riêng trên bản sao Sandbox: 16 kiểm tra qua, gồm bốn hướng thả quặng,
  thiếu nhiên liệu không xây, `dry_run` không tiêu vật tư, dùng lại ô đã có không
  dựng trùng. Audit 1.800 tick đo rương tăng ròng 8 than từ mỏ thật. Hai lượt
  goal/status trả tổng 621 byte JSON trong fixture; blueprint đã xuất.
- 46 test Python và contract 25 action qua. Starter cũ 20 kiểm tra và dãy lò
  cũ 74 kiểm tra qua sau thay đổi. maintainer lưu và mở lại Sandbox; live `ping` trả
  build `2026-09-18-coal-cell`, 25 action. Live `coal-stockpile --dry-run` tìm
  ô khoan (-92,60), rương (-92.5,58.5), báo thiếu drill/rương/nhiên liệu mồi,
  không xây. Client MCP stdio mới liệt kê đúng ba tool và gọi trực tiếp
  `achieve(goal="coal_stockpile", dry_run=true)` trên live, trả đúng blocker.
  Task Codex này cache schema MCP cũ nên từ chối tên goal mới; cần nạp lại
  Codex để gọi goal trực tiếp từ task hiện hành.
- Khi maintainer yêu cầu biểu diễn trực tiếp, agent thu vật tư thật bằng 8 action
  chẩn đoán: 3 iron-plate từ lò cũ, 1 coal rơi trên đất, 4 wood từ cây, 20
  stone từ đá; chế 3 iron-gear-wheel, 1 stone-furnace, 1 burner-mining-drill,
  1 wooden-chest. Sau đó **một** `achieve(coal_stockpile)` qua client MCP mới
  dựng khoan (-92,60), rương (-92.5,58.5), nạp 1 coal mồi và bắt đầu audit.
  `report(coal-1)` verified: +6 coal ròng trong 1.800 tick, rương có 12 coal
  lúc đọc; `observe` xác nhận khoan working và rương có coal. Receipt live ghi
  2 item đặt, 1 coal mồi thật, các lượt cấp lại từ rương; blueprint 238 byte.
  Phần chuẩn bị vật tư vẫn phải dùng 8 action và là điểm chưa tối ưu; lợi ích
  2 lượt goal/report áp dụng cho phần dựng, duy trì và đo ô than.
- Ô than này tạo nguồn than tại chỗ. Dãy lò lớn vẫn cần nối quặng–than, điện và
  vật tư; chưa thể tự triển khai trọn chuỗi từ save đầu game.

## Giao diện mục tiêu 2026-09-18 (agent — đã nghiệm thu trên Sandbox)

- Codex global `factorio-engineer` trỏ `factorio_goal_mcp.py`, chỉ quảng bá
  `observe`, `achieve`, `report`. 23 action Lua và CLI chi tiết vẫn có. Schema
  tool đo bằng SDK giảm 15.208 → 2.581 byte (83%); chưa đo quota tài khoản.
- `achieve` hỗ trợ `first_iron_plates`, `first_copper_plates`, `iron_smelting_row`.
  Dãy lò: plan và build trong một lượt MCP khi belt, điện, công nghệ và vật tư
  sẵn sàng; thiếu thì trả blocker, không tiêu vật tư. `report` đọc audit theo ID.
- Planner khai cuộc nhận diện cặp drill→furnace sẵn có, báo đúng nhiên liệu thiếu,
  nạp than thật từ treasury khi có và audit lại; không dựng cặp trùng. Bài thử
  engine trên bản sao Sandbox qua 20 check, gồm nhận diện/refuel cặp có sẵn.
- 46 test Python, contract 23 action, Lua parse và benchmark starter đều xanh.
  4 file production trong thư mục mod khớp SHA-256. Sau khi maintainer xác nhận save,
  agent restart Factorio với `--enable-lua-udp 34198 --load-game Sandbox.zip`;
  live `ping` trả đúng build `2026-09-18-goals`, 23 action.
- MCP mới đã gọi `observe(view=situation)` và
  `achieve(goal=iron_smelting_row, target_per_minute=60, dry_run=true)` trên
  save live; dãy lò trả `blocked` với `materials`, `ore-coal-feed`, `power`,
  không xây. `achieve(first_iron_plates, dry_run=true)` nhận diện cặp máy cũ,
  output 8, thiếu 1 coal. Gọi goal thật nạp than có receipt, trả job `starter-1`
  ở trạng thái `auditing`; `report` sau 1.800 tick trả `verified`, sản xuất thêm
  5 iron-plate, output tăng lên 13. Không xây thêm cặp máy.
- Task Codex đang mở có thể cache catalogue MCP cũ; server đăng ký mới quảng bá
  3 tool khi Codex nạp lại.

## Planner khai cuộc 2026-09-17/18 (agent — đã nạp trên Sandbox)

- Build `2026-09-17-starter-smelt` thêm `starter_smelt` và `starter_status` qua
  MCP/CLI (tổng 23 action). Chọn mỏ than/quặng và vị trí cặp burner drill →
  stone furnace. Từ bộ đồ khởi đầu 1 drill, 1 furnace, 1 wood, tự đào than thật,
  thu từng cục than rơi, nhặt lại drill, dựng cặp máy trên mỏ sắt/đồng, nạp fuel,
  đo output và xuất blueprint. Không cần belt, inserter, điện hay robot.
- Thử vật lý trực tiếp trong save Sandbox qua MCP build cũ: dùng 1 wood đào than;
  ô output chỉ giữ 1 than rồi drill chờ chỗ, thu than lần lượt, nhặt drill và
  dựng cặp trên mỏ sắt. Snapshot xác nhận lò chạy và có 2 iron-plate. Đã bật
  `autofuel` lại sau thử nghiệm. Đây là thao tác thật trên Sandbox.
- Test trên bản sao Sandbox trong benchmark: 16 check PASS; planner từ wood tạo
  7 iron-plate, nhánh có sẵn 2 coal tạo 7 copper-plate; mỗi nhánh 2 lượt gọi
  (khởi động + trạng thái), tổng JSON reply 999/777 byte. Blueprint string của
  cả hai cặp được xuất. 45 Python tests + contract 23 action PASS.
- Đã chép đúng 4 file production `control.lua`, `smelting.lua`, `starter.lua`,
  `info.json` vào thư mục mod và đối chiếu SHA-256 từng file. Sau khi maintainer lưu,
  agent đóng game bằng CloseMainWindow và mở lại trực tiếp file `Sandbox.zip`
  với `--enable-lua-udp 34198 --load-game`. Live `ping` trả build
  `2026-09-17-starter-smelt` và 23 action. Một client MCP stdio mới liệt kê
  đủ 23 tool và gọi `starter_smelt(dry_run=true)` vào save đang chạy: planner tìm
  site mỏ than/sắt, không xây, báo thiếu drill/furnace/wood do bộ đồ khởi đầu
  đang nằm trong cặp máy của thử nghiệm trước. Catalog của task Codex đang mở
  vẫn cache 21 tool cũ; cần nạp lại Codex để gọi tên tool mới trực tiếp ở task.

## MCP và bản sửa 2026-09-17 (agent — trạng thái hiện tại)

- `factorio_mcp.py`: 21 tool stdio dùng chung `factorio_ai.execute()` với CLI.
  Server `factorio-engineer` đã đăng ký và bật trong Codex global; xem `MCP.md`.
- Mod build `2026-09-17-mcp-fixes`: fluids/ports, insert rương, snapshot vật cản,
  nhặt đồ rơi giữ stack metadata, tham số input/output của underground-belt.
  Giữ `dry_run.can_place` độc lập vật tư như code gốc.
- 44 test Python qua, gồm client MCP stdio gọi đủ 21 tool vào UDP peer thử nghiệm.
  Engine thật qua 28 kiểm tra các bản sửa + 74 kiểm tra nung/blueprint trong bản
  sao save tách biệt; không thay đổi save đang chơi.
- Đã chép `control.lua`, `smelting.lua`, `info.json` vào mod game và đối chiếu SHA-256.
  Sau khi maintainer reload ngày 2026-09-17, MCP gọi trực tiếp trên save mới nhất:
  `ping` trả build `2026-09-17-mcp-fixes`, 21 action, 1 player;
  `brief` đọc khu vực người chơi và treasury; `spec(entity=boiler)` trả 2
  fluidbox và native port positions; `place(dry_run=true)` trả `probe`
  với `can_place=true`, `have=81`, `would_build=false`, blocker
  `technology-locked`. Không tiêu vật tư trong lệnh thử này.
- Kiểm chứng live hiện mới gồm lệnh đọc và `dry_run`. Chưa gọi các lệnh xây,
  nhặt hay nhập blueprint làm đổi save thật. Các ca đó đã qua test engine
  trên bản sao save tách biệt.

Các mục dưới đây là lịch sử theo thời điểm, không thay thế trạng thái trên.

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
