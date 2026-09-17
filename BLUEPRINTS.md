# Blueprint import cho map mới

Trạng thái: đã có lệnh `blueprint-export` và `blueprint-import` (xây trực tiếp bằng vật tư thật hoặc đặt ghost với `--ghosts`), nhưng chưa nghiệm thu live; chưa có blueprint string từ map mới.

Đầu ra cần bàn giao là **blueprint string nhập được trực tiếp vào Factorio**, xây dần trong quá trình chơi. Mỗi blueprint dùng tọa độ tương đối và có thể xoay/đặt lại trên map mới. Bridge đọc map, spec và recipe để chọn chỗ đặt; không mang tọa độ, kho, mỏ hay sản lượng của save cũ.

## Quy trình tạo và nghiệm thu blueprint

1. Thiết kế một module nhỏ ngay khi dây chuyền tương ứng chạy ổn định, trước khi nhân rộng hoặc bước sang tech tiếp theo.
2. Chọn cụm entity đã đo chạy đúng trong game, dùng `blueprint-export` để chụp vùng ra string. Không coi bản phác thảo Markdown là blueprint hoàn tất.
3. Dùng `blueprint-import` tại một vùng trống để kiểm tra nó tạo đúng ghost, hướng, recipe và kết nối. Ghi công nghệ, vật tư, đầu vào/đầu ra và tốc độ đã đo kèm string.
4. Dùng lại blueprint ở vị trí khác sau khi probe địa hình và kiểm tra nguồn vật tư thật. Blueprint chỉ lưu bố cục; bridge vẫn phải trừ item thật khi xây.
5. Cập nhật blueprint khi một lần dùng lại phát hiện lỗi; giữ bản đã nghiệm thu để tránh lặp lại việc suy từng máy bằng token.

## Giao kèo chung

Mỗi module phải khai báo:

- **Đầu vào:** item/fluid/điện cần có, nguồn và tốc độ yêu cầu.
- **Đầu ra:** item/fluid, hướng và tốc độ dự đoán.
- **Vật tư xây:** lấy từ inventory hoặc storage thật; đủ trước khi bắt đầu.
- **Vị trí:** footprint tương đối, cổng nối, hướng có thể xoay; không đè mỏ, nước hoặc lối mở rộng.
- **Nghiệm thu:** dự đoán bằng số trước khi xây, probe, xây có receipt, đo sản lượng và trạng thái sau khi chạy ổn định.

Một module chỉ được coi là hoạt động khi đầu vào đi vào, đầu ra đi ra và sản lượng đo được đạt ngưỡng đã ghi trong kế hoạch. Buffer có sẵn không được tính thành sản lượng của module.

## 1. Khai thác quặng

**Đầu vào:** mỏ phù hợp, máy khoan, điện hoặc nhiên liệu, belt/consumer ở ô output.

**Đầu ra:** quặng lên một belt hướng tới dàn nung.

**Thiết kế:** khảo sát biên mỏ, đặt máy khoan phủ tài nguyên mà không chặn chỗ cho máy tiếp theo. Probe từng máy và ô output. Với burner drill, thiết kế nhánh nhiên liệu vật lý; dùng `autofuel` chỉ trong bước khởi động có receipt.

**Nghiệm thu:** toàn bộ máy dự kiến hoạt động, quặng có mặt trên belt nhận, không có item kẹt trên đất; tốc độ quặng đo được so với tốc độ tính từ spec.

## 2. Nung sắt/đồng

**Đầu vào:** quặng, nhiên liệu hoặc điện, vật tư dàn nung.

**Đầu ra:** plate lên belt riêng, không lẫn quặng/than.

**Thiết kế:** tính tổng tốc độ mỏ và tổng sức nung từ recipe trước khi chọn số lò. Cấp nguyên liệu trên hai làn belt nếu phù hợp; kiểm tra từng transport-line. Đặt inserter nạp/xả và cột điện theo pickup/drop và vùng cấp điện thật, không suy từ hình nhìn.

**Nghiệm thu:** mỗi lò được cấp đúng nguyên liệu, sản phẩm vào belt đầu ra, không có lò đứng lâu vì thiếu nhiên liệu/đầu ra đầy. So sánh plate/phút thực tế với dự đoán, rồi ghi nút thắt nếu lệch.

## 3. Điện hơi nước

**Đầu vào:** bờ nước có tile hút được, coal thật, offshore pump, boiler, steam engine, cột điện.

**Đầu ra:** điện vào mạng cần cấp.

**Thiết kế:** tìm bờ bằng thuộc tính fluid của tile; probe máy bơm và các cổng fluid. Dùng cặp 1 boiler : 2 steam engine làm cấu hình khởi đầu đã đo, nhưng kiểm tra lại spec và nhu cầu điện của map mới. Bố trí tuyến coal vật lý tới boiler.

**Nghiệm thu:** pump đưa nước, boiler có fuel và tạo steam, engine nối mạng và phát điện khi có tải; công suất khả dụng lớn hơn nhu cầu dự đoán.

## 4. Main bus và nhánh sản xuất

**Đầu vào:** plate từ dàn nung, sản phẩm trung gian từ các module khác.

**Đầu ra:** các làn vật tư riêng có cổng rẽ cho science và mall.

**Thiết kế:** chọn hành lang sau khi biết địa hình, mỏ và vùng mở rộng. Ghi rõ hướng dòng, item từng belt và khoảng trống cho rẽ nhánh. Mỗi nhánh mới phải được tính mức tiêu thụ để không rút cạn nguồn phía trước.

**Nghiệm thu:** không lẫn item trên các belt, đầu xa vẫn nhận vật tư khi những nhánh đã bật cùng chạy; đo sản xuất và tiêu thụ để tìm chỗ thiếu.

## Cách áp dụng cho map mới

1. Snapshot mỏ, nước, vật cản, địch và inventory; đọc công nghệ/recipe/spec đang có.
2. Chọn mục tiêu sản lượng đầu tiên, tính số máy và vật tư cần.
3. Đặt module bằng tọa độ tương đối vào một vùng thật; xoay/nắn các cổng nối theo địa hình.
4. Probe toàn bộ footprint và đường cấp liệu. Ghi số dự đoán trước khi tiêu vật tư.
5. Xây từ nguồn tới đầu ra, lấy receipt sau từng nhóm có thể kiểm chứng; cuối cùng audit theo ngưỡng.

Các mục 1–4 là danh sách module cần biến thành blueprint string trong quá trình chơi, không phải blueprint đã xuất. Ưu tiên hoàn tất và thử nhập lại từng string trước giai đoạn tech xanh để việc scale về sau chỉ còn chọn module, kiểm tra vị trí và cấp đủ vật tư.
