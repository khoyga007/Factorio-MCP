# Factorio AI — Field Notes

Các quy tắc dưới đây được rút từ những lần xây và đo thực tế trong Factorio 2.0.77 với Space Age. Chúng là điểm khởi đầu cho map mới; vị trí, tài nguyên, công nghệ đã mở và mod đang bật phải được quan sát lại trên chính map đó.

## Phân vai và tài nguyên

1. Người chơi cung cấp nguyên liệu thô ban đầu; AI chế tạo, bố trí và xây automation bằng bridge. AI được xây tại bất kỳ vị trí hợp lệ nào, không cần mô phỏng bước đi hoặc tầm với của nhân vật.
2. Không spawn item hoặc tài nguyên miễn phí. Mọi lần xây, craft và nạp nhiên liệu phải dùng item thật từ inventory nhân vật hoặc storage thuộc phe người chơi, kể cả khi ở xa. Thiếu item thì báo người chơi khai thác thêm.
3. Mỗi hành động chuyển item phải ghi nguồn, đích, số lượng và receipt trước–sau. Nếu hành động thất bại sau khi trừ item, phải hoàn trả đủ.
4. `autofuel` chỉ là cách khởi động tạm thời: lấy nhiên liệu thật từ storage, chỉ nạp khi burner hết cả fuel stack lẫn năng lượng đang cháy. Khi một nhánh đã có logistics nhiên liệu vật lý và được xác nhận hoạt động, tắt fallback cho nhánh đó.

## Xây dựng và kiểm chứng

5. Trước mỗi lệnh xây, kiểm tra công nghệ, vị trí, surface, force, va chạm và item cần dùng. Thứ tự transaction: kiểm tra công nghệ → kiểm tra vị trí → kiểm tra item → trừ item → tạo entity; tạo thất bại thì hoàn item.
6. `can_place_entity` phải được gọi ở đúng vị trí dự định. Preflight các entity lớn trước khi đặt cả chuỗi vì một ô không đặt được có thể buộc đổi bố cục.
7. Mỗi action thay đổi thế giới cần nonce idempotent để retry UDP không xây hoặc trừ item hai lần. Bridge chỉ nhận action trong whitelist, không nhận lệnh Lua tùy ý.
8. Snapshot phải giới hạn vùng và kích thước. Đo trạng thái, inventory và luồng vật phẩm trước–sau; không coi entity đã đặt là bằng chứng nó đang sản xuất.
9. Với cơ chế game chưa hiểu, thử một thay đổi nhỏ và đo receipt trước–sau. Khi cơ chế đã được xác nhận, có thể mở rộng và tối ưu theo tính toán.
10. Tọa độ, crash-site, mỏ, nước, vật cản và công trình không được mang từ map này sang map khác. Snapshot map mới trước khi quy hoạch và trước khi đặt entity đầu tiên.

## Bridge và API

11. Lua UDP chỉ xử lý lệnh khi map/scenario đang active; mở game ở menu chưa đủ. Trong GUI single-player đã thử nghiệm, `helpers.recv_udp()` nhận packet, còn `helpers.recv_udp(0)` làm lệnh timeout dù socket mở.
12. Không dựa vào tên nhân vật để xác định kho bootstrap: player có thể có index hợp lệ nhưng tên rỗng. Nếu không có container ban đầu, inventory nhân vật là kho hữu hạn hợp lệ để xây rương đầu tiên.
13. Không giả định mọi entity có `unit_number` đều tìm lại được bằng `game.get_entity_by_unit_number`; đã gặp ngoại lệ với crash-site spaceship.
14. Nếu mod được cài bằng bản sao trong thư mục mods, sửa file ở repo không tự cập nhật bản game đang chạy. Đối chiếu bản được game nạp sau khi triển khai thay đổi bridge.
15. Với tile nước, dùng `LuaTilePrototype.fluid` để xác định nơi offshore pump hút được; tránh hardcode tên tile vì mod có thể thêm biến thể nước.
16. Receipt trong snapshot có thể là lịch sử. Đối chiếu tick của receipt với tick hiện tại và đọc cờ trạng thái như `autofuel.enabled` trước khi kết luận hệ thống đang chạy.

## Khai thác, nhiên liệu và vận chuyển

17. Đặt burner mining drill không tự nạp nhiên liệu. Xây và nạp fuel là hai transaction riêng; kiểm tra burner inventory và status sau khi nạp.
18. Burner mining drill nhả sản phẩm ở ô output, có thể trực tiếp lên belt đặt đúng ô. `get_output_inventory()` không phải bằng chứng về lượng quặng đã khai thác; kiểm tra belt, container nhận hàng, item trên đất và lượng tài nguyên còn lại.
19. Ô output cần storage hoặc consumer nhận vật phẩm. Nếu sản phẩm rơi xuống đất và ô đầy, máy có thể ngừng xuất hàng.
20. Không trộn wood với coal khi burner còn loại fuel cũ hoặc còn năng lượng đang cháy; đợi hết chu kỳ hoặc cấp fuel theo một luồng nhất quán.
21. Burner inserter có thể trượt khi gắp từ belt thưa chạy nhanh. Cấp nhiên liệu từ container hoặc nhánh belt ngõ cụt được nén; một inserter có thể nạp fuel cho burner inserter khác.
22. Có thể tự cấp coal cho cụm khai thác bằng output của drill, một nhánh belt ngõ cụt và inserter trả coal về drill; phần coal dư đi tiếp vào trục chính. Kiểm tra buffer và sản lượng thực trước khi tắt `autofuel`.

## Hướng, làn belt và điện

23. Kiểm tra `pickup_position` và `drop_position` của inserter, không suy hai vị trí chỉ từ tên hướng. Trong layout đã đo, `direction=west` gắp phía Tây và thả phía Đông.
24. Tọa độ Y tăng là hướng south. Khi đặt belt north/south, kiểm tra dấu của chênh lệch Y và xác nhận luồng trên transport-line.
25. Inserter thả vuông góc vào belt có thể chỉ chiếm làn xa, khiến item khác bị kẹt dù làn còn lại trống. Muốn chia hai item lên hai làn, dùng side-load cho một item và kiểm tra từng transport-line sau khi chạy.
26. Tầm nối dây của cột điện khác vùng cấp điện. Với small electric pole đã đo, wire reach là 7,5 ô còn supply area là hình vuông 5×5 ô; kiểm tra entity ở mép vùng phủ bằng trạng thái điện thực tế.

## Công suất và bố cục

27. Tính công suất theo recipe và tốc độ máy, rồi so với mức tiêu thụ của các nhánh. Đo sản lượng thực và trạng thái `waiting_for_space_in_destination` hoặc thiếu nguyên liệu trước khi mở rộng.
28. Boiler và steam engine có thể nối trực tiếp; cấu hình 1 boiler : 2 steam engine đã vận hành ổn định trong bản game được thử. Kiểm tra cổng fluid, fuel và mạng điện sau khi đặt.

## Lò nung và slot nguyên liệu

29. Lò nung (furnace) không có `assembling_machine_input`; `insert` mặc định route lò vào slot fuel. Nạp quặng vào slot nguyên liệu phải dùng `insert <ore> <n> <x> <y> --source`, route qua `defines.inventory.furnace_source`. Đã kiểm chứng trên map thật (build `2026-09-17-furnace-source`): 5 iron-ore `--source` + 5 coal → 5 iron-plate collect về.
30. Với burner drill không có consumer ở output, một item quặng/than có thể rơi xuống đất rồi máy chuyển sang `waiting_for_space_in_destination`. Thu item đó mới cho máy xuất tiếp; đừng giả định nó tự chất thành một chồng lớn trên đất.
31. Burner drill và stone furnace đều 2×2. Đặt tâm lò cách tâm drill đúng 2 ô theo hướng nhả có thể nạp quặng trực tiếp, không cần belt/inserter. Phải cấp nhiên liệu thật riêng cho cả hai và đo plate trong output lò trước khi coi dây chuyền hoạt động.
32. Trước khi quy hoạch cặp máy mới cho cùng mục tiêu, tìm cặp drill→furnace đã có trên đúng loại quặng. Cặp có sẵn mà thiếu fuel cần được nạp lại từ kho thật và đo tiếp; thiếu item xây trong túi không có nghĩa là phải xây thêm cặp mới.

Những cơ chế chưa có receipt thực tế cần được kiểm chứng riêng trước khi dùng làm quy tắc.
