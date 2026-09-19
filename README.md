# Factorio AI Bridge

Prototype tối thiểu để nghiên cứu cách AI đọc một vùng bản đồ và xây trực tiếp trong Factorio 2.0.77.

**Vạch đích giai đoạn học hỏi (maintainer chốt 2026-09-16): phóng thành công rocket đầu tiên** bằng nhà máy do agent xây/vận hành với tài nguyên thật, không spawn miễn phí. Các mốc nghiên cứu, sản lượng và hạ tầng chỉ là bước trung gian phục vụ vạch đích; không mở rộng vô hạn chỉ vì còn có thể xây.

**Mục tiêu cuối của dự án:** bàn giao bộ công cụ và tài liệu để bất kỳ AI tiếp quản nào cũng có thể chơi Factorio như một kỹ sư thực thụ: đọc luật từ game, dự đoán bằng số trước khi xây, kiểm tra vị trí và nguồn lực, xây bằng vật tư thật, đo kết quả, sửa mô hình khi thực tế khác dự đoán, ứng phó sự cố và tiếp tục từ một handoff rõ ràng. Lần phóng rocket là bài kiểm tra tích hợp của bộ công cụ này, không phải điểm kết thúc của việc đóng gói và bàn giao.

> **Trạng thái: đã qua Discovery (2026-09-16).** Luật cốt lõi đã đo xong và ghi
> trong `FIELD_NOTES.md`; xây hàng loạt và tối ưu theo tính toán được phép. Cơ chế
> game MỚI chưa đo thì vẫn quay về nhịp thí nghiệm nhỏ, đo trước/sau. Kiến trúc
> tool chỉ sửa khi có lỗi/giới hạn đã tái hiện (luật 39).

Ranh giới gameplay:

- Không điều khiển nhân vật, không giới hạn tầm với.
- Chỉ đặt được entity hợp lệ, không xuyên địa hình hay công trình khác.
- Mỗi công trình trừ đúng vật phẩm từ inventory người chơi ở bước bootstrap,
  rồi từ rương được chọn làm kho xây dựng.
- Công nghệ chưa mở vẫn bị chặn.
- Không có lệnh chạy Lua tùy ý.
- Máy đào cần storage hoặc consumer ở đúng đầu output; chuỗi burner đầu game
  dùng hòm gỗ để nhận quặng.

Các phát hiện, mức độ chắc chắn và quy tắc thử nghiệm nằm trong
[`FIELD_NOTES.md`](FIELD_NOTES.md).

## Chạy thử

1. Thoát Factorio hiện tại.
2. Chạy `start-factorio-ai.bat` để bật cổng UDP localhost `34198`.
3. Tạo hoặc mở một map. Mod phải hiện trong danh sách mod đã bật.
4. Kiểm tra cầu nối:

```powershell
python E:\FactorioMayor\factorio_ai.py ping
python E:\FactorioMayor\factorio_ai.py snapshot
python E:\FactorioMayor\factorio_ai.py brief --x 10 --y -28 --radius 64
python E:\FactorioMayor\survey.py 10 -28 32
python E:\FactorioMayor\factorio_ai.py snapshot --x 27 --y -2 --radius 28 --offset 64
python E:\FactorioMayor\factorio_ai.py index
python E:\FactorioMayor\factorio_ai.py ore-marks --name iron-ore
```

Khai cuộc trên map có máy khoan đốt nhiên liệu, lò đá và 1 gỗ: planner tự lấy
than thật, ghép máy khoan nhả thẳng vào lò, rồi đo plate đầu ra. Không cần
belt, inserter, điện hay robot. Nếu thiếu đồ/mỏ/vị trí thì trả blocker và không
xây. Dùng `--dry-run` để chỉ xem phương án.

```powershell
python E:\FactorioMayor\factorio_ai.py starter-smelt iron-plate
python E:\FactorioMayor\factorio_ai.py starter-status starter-1  # thay bằng job_id vừa nhận
```

MCP dùng `achieve(goal="first_iron_plates")` và `report(job_id)`; xem [MCP.md](MCP.md). Blueprint
cặp máy được lưu trong `script-output/starter/` khi xây thành công.

Nguồn than đầu game: `achieve(goal="coal_stockpile")` dùng 1 khoan đốt nhiên liệu,
1 rương gỗ và 1 gỗ/than thật để tạo ô khai thác than có cấp nhiên liệu lại từ
rương kề bên. `report(job_id)` đo than tăng và blueprint nằm trong
`script-output/coal/`. Luồng CLI tương ứng là `coal-stockpile` và `coal-status`.

Để thử xây thật, đặt một rương, bỏ vật phẩm xây dựng vào đó, rồi dùng tọa độ rương:

```powershell
python E:\FactorioMayor\factorio_ai.py treasury 10.5 20.5
python E:\FactorioMayor\factorio_ai.py place transport-belt 14.5 20.5 --direction east
python E:\FactorioMayor\factorio_ai.py insert coal 1 14.5 20.5
python E:\FactorioMayor\factorio_ai.py craft iron-gear-wheel 2
python E:\FactorioMayor\factorio_ai.py mine stone-furnace 4 -23
python E:\FactorioMayor\factorio_ai.py collect iron-plate 6 9.5 -26.5
python E:\FactorioMayor\factorio_ai.py collect iron-plate 20 14 -29
python E:\FactorioMayor\factorio_ai.py autofuel on
```

Đọc mặt đất trước khi xây (không tiêu gì, không xây gì):

```powershell
python E:\FactorioMayor\factorio_ai.py snapshot --tiles --obstacles --x 10 --y -28 --radius 32
python E:\FactorioMayor\factorio_ai.py place offshore-pump 12.5 -30.5 --direction south --dry-run
python E:\FactorioMayor\factorio_ai.py spec recipe --entity lab
python E:\FactorioMayor\factorio_ai.py spec entity burner-mining-drill
python E:\FactorioMayor\factorio_ai.py spec entity stone-furnace
python E:\FactorioMayor\factorio_ai.py spec entity iron-ore
python E:\FactorioMayor\factorio_ai.py spec recipe iron-plate
python E:\FactorioMayor\factorio_ai.py audit iron-plate --expected-per-second 0.625
python E:\FactorioMayor\factorio_ai.py set-recipe iron-gear-wheel 26.5 -27.5
python E:\FactorioMayor\factorio_ai.py set-recipe automation-science-pack 26.5 -23.5
python E:\FactorioMayor\factorio_ai.py research
python E:\FactorioMayor\factorio_ai.py research fast-inserter --start
python E:\FactorioMayor\factorio_ai.py insert automation-science-pack 10 30.5 -23.5
python E:\FactorioMayor\factorio_ai.py insert firearm-magazine 5 13 24
```

Blueprint: xuất một cụm đã xây thành string có thể nhập trong Factorio, rồi xây
lại cụm đó bằng vật tư thật tại nơi khác. Không cần robot. File đầu ra phải chưa tồn tại; mỗi vùng tối đa
64×64 ô và string tối đa 24.000 ký tự.

```powershell
python E:\FactorioMayor\factorio_ai.py blueprint-export 0 -20 20 0 E:\FactorioMayor\my-smelter.txt
python E:\FactorioMayor\factorio_ai.py blueprint-import E:\FactorioMayor\my-smelter.txt 40 20
```

`blueprint-import` mặc định kiểm tra tổng vật tư trong treasury, đặt ghost theo
build mode thường rồi dựng trực tiếp từng entity và trừ vật tư có receipt. Nếu
một entity lỗi giữa chừng, lệnh báo số đã xây và số vật tư đã tiêu; phần ghost
còn lại được dọn. Chế độ trực tiếp giới hạn 64 entity mỗi module. Thêm
`--ghosts` nếu muốn robot xây về sau. String trong file
cũng nhập được bằng nút Import string của Factorio.
Hai action này đã kiểm thử trong engine bằng save tách biệt; xem [MCP.md](MCP.md)
cho build hiện tại và cách gọi trực tiếp bằng MCP.

Nung sắt: `smelt-plan` tính một dãy lò đá (tối đa 6 lò) đủ chạm mức đĩa/phút yêu
cầu, tìm chỗ đặt + hướng, nối một nhánh belt cấp liệu tới belt quặng–than gần
nhất, rồi trả kế hoạch ngắn: số lò, vật tư còn thiếu, vị trí, nguồn cấp và cách đo
sản lượng. Thiếu điện hoặc nguồn cấp thì kế hoạch báo rõ; đặt đủ máy chưa được
coi là dây chuyền đã chạy.

```powershell
python E:\FactorioMayor\factorio_ai.py smelt-plan 60 --x 10 --y -28
python E:\FactorioMayor\factorio_ai.py smelt-build smelt-1
python E:\FactorioMayor\factorio_ai.py smelt-status smelt-1
```

`smelt-plan` tự tìm chỗ nếu không truyền `--x/--y`; `--input-x/--input-y` chỉ vị
trí belt cấp liệu. `smelt-build` kiểm tra lại công nghệ, vị trí và vật tư rồi mới
xây, trừ vật tư thật có receipt và xuất blueprint; site đã đổi hoặc thiếu vật tư
thì từ chối trước khi đặt gì. `smelt-status` đọc audit sau khi chạy ổn định (khoảng
30 giây khởi động + 60 giây đo trong game): sản lượng so với mục tiêu và trạng thái từng lò.

- `snapshot --tiles` mặc định liệt kê mọi ô mà offshore pump hút được, suy ra từ
  `LuaTilePrototype.fluid` lúc chạy nên không sót biến thể nước của mod.
  Trả bin 8x8 cộng tối đa 200 ô lẻ, ô giáp bờ xếp trước.
- `place --dry-run` chạy khô đúng cổng mà `place` dùng: vị trí, item, công nghệ, kho.
  Trả `blockers` và `would_build`. Không xây, không trừ item.
- `spec recipe` trả nguyên liệu (kèm số đang có), sản phẩm, và khi recipe bị khoá thì
  nêu tên công nghệ mở nó.
- `spec` đọc từng prototype từ map đang chạy: tốc độ đào/chế tạo/băng chuyền,
  thời gian đào, năng lượng, nhiên liệu, kích thước và recipe. Dùng các số này
  làm đầu vào cho `factorio_model.py`, không coi số trong test là hằng số game.
- `audit` đọc thống kê sản lượng của cả force trên surface, rồi có thể so với
  `--expected-per-second`. Nếu có nhiều dây chuyền cùng sản xuất một món, số
  tổng này không thể quy riêng cho một dây chuyền.
- `set-recipe` chỉ cài recipe đã mở khóa, đúng category, cho máy lắp ráp chưa
  có recipe và rỗng; gọi lại cùng recipe là no-op. Không tự đổi recipe trên
  máy đang hoạt động để tránh làm xáo trộn nguyên liệu.
- `research` đọc nghiên cứu hiện tại; `--start` bắt đầu một công nghệ có thể
  nghiên cứu mà không ghi đè nghiên cứu khác đang chạy.
- `insert` chuyển đúng vật phẩm thật từ treasury vào đầu vào Lab, máy lắp ráp
  hoặc kho đạn của gun turret; kiểm tra nguồn, loại item và sức chứa, hoàn vật
  phẩm nếu chèn thất bại.
  `snapshot` hiển thị `input` và recipe của Lab/máy lắp ráp; kho đạn turret
  hiện trong `output` của entity.
- `collect` lấy vật phẩm thật từ rương hoặc kho đầu ra của lò/máy lắp ráp về
  túi nhân vật; không lấy từ kho đầu vào, không sinh vật phẩm.

> **Bẫy triển khai:** game nạp mod từ `%APPDATA%\Factorio\mods\factorio-ai-bridge_0.1.0\`,
> đó là BẢN SAO chứ không phải junction. Sửa `control.lua` trong repo xong phải chép
> sang đó và đối chiếu md5, rồi load lại save thì code mới chạy.

MCP stdio có 3 tool `observe`, `achieve`, `report`; xem [MCP.md](MCP.md).
Các lệnh chi tiết vẫn có trong CLI để chẩn đoán.

`snapshot` gom mỏ theo ô 8x8 để gói UDP nhỏ, giới hạn bán kính 32 và trả tối
đa 64 công trình mỗi trang. Dùng `entities_next_offset` làm `--offset` cho trang
tiếp theo; `entities_total` là tổng trong vùng.

`brief` trả một gói ngắn cho vùng vuông tâm ±64 ô: số công trình theo tên,
máy thiếu điện/nhiên liệu/nguyên liệu và tối đa 20 kẻ địch gần tâm nhất. Đây là
quan sát chỉ đọc, không tự suy ra địch đang di chuyển hay tấn công. `survey.py`
tự đọc mọi trang snapshot và in bản tóm tắt; thêm `--details` khi cần từng entity.

`index` quét toàn bộ chunk đã tạo và ghi lại từng vùng tài nguyên 32×32 ô vào
storage của save. `ore-marks` đọc danh sách đã ghi (lọc `--name`, phân trang
`--offset`/`--limit`); ô tài nguyên cạn vẫn còn dấu `depleted`. Dấu chỉ được
lưu lâu dài khi game được save. Đây là dấu cho agent đọc qua bridge, không phải
chart tag hiện trên bản đồ Factorio.
