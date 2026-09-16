# Factorio AI — Field Notes

Ngày ghi nhận: 2026-09-15 — đính chính 2026-09-16 theo phán quyết của maintainer  
Trạng thái: **Đã qua Discovery — luật cốt lõi đã nắm, được triển khai và tối ưu
theo tính toán**

## Phương pháp discovery

Phân vai đã chốt với maintainer:

- maintainer khai thác và cung cấp nguyên liệu thô ban đầu.
- AI chịu trách nhiệm chế tạo, bố trí và xây automation bằng bridge.
- Mọi bước của AI vẫn phải tiêu tài nguyên thật, tuân recipe/công nghệ và có
  receipt trước–sau; phân vai này không cho phép spawn item hoặc bỏ qua logistics.
- AI được lấy nhiên liệu thật từ bất kỳ storage thuộc phe người chơi để tự nạp
  máy, không giới hạn khoảng cách; mỗi lượt phải ghi source/target/count và tuyệt
  đối không spawn fuel.
- `autofuel` chỉ là bootstrap/fallback khi chưa có logistics nhiên liệu vật lý.
  Mục tiêu bắt buộc vẫn là tự động hóa khai thác, vận chuyển và nạp fuel bằng
  entity trong game; khi chuỗi đó được xác nhận, phải tắt fallback tương ứng.

Được làm:

- Đọc tài liệu API đi kèm bản game và log hiện tại.
- Viết prototype trong `E:\FactorioMayor`.
- Kiểm tra Python, Lua syntax và tạo map thử với `write-data` tách biệt.
- Gửi lệnh vào map đang chơi và xây thật với tài nguyên hữu hạn.
- Mỗi lượt chỉ thử một thay đổi nhỏ; đo snapshot/inventory trước và sau.
- Ghi rõ quan sát, suy luận và điều chưa kiểm chứng.

Không được làm:

- Không thêm tính năng chỉ vì đoán rằng sau này sẽ cần.
- Không tạo vật phẩm miễn phí, bật cheat hoặc bỏ qua kho xây dựng. Đây là ranh
  giới CỨNG duy nhất của phân vai này.
- Thiếu tài nguyên để khởi động automation thì báo người chơi khai thác đủ rồi
  mới xây; tuyệt đối không tự bơm item để đi tiếp.
- Không xây hàng loạt khi một lệnh nhỏ chưa có receipt trước/sau.
- Không sửa trực tiếp file save để làm thí nghiệm trông như thành công.

Mục tiêu hiện tại không phải hoàn thiện tool. Mục tiêu là để prototype va vào
luật thật của Factorio, rồi biến các va chạm đó thành quy tắc có bằng chứng.

## Quan sát đã xác nhận

### Môi trường

- Factorio đang chạy bản `2.0.77`, build `84539`, Win64, có Space Age.
- Executable: `D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe`.
- Write-data: `C:\Users\user\AppData\Roaming\Factorio`.
- API docs cục bộ cũng mang phiên bản `2.0.77`.

### Cầu nối

- Factorio 2.0.77 có cờ chính thức `--enable-lua-udp PORT`.
- Runtime API có `helpers.recv_udp`, `helpers.send_udp` và sự kiện
  `on_udp_packet_received` với `payload`, `source_port`, `player_index`.
- Vì UDP chỉ nhắm localhost, nó phù hợp hơn RCON cho prototype single-player:
  không cần dựng dedicated server và không cần mật khẩu RCON.
- Lần khởi động hiện tại có đối số `--enable-lua-udp 34198`; log ghi nhận
  `factorio-ai-bridge 0.1.0` và checksum của `control.lua`.
- Log xác nhận UDP socket mở tại `127.0.0.1:34198` sau khi map setup xong và
  đóng khi active scenario bị xóa.
- Thử `ping` khi game đang ở menu trả Windows `10054`; không có lệnh xây nào
  được thực thi.
- Thử `ping` khi map active với prototype gọi `helpers.recv_udp(0)` bị timeout:
  socket hệ điều hành vẫn mở nhưng mod không phát response.
- Sau khi chỉ đổi thành `helpers.recv_udp()`, cùng lệnh `ping` thành công ở
  tick 3962. Đây là A/B xác nhận semantics khác nhau trong GUI single-player.
- Snapshot quanh crash-site xác nhận một mỏ sắt phía đông, trải qua các bin
  8x8 từ khoảng `(8,8)` đến `(24,24)`.
- `crash-site-spaceship` tại `(-5,-6)` là container và còn 8
  `firearm-magazine`, nhưng không có item xây dựng.
- Sau restart, map mới đặt người chơi khoảng `(-70,-3)` và không có container
  trong dải đã quét từ X=-120 đến X=32. Mỏ sắt, than và đá cũng nằm ở tọa độ
  khác map trước.

### API xây dựng và tài nguyên

- `LuaSurface.can_place_entity` kiểm tra va chạm với địa hình/entity.
- `LuaSurface.create_entity` có thể tạo entity và phát sự kiện build bằng
  `raise_built`.
- `LuaEntityPrototype.items_to_place_this` trả item và số lượng dùng để đặt
  entity.
- `LuaInventory.get_item_count`, `remove`, `insert` đủ để kiểm tra, trừ và
  hoàn lại vật phẩm trong rương.
- `LuaForce.recipes` cho phép chặn công trình có recipe chưa mở.

### Prototype sandbox

- `python -m unittest -v`: 1/1 test qua; xác nhận retry UDP giữ nguyên nonce
  và bỏ qua response không cùng nonce.
- `python -m py_compile`: qua.
- `luac -p control.lua`: qua.
- Factorio tạo thành công một map thử dùng write-data riêng; log có checksum
  cho `__factorio-ai-bridge__/control.lua`.

### Receipt thực chiến đầu tiên

- Snapshot trước xây tại tick 3039: treasury fallback là inventory người chơi,
  gồm 1 `burner-mining-drill`, 1 `stone-furnace`, 8 `firearm-magazine`, 1
  `wood`.
- Mỏ sắt có bin 8x8 kín 64/64 resource tile quanh `(0..7,-32..-25)`.
- Lệnh đặt `burner-mining-drill` tại `(4,-28)`, hướng nam, thành công; entity
  nhận `unit_number=54`.
- Receipt build: đã tiêu đúng 1 `burner-mining-drill`, số còn lại là 0 và
  `treasury_kind=player`.
- Snapshot hậu kiểm tại tick 4571 thấy đúng máy đào ở `(4,-28)`, hướng 8; kho
  chỉ còn lò đá, 8 băng đạn và 1 gỗ.
- Chưa xác nhận máy đào đang hoạt động. Lệnh place chỉ đặt entity, không chuyển
  gỗ/nhiên liệu từ treasury vào burner inventory.

### Receipt nạp nhiên liệu và khai thác đầu tiên

- Sau restart sạch, snapshot mới xác nhận máy đào vừa đặt có `fuel={}` và mã
  trạng thái 53; việc đặt entity tự nó không nạp nhiên liệu.
- Lệnh `fuel coal 1 4 -28` tiêu đúng 1 coal từ inventory người chơi (20 → 19),
  chuyển máy đào sang `status_name=working` và giữ nguyên `unit_number=45`.
- Sau khoảng 5 giây, tổng quặng sắt trong bin `(0,-32)` giảm 49.595 → 49.594,
  xác nhận máy thực sự khai thác chứ không chỉ đổi trạng thái.
- `get_output_inventory()` của burner mining drill không đại diện cho sản phẩm
  rơi trên đất: receipt ngay sau nạp đã trả chính coal trong trường output.
  Snapshot phải đo `item-entity` ở mặt đất cho kiểu máy đào này.
- maintainer đặt hòm gỗ tại `(4.5,-26.5)`, đúng đầu output phía nam của máy đào
  `(4,-28)`. Trước khi nạp fuel, hòm rỗng và máy báo `no_fuel`.
- Sau khi bridge chuyển đúng 1 coal (treasury 22 → 21) và chờ khoảng 8 giây,
  máy báo `working`, bin sắt giảm 49.595 → 49.593, hòm chứa đúng 2 `iron-ore`
  và `ground_items={}`. Đây là receipt xác nhận storage đầu output nhận đủ sản phẩm.

### Receipt automation luyện sắt đầu tiên

- Bridge dùng hand-crafting thật để chế tạo 2 `iron-gear-wheel`, sau đó 2
  `burner-inserter`: 14 iron plate ban đầu còn 8, đúng tổng chi phí 6 plate.
- Layout Bắc–Nam đầu tiên thất bại có kiểm soát: inserter thả ore tại
  `(4.5,-24.30078125)` ngoài collision box của lò nên báo
  `waiting_for_space_in_destination`; lò vẫn `no_ingredients`.
- `LuaEntity.mine` không nhận main inventory của player trực tiếp. Bridge dùng
  script inventory tạm, chuyển item thu hồi về treasury và spill phần không vừa;
  lượt sửa này thu hồi đủ entity, fuel và ore, không spill.
- Layout chạy được theo trục Tây→Đông: hòm ore `(4.5,-26.5)` → burner inserter
  `(5.5,-26.5)` hướng `west` → stone furnace `(7,-27)` → burner inserter
  `(8.5,-26.5)` hướng `west` → hòm plate `(9.5,-26.5)`.
- Sau 20 giây với mỗi máy nhận 1 wood, hòm ore giảm 103 → 94, furnace và hai
  inserter đều `working`, hòm thành phẩm có 5 `iron-plate`.

### Receipt nhánh khai thác than đầu tiên

- AI thu 20 iron plate từ hòm thành phẩm, dùng hand-crafting thật để tạo 1
  stone furnace, 3 iron gear, 1 burner mining drill và 1 wooden chest; sau craft
  còn 19 iron plate.
- Quét khu vực tìm thấy mỏ coal lớn quanh `(-56,-72)` và `(-48,-72)`; drill
  tại `(-52,-72)` hướng nam đặt thành công, hòm output tại `(-51.5,-70.5)`.
- Sau 12 giây với 5 wood, hòm nhận 3 coal; sau lượt đo kế tiếp hòm đã có 8 coal,
  drill vẫn `working` và không có item rơi trên đất.
- Lấy 3 coal về inventory thành công, nhưng nạp coal vào các burner đang dùng
  wood trả `fuel-not-accepted`. Fuel inventory không nhận trộn loại nhiên liệu
  khi stack/chu kỳ wood hiện tại còn chiếm burner.

### Receipt băng chuyền đầu tiên

- AI craft 4 transport belt (2 lượt recipe) và thêm 1 burner inserter, sau đó
  thu hồi đoạn lò compact cũ về treasury, gồm cả plate và fuel, không spill.
- Layout mới: hòm ore `(4.5,-26.5)` → inserter `(5.5,-26.5)` hướng west →
  4 belt hướng east tại X=`6.5..9.5` → inserter `(10.5,-26.5)` hướng west →
  furnace `(12,-27)` → inserter `(13.5,-26.5)` hướng west → hòm plate
  `(14.5,-26.5)`.
- Sau 20 giây, cả 4 belt, 3 inserter và furnace đều `working`; hòm đầu ra có
  6 iron plate và không có item rơi đất. Đây là receipt end-to-end đầu tiên có belt.

### Receipt autofuel fallback đầu tiên

- `autofuel` chạy mỗi 300 tick và chỉ xét burner đã hết stack lẫn năng lượng
  đang cháy; nguồn là container phe người chơi trên cùng surface.
- Tại tick 106.200, hệ thống lấy đúng 1 coal từ hòm than `unit=399` tại
  `(-51.5,-70.5)` và nạp cho burner inserter `unit=578` tại `(10.5,-26.5)`.
- Snapshot sau đó thấy hòm than còn 64 coal, target đang `working`; các burner
  còn wood/coal hoặc còn năng lượng cháy không bị nạp thêm.
- Đây chỉ là fallback bootstrap. Khi logistics nhiên liệu vật lý hoạt động,
  phải tắt bằng `autofuel off`.

### Receipt tuyến coal vật lý đầu tiên

- AI thu 80 plate từ hòm thành phẩm, hand-craft 102 belt, 2 burner inserter và
  1 wooden chest. Tuyến chữ L dài 92 belt đặt thành công 92/92, không vật cản:
  từ hòm coal `(-51.5,-70.5)` đi ngang tới `(2.5,-70.5)`, rồi dọc về buffer
  `(2.5,-29.5)`.
- Lần đầu đoạn dọc đặt `north` trong khi tọa độ Y tăng từ -70.5 lên -31.5;
  coal dồn 4 viên tại corner. Đo transport-line xác nhận đoạn ngang có coal,
  đoạn sau corner rỗng. Thu hồi 40 belt không spill và đặt lại `south` sửa lỗi.
- Sau sửa, midpoint `(2.5,-50.5)` có 4 coal và fuel buffer nhận 51 coal; inserter
  nguồn/đích đều `working`. Đây là receipt vận chuyển vật lý end-to-end.
- Nhánh local 7 belt từ buffer nhập coal vào belt ore. Ba hướng Y được sửa theo
  transport-line: hai belt đầu `south`, belt nhập từ Y=-25.5 xuống -26.5 dùng
  `north`. Snapshot thấy belt chính chứa cả coal và iron ore.
- Fuel logistics vật lý hiện cấp được buffer và lane vào furnace. Máy đào sắt
  cùng một số burner chưa có nhánh nạp riêng, nên autofuel vẫn là fallback cho
  các target chưa nối vật lý; chưa được tắt toàn cục.

## Quy tắc gameplay rút ra

1. AI được xây trực tiếp ở bất kỳ vị trí hợp lệ; không mô phỏng đi bộ hoặc tầm
   với của nhân vật.
2. Tài nguyên vẫn hữu hạn. Mọi công trình phải trừ đúng item thật từ một kho có
   thật: **rương kho xây dựng AI** đã chỉ định, hoặc inventory người chơi ở bước
   bootstrap (luật 16). Không tồn tại đường nào khác sinh ra item.
3. **Điều cấm duy nhất (maintainer đính chính 2026-09-16): AI không được spawn item
   hay tài nguyên miễn phí dưới bất kỳ dạng cheat nào.** Ngoài điều đó mọi thao
   tác đều hợp lệ — AI được lấy item thật từ bất kỳ storage nào thuộc phe người
   chơi, kể cả inventory nhân vật, không giới hạn khoảng cách, miễn ghi đủ
   receipt `source/target/count`. Thiếu tài nguyên thì báo người chơi khai thác
   thêm, không tự bơm. (Bản cũ cấm lấy từ inventory nhân vật và cấm quét rương
   nhà máy — đã bị bãi, nó chỏi luật 16, mục phương pháp và chính hành vi của
   `autofuel` trong `control.lua`.)
4. Một lệnh xây phải theo thứ tự nguyên tử:
   `kiểm tra công nghệ → kiểm tra vị trí → kiểm tra item → trừ item → tạo`.
   Nếu tạo thất bại sau khi trừ, phải hoàn lại đủ item.
5. Không bỏ qua va chạm, mặt nước, surface, force hoặc khóa công nghệ.
6. Mọi lệnh làm thay đổi thế giới phải có nonce idempotent để retry UDP không
   xây/trừ tiền hai lần.
7. Bridge chỉ nhận action có whitelist; tuyệt đối không mở lệnh chạy Lua tùy ý.
8. Snapshot phải có giới hạn vùng và kích thước. Prototype hiện gom tài nguyên
   theo ô 8x8, bán kính tối đa 32 và tối đa 500 entity.
9. Quan sát trước, hành động sau. Không được suy ra rằng một entity có thể đặt
   chỉ từ tên prototype; phải dùng `can_place_entity` ở đúng vị trí.
10. Khi chạm một cơ chế game CHƯA nắm luật, lệnh xây đầu tiên chỉ đặt một entity
    rẻ ở vị trí trống và phải đo inventory trước/sau. Đây là công cụ HỌC LUẬT,
    không phải trần vĩnh viễn: luật nào đã nắm rõ thì được triển khai và tối ưu ở
    quy mô theo tính toán (maintainer đính chính 2026-09-16).
11. Bridge Lua UDP chỉ hoạt động khi một map/scenario đang active. Game mở ở
    menu chưa đủ; client phải báo riêng trạng thái “chưa vào map”.
12. Trong GUI single-player, gọi `helpers.recv_udp()`; ép `for_player = 0`
    khiến socket vẫn mở nhưng packet không được mod xử lý.
13. Không được giả định mọi entity có `unit_number` đều tra lại được bằng
    `game.get_entity_by_unit_number`. Crash-site spaceship trả unit number nhưng
    lần tra kế tiếp thất bại; storage chính thức cho phép giữ trực tiếp tham
    chiếu `LuaObject` và đó là cách đang được A/B tiếp theo kiểm tra.
14. Bridge cần một cơ chế bootstrap kho: container khởi đầu có thể tồn tại
    nhưng chưa chắc chứa bất kỳ item xây dựng nào. Không được tự bơm item để
    vượt qua bước này.
15. Tọa độ, crash-site và phân bố mỏ không được tái sử dụng giữa các map. Mỗi
    phiên/map phải snapshot lại trước khi đặt bất kỳ entity nào.
16. Nếu map không có container ban đầu, inventory người chơi là kho bootstrap
    hữu hạn hợp lệ: AI được tiêu item thật ở đó để đặt rương đầu tiên, rồi mới
    chuyển sang kho chuyên dụng. Điều này bỏ tầm với nhưng không tạo tài nguyên.
17. `can_place_entity` cộng với bin tài nguyên đủ để đặt thành công máy đào trên
    mỏ; debit item và tạo entity có thể hoàn tất trong một transaction bridge.
18. Đặt một máy chạy nhiên liệu không đồng nghĩa máy hoạt động. Xây dựng và nạp
    nhiên liệu là hai hành động tài nguyên riêng; audit phải đọc status/burner
    inventory thay vì suy từ việc entity đã tồn tại.
19. Không dựa vào tên người chơi để định danh kho bootstrap: map thử trả
    `player_index=1` nhưng `name` là chuỗi rỗng.
20. Nạp nhiên liệu là một transaction riêng: kiểm tra đích nhận fuel, trừ item
    hữu hạn từ treasury, insert đủ hoặc rollback, rồi mới coi entity có thể chạy.
21. Với burner mining drill, sản phẩm nằm trên mặt đất tại output tile; không
    dùng `get_output_inventory()` làm bằng chứng sản lượng.
22. Đầu output của máy đào phải có storage/consumer nhận vật phẩm: hòm gỗ đúng ô
    output ở chuỗi đầu game, hoặc transport-belt ngay dưới chân output (luật 30
    đo được là nhả thẳng lên belt, bỏ hẳn hòm trung gian). Nếu không có nơi nhận,
    vật phẩm
    rơi xuống đất và khi ô bị chiếm đầy máy sẽ không thể tiếp tục xuất.
23. Với inserter, `direction=west` tạo pickup ở phía Tây và drop phía Đông;
    direction biểu diễn hướng thân/arm của entity, không được suy bằng tên hướng
    nếu chưa đo `pickup_position` và `drop_position`.
24. Trước khi đặt cả chuỗi, phải preflight entity lớn (như furnace) trước; một
    ô bị `can_place_entity` từ chối có thể buộc đổi toàn bộ trục logistics.
25. Không đổi trực tiếp từ wood sang coal khi burner còn wood hoặc còn chu kỳ
    đốt hiện tại; phải đợi loại fuel cũ cạn hoặc xây logistics tránh trộn fuel.
26. Với đoạn thẳng Tây→Đông, transport belt dùng `direction=east`; inserter ở
    hai đầu vẫn dùng `direction=west` để pickup phía Tây và drop phía Đông.
27. Autofuel không được top-up máy còn nhiên liệu; chỉ chuyển 1 item từ storage
    có thật khi fuel inventory rỗng và `remaining_burning_fuel <= 0`.
28. Trong tọa độ Factorio, đi từ Y âm lớn về gần 0 là hướng south; luôn kiểm tra
    dấu delta Y trước khi đặt belt north/south và xác nhận bằng transport-line.
29. Burner inserter di chuyển chậm (tốc độ quay ~128 deg/s); nếu than di chuyển trên
    băng chuyền đơn ở tốc độ tối đa (15 item/s) mà không bị nén, tay gắp có thể bị
    trượt chu kỳ gắp. Nguồn cấp than cho tay gắp nhiệt phải nằm trong container,
    hoặc trên nhánh belt ngõ cụt / bị nén (compressed).
30. Máy khoan khai thác (burner-mining-drill) nhả sản phẩm trực tiếp lên transport-belt
    ngay dưới chân output; không cần hòm trung gian và không cần inserter rút quặng,
    cắt giảm hoàn toàn một burner-inserter cần nuôi than.
31. Inserter có thể nạp nhiên liệu vào một burner-inserter khác; cho phép nuôi tay gắp
    rút sản phẩm không-phải-nhiên-liệu (như đĩa sắt từ lò) vĩnh cửu bằng một nhánh than rẽ.
32. Khép kín tự cấp than độc lập tại mỏ than: drill nhả vào rương output -> inserter A
    rút vào nhánh belt ngõ cụt -> inserter B gắp từ ngõ cụt vào drill. Khi drill đạt trần
    5 than, nhánh ngõ cụt dừng và inserter C chuyển toàn bộ than dư vào trục chính.
33. Nghiệm thu không fallback (agent 2026-09-16): Tắt hoàn toàn `autofuel off`; chuỗi
    nung sắt tự vận hành 100% logistics vật lý; đo đạc 25s đạt 6 đĩa sắt, receipt
    autofuel = 0, toàn bộ máy khoan than/sắt, lò và các tay gắp giữ buffer than ổn định.
34. Clean Rebuild (agent 2026-09-16): Thực thi chỉ thị Prototype-To-Clean-Rebuild của
    maintainer. San phẳng 28 thực thể prototype chắp vá; tái thiết dàn nung công nghiệp
    thẳng tắp: trục than Bắc-Nam đi thẳng vào trục ngang; quặng sắt nhả thẳng vào belt
    tạo dải đôi (quặng + than) thẳng tắp về phía Đông; 2 lò nung song song đối xứng
    gấp đôi sản lượng; mở rộng vô hạn về phía Đông. Đã kiểm toán live chạy hoàn hảo.
35. Khai thác quy mô (agent 2026-09-16): Mở rộng dãy máy khoan sắt thành 3 máy khoan
    song song thẳng hàng (#60, #863, #864) cùng nhả thẳng xuống trục cấp ngang;
    nâng sản lượng khai thác sắt lên gấp 3 lần (0.75 quặng/giây), đảm bảo dòng quặng
    dày đặc nuôi bão hòa đồng thời cả 2 lò nung hoạt động hết công suất.
36. North Fuel Spur (agent 2026-09-16): Giải quyết triệt để tiếp vận than vật lý cho dãy
    máy khoan mở rộng. Khi các máy khoan quặng xả sản phẩm về phía Nam, mặt Bắc của chúng
    là không gian lý tưởng cho dải tiếp vận than. Dùng 1 tay gắp tại điểm rẽ trục chính
    nhón than sang nhánh belt ngõ cụt chạy ngang ở Y=-30.5 phía sau lưng các máy khoan.
    Mỗi máy khoan được tiếp than bởi 1 tay gắp nhiệt hướng North (dir=0) gắp từ nhánh than
    đút vào lưng máy khoan. Vì nhánh than là ngõ cụt nén chặt, tay gắp nhiệt gắp chính xác
    100% không trượt chu kỳ tốc độ, tự dừng khi máy khoan đầy than, bảo toàn 100% dòng than
    trục chính tiếp tục đổ về nuôi cụm lò nung. Đã nghiệm thu độc lập: Drill #863 và #864
    được nạp đầy 34-46 than, tổng sản lượng đĩa sắt tích lũy vượt mốc 700 đĩa.
37. Unidirectional Streamline Refactor (agent 2026-09-16): Triệt tiêu hoàn toàn góc gãy khúc
    chữ Z do di chứng né tay gắp cũ. Trục than từ mỏ than chạy thẳng tắp ở X=2.5 xuống Y=-30.5
    rẽ đúng 1 góc 90 độ sang Đông. Dãy 3 máy khoan xếp thẳng hàng cách đều chuẩn module (X=4, 7, 10
    tại Y=-28.0), được nạp than đồng nhất 100% bằng 3 tay gắp ở lưng (Y=-29.5 dir=0). Trục quặng
    dưới chân (Y=-26.5) nhận quặng từ 3 drill và đón than đổ vào từ dải trên tại X=12.5 tạo thành
    băng chuyền hỗn hợp chuẩn mực cấp liệu cho dãy 2 lò nung thẳng hàng phía sau (X=14, 17).
    Toàn bộ bố cục vuông vức, đối xứng, dòng chảy 1 chiều tự nhiên, dọn sạch 100% phế tích cũ.
38. No-Bypass Refactor-First (maintainer decree 2026-09-16): Tuyệt đối không được né (bypass) những cấu
    trúc đã đặt bằng cách uốn lượn, bẻ cong hay vá víu đường đi. Nếu cấu trúc cũ vướng đường quy
    hoạch hoặc cản trở luồng trục chính, bắt buộc đập bỏ và refactor lại toàn bộ đoạn đó (tương tự
    như cách refactor code sạch trong lập trình: thấy code smell/vướng là refactor thẳng tay, cấm
    viết workaround/wrapper bọc ngoài). Di chứng gãy khúc chữ Z ở trục than X=1.5 là bài học đắt giá
    cho thói quen né tay gắp cũ thay vì dời vị trí tay gắp. Áp dụng toàn diện cho mọi bài toán
    quy hoạch tự động hoá.
39. PHẠM VI HAI SẮC LỆNH (maintainer đính chính 2026-09-16): cả Prototype-To-Clean-Rebuild
    (luật 34) lẫn No-Bypass Refactor-First (luật 38) áp dụng cho **công trình TRONG
    GAME**, không áp cho mã nguồn bridge. Hai sắc lệnh rút ra từ vụ trục than bị xây
    gãy khúc chữ Z; phép so sánh với refactor code chỉ là hình ảnh minh hoạ, không
    phải mệnh lệnh đập bỏ tool. Kiến trúc tool vẫn theo cổng Hardening bên dưới: chỉ
    sửa khi có lỗi hoặc giới hạn ĐÃ TÁI HIỆN, không sửa theo giả thuyết.
40. Throughput Balancing & Triple Smelter Scaling (agent 2026-09-16):
    - 1 burner drill sắt: 0.25 quặng/s -> 3 drill = 0.75 quặng/s.
    - 1 stone furnace nung sắt: 3.2s / đĩa -> tiêu thụ 0.3125 quặng/s.
    - 2 lò nung chỉ nuốt 0.625 quặng/s -> thiếu 0.125 quặng/s khiến Drill 3 bị nghẽn
      `waiting_for_space_in_destination`.
    - Mở rộng Lò 3 (Furnace 3) tại (20, -29) cùng tay gắp vào (20.5, -27.5 dir=south),
      tay gắp ra (20.5, -30.5 dir=south), rương 3 (20.5, -31.5) và kéo dài belt hỗn hợp đến X=21.5.
    - Nâng sức nuốt lên 0.9375 quặng/s, giải toả 100% công suất cho cả 3 máy khoan.
    - Nghiệm thu độc lập: 3/3 drill working, 3/3 furnace working, tổng đĩa sắt trong 3 rương đạt 1253 đĩa!
    - Đúc rút 2 bẫy thi công: (1) Inserter Direction Inversion (dir=south để pickup Nam drop Bắc);
      (2) Ground Item Collision: tay gắp nhả item xuống đất trống sẽ cản trở không cho đặt công trình,
      phải dùng `mine` với tên `item-on-ground` để dọn sạch trước khi đặt.

41. Mod nạp từ BẢN SAO, không phải từ repo (agent đo 2026-09-16). Game đọc
    `%APPDATA%\Factorio\mods\factorio-ai-bridge_0.1.0\control.lua`; thư mục đó là
    một bản sao riêng, KHÔNG phải junction tới `E:\FactorioMayor\...`. Trước khi vá
    hai file md5 giống hệt nhau (`9a27b54e...`), nên chưa có drift — nhưng sửa trong
    repo mà quên chép sang thì game chạy code cũ và không báo lỗi gì. Mọi lần sửa
    `control.lua` phải chép sang mods dir rồi đối chiếu md5.
42. Dò nước KHÔNG hardcode tên tile (agent 2026-09-16). `LuaTilePrototype.fluid` —
    doc 2.0.77 ghi "The fluid offshore pump produces on this tile, if any" — là dấu
    hiệu chính xác của ô mà offshore pump hút được. Dựng danh sách tên tile từ
    `prototypes.tile` lúc chạy, không viết cứng "water"/"deepwater". Map này đang bật
    **alien-biomes** (`mod-list.json`), mod đó thêm rất nhiều biến thể nước, nên danh
    sách viết cứng CHẮC CHẮN sót.
43. Nghi ngờ mốc thời gian của receipt trước khi đọc nó là hiện trạng. `snapshot` trả
    `autofuel.receipts` là LOG LỊCH SỬ, không phải hoạt động đang diễn ra: lúc đo tick
    là 487.966 mà receipt mới nhất ở tick 190.500. Đọc `autofuel.enabled` mới là trạng
    thái thật.
44. Chuẩn kiến trúc trạm điện nước (maintainer Ground Truth 2026-09-16):
    - Bờ nước thực tế: Hồ nước lớn bờ nam phẳng đẹp nằm ở `Y=41.5` (`alien-biomes`).
    - Máy bơm (Offshore pump #1427): Đặt tại mép nước `(10.5, 41.5)`, hướng `direction=8`
      (chân hút cắm xuống nước ở Nam, miệng xả hướng lên Bắc).
    - Dải cấp nước: Dãy 3 ống nước dọc tại `X=10.5` (`Y=40.5, 39.5, 38.5`) dẫn nước thẳng lên Bắc.
    - Lò hơi (Boiler #1428): Đặt tại `(11.0, 36.5)`, hướng `direction=4` (East).
      Kích thước 2x3 (rộng 2 ô X=10..12, cao 3 ô Y=35..38):
      + Cổng nước vào ở đáy Nam (`Y=37.5`) nối trực tiếp với ống nước `(10.5, 38.5)`.
      + Cổng nước thông ở đỉnh Bắc (`Y=35.5`) cho phép nối tiếp boiler tiếp theo.
      + Cổng hơi nước (Steam out) ở hông Đông (`X=12.0, Y=36.5`) xả hơi nước 100°C sang Đông.
      + Đã nạp 44 than, status `full_output` sinh hơi nước bão hoà.
    - Dải dẫn hơi nước: 3 đoạn ống chạy ngang ở cao độ `Y=36.5` (`X=12.5, 13.5, 14.5`) dẫn hơi nước sang Đông.
    - Động cơ hơi nước (Steam engine #1432): Đặt nằm ngang tại `(17.5, 36.5)`, hướng `direction=4` (East).
      Kích thước 5x3 (rộng 5 ô X=15..20, cao 3 ô Y=35..38):
      + Cổng nhận steam ở đầu Tây (`X=15.0, Y=36.5`) nối khít dải ống steam `Y=36.5`.
      + Cùng đồng trục tâm `Y=36.5` với dải ống dẫn steam, thẳng hàng tuyệt đối.
      + Status `not_plugged_in_electric_network` (đã nạp đầy hơi, chỉ cần cắm cột điện là phát tối đa 900 kW).

45. Tỉ lệ vàng 1 Boiler : 2 Steam Engine & Cắm trực tiếp không ống nối (agent 2026-09-16):
    - Thực thi Clean Rebuild & Human-Sample-As-Rule-Only Decree:
      + Dỡ bỏ toàn bộ 3 ống dẫn hơi thừa ở giữa (X=12.5, 13.5, 14.5).
      + Cắm Steam Engine 1 (#1438) trực tiếp vào hông Đông Boiler tại (14.5, 36.5) dir=4 (East). Khớp khít 100%, 0 ống nối.
      + Cắm nối tiếp Steam Engine 2 (#1439) tại (19.5, 36.5) dir=4 ngay sau đuôi Engine 1, chạy thẳng hàng trên trục Y=36.5.
      + Cắm cột điện nhỏ (#1440) tại (17.5, 34.5) phủ đồng thời cả 2 Steam Engine.
      + Nghiệm thu snapshot UDP: Boiler full_output (44 than), 2/2 Steam Engine `working` sinh điện bão hoà, nâng công suất trần lên 1.8 MW.
46. Nhân đôi trạm điện Hồ Nam 3.6 MW (Bước R1 - agent 2026-09-16):
    - Dựng dãy nhiệt điện thứ 2 song song tại `Y=33.5` gồm Boiler #2 `(11.0, 33.5)` ghép nối tiếp đường nước từ Boiler #1 + 2 Steam Engine #3 `(14.5, 33.5)` và #4 `(19.5, 33.5)`.
    - Lắp Splitter than tại `(8.0, 32.5)` chia đều than tự động cho cả 2 nồi hơi.
    - Nghiệm thu: 2 Boiler `working` (5 than/lò), 4 Steam Engine `working` sinh điện 3.6 MW ổn định vào lưới Nauvis.

47. Điện hóa mỏ sắt & triệt tiêu nhánh than rác (Bước R2 - agent 2026-09-16):
    - Đào bỏ 3 burner drill và toàn bộ nhánh belt than ruột thừa `Y=-30.5`.
    - Đặt 3 `electric-mining-drill` mới tại `(4.5, -28.5)`, `(7.5, -28.5)`, `(10.5, -28.5)` dir=south (tổng công suất 1.5 quặng/s, xả trực tiếp xuống belt quặng `Y=-26.5`).
    - Thay thế 6 burner inserter của dàn nung sắt bằng 6 `inserter` điện. Cả 3 lò đá nung đầy 100 đĩa sắt/lò, đạt chuẩn điện hóa sạch 100%.

48. Điện hóa & mở rộng mỏ đồng 84 ô lên phía Bắc (Bước R3 - agent 2026-09-16):
    - Kéo tuyến điện Nauvis 13 cột `small-electric-pole` vượt 84 tiles dọc từ mỏ sắt `(4.5, -25.5)` lên mỏ đồng `(-39.5, -95.5)`.
    - Đặt 2 `electric-mining-drill` tại `(-37.5, -100.5)` và `(-34.5, -100.5)` dir=south (1.0 quặng/s).
    - Dựng cụm 4 lò đá nung đồng (`stone-furnace`) tại X=-37.0 (`Y=-93, -90, -87, -84`) với tuyến cấp liệu Half-Belt (than từ X=-42.5 side-load vào quặng X=-34.5). 8 inserter điện nạp/xả đĩa đồng ra trục X=-40.5 về Main Bus (1.25 đĩa/s, gấp 5 lần prototype cũ).

49. Trục đôi Main Bus Sắt (X=22.5) & Đồng (X=23.5) và The Mall Tự Động Hóa (agent 2026-09-16):
    - Kéo dài Main Bus Trục Sắt (X=22.5) và Trục Đồng (X=23.5) độc lập song song xuống Y=4.5.
    - The Mall Giai đoạn 1 (Băng chuyền): Máy Bánh răng `(26.5, -20.5)` rút sắt từ X=22.5 qua long inserter -> nhả trực tiếp sang Máy Băng chuyền `(26.5, -16.5)` -> nhả vào Rương Sắt Buffer `(26.5, -13.5)`. Tích lũy 400+ băng chuyền tự động.
    - The Mall Giai đoạn 2 (Tay gắp điện): Dựng chuỗi 4 máy tại X=26.5 (Cáp Đồng `(26.5, -10.5)` -> Mạch Điện Xanh `(26.5, -6.5)` -> Bánh Răng `(26.5, -2.5)` -> Tay Gắp `(26.5, 1.5)`) kèm belt trung gian Mạch Xanh tại X=29.5 và Rương Sắt Buffer tại `(26.5, 4.5)`. Tự động tích lũy tay gắp điện vào rương. Xóa bỏ hoàn toàn nút thắt chế tạo thủ công bằng tay.

50. Siêu xưởng Red Science Công Nghiệp 36/phút & Lab Daisy-Chain (Bước R4 - agent 2026-09-16):
    - Đập bỏ toàn bộ prototype cũ theo sắc lệnh Prototype-To-Clean-Rebuild.
    - Đặt 1 máy Bánh Răng tại `(26.5, -30.5)` rút sắt từ Main Bus qua long inserter, nhả bánh răng xuống belt cấp liệu `Y=-27.5`.
    - Đặt Dàn 6 máy Red Science tại `Y=-24.5` (`X=27.5, 31.5, 35.5, 39.5, 43.5, 47.5`) kèm 6 inserter nạp liệu (`Y=-26.5`) và 6 inserter xuất liệu (`Y=-22.5`).
    - Trục thu hoạch bình đỏ chạy ngang tại `Y=-21.5` từ X=28.5 đến 52.5.
    - Dàn 3 Labs Daisy-Chain tại `(54.5, -21.5)`, `(58.5, -21.5)`, `(62.5, -21.5)` nối tiếp nhau bằng inserters.

51. Quy luật Bán kính Cấp điện Cột Điện Nhỏ (Electric Pole Supply Area Trap - agent 2026-09-16):
    - `small-electric-pole` có tầm nối dây (wire reach) 7.5 ô nhưng vùng cấp điện (supply area) chỉ là hình vuông 5x5 ô (bán kính 2.5 ô).
    - Cột đặt tại `Y=-24.5` chỉ phủ điện từ Y=-27.0 đến Y=-22.0. Các thực thể đặt tại `Y=-21.5` (như dàn Lab và inserter Lab) bị hụt đúng 0.5 ô và rơi vào lỗi `status_name: no_power`.
    - Quy tắc: Cột điện bắt buộc phải đặt trong khoảng cách vuông góc <= 2.5 ô tới bounding box của entity (ví dụ đặt cột tại `Y=-19.5` để phủ dải `Y=[-22.0, -17.0]`).

52. Bẫy Tranh Chấp Làn Băng Chuyền Đôi (Half-Belt Far-Lane Collision Trap - agent 2026-09-16):
    - Trong Factorio, inserter xả vuông góc vào belt luôn thả vào làn XA (Far lane / Line 2); inserter xả dọc trục vào đuôi belt cũng thả vào làn PHẢI (Line 2).
    - Khi cả inserter đồng (từ Bus) và inserter bánh răng cùng xả vào belt `Y=-27.5` theo hướng này, đồng nạp trước chiếm trọn Line 2 làm inserter bánh răng kẹt cứng ở `waiting_for_space_in_destination`, trong khi Line 1 (North lane) bị bỏ trống 100%!
    - Quy tắc giải quyết: Sử dụng nhánh belt vuông góc đâm vào sườn (side-load) để rót tài nguyên thứ nhất (nhánh đâm từ Bắc vào sẽ ép 100% tài nguyên vào North lane / Line 1), trong khi tay gắp xả ngang thả tài nguyên thứ hai vào South lane / Line 2. Tuyến belt được phân làn 50/50 hoàn hảo, chấm dứt triệt để xung đột.

53. Nghiệm thu Thực tế & Hoàn tất Nghiên cứu Tự động (agent 2026-09-16):
    - Công nghệ `military` (10 bình đỏ) hoàn tất 100% tự động.
    - Công nghệ `heavy-armor` (30 bình đỏ) đang vận hành ổn định.
54. The Mall Giai đoạn 3 — Tự động hóa sản xuất Tay Máy Nhanh (Fast Inserter) & Hoàn tất Heavy-Armor (agent 2026-09-16):
    - Kéo dài Main Bus Sắt (X=22.5) và Đồng (X=23.5) xuống Y=8.5. Kéo dài belt Mạch Xanh (X=29.5) xuống Y=7.5.
    - Lắp đặt Machine 7 (assembling-machine-1) tại (26.5, 7.5), gán recipe `fast-inserter`.
    - Cấp liệu tự động: Inserter (26.5, 5.5) rút tay gắp thường từ Rương buffer (26.5, 4.5); Long inserter (24.5, 7.5) rút sắt từ Bus X=22.5; Inserter (28.5, 7.5) rút mạch xanh từ belt X=29.5.
    - Rương buffer Fast Inserter tại (26.5, 10.5) hứng sản phẩm qua inserter (26.5, 9.5).
    - Cột điện nhỏ tại (24.5, 8.5) và (30.5, 7.5) cấp điện 100%. Rương buffer đã bắt đầu tích lũy Fast Inserters.
    - Nghiên cứu: `heavy-armor` (30 bình đỏ) hoàn tất 100%. Tiếp tục kích hoạt `physical-projectile-damage-1` (100 bình đỏ) duy trì tải ổn định.

## Điều chưa được kiểm chứng

- Lưu trực tiếp `LuaEntity` của kho vào `storage` có tồn tại qua các UDP request
  và save/reload đúng như tài liệu hay không; cần restart để nạp bản vá rồi A/B.
- Fallback sang inventory người chơi đã build và kiểm tra syntax nhưng chưa
  được kiểm tra qua save/reload sau một phiên dài.
- `LuaBurner.currently_burning` trả `nil` trong khi `remaining_burning_fuel > 0`
  trên burner drill; cần hiểu semantics trước khi dùng tên prototype nhiên liệu.
- Serialization thực tế của snapshot lớn và inventory có nhiều quality.
- Recipe name có luôn khớp item đặt entity trong mọi mod đang bật hay không.
- Chuỗi `remove → create → refund` dưới lỗi runtime thật.
- Tương tác với mod khác khi `raise_built = true`.
- Giới hạn kích thước UDP an toàn khi bản đồ có nhiều entity/resource.
- **Ba action mới `tiles` / `probe` / `recipe` (agent 2026-09-16) CHƯA CHẠY THẬT
  LẦN NÀO.** `luac -p` xanh và 13/13 unittest phía client xanh, nhưng cả hai chỉ
  chứng minh cú pháp và cách dựng gói — không chứng minh handler sống trong game.
  Bản đang chạy trong RAM vẫn là build cũ (`ping` chưa trả `build`/`actions`).
  Nghiệm thu: sau khi load lại save, `ping` phải trả
  `build="2026-09-16-tiles-probe-recipe"` và đủ 12 action; rồi mới đo từng cái.

Không mục nào trong phần này được coi là quy tắc đã xác nhận.

## Cổng trưởng thành của tool

- **Discovery — ĐÃ QUA (2026-09-16):** đọc và xây thật từng bước nhỏ; mọi luật
  gặp phải đã ghi ở đây. Cổng này chỉ mở lại cho từng cơ chế game MỚI chưa đo.
- **Hardening sau discovery — ĐANG Ở ĐÂY:** chỉ sửa kiến trúc dựa trên lỗi hoặc
  giới hạn đã tái hiện, không dựa trên giả thuyết. Luật 39 xác nhận cổng này vẫn
  chi phối tool; sắc lệnh clean-rebuild không ghi đè nó.
- **Automation — ĐIỀU KIỆN ĐÃ ĐẠT:** đường `snapshot → preflight → trừ item →
  build → audit` đã có receipt đầy đủ (luật 33). Xây hàng loạt và tối ưu theo
  tính toán được phép từ đây.
