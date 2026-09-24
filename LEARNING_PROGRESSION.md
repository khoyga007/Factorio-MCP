# Factorio 2.0 — Learning Progression & Physical Rules Notebook

Nhật ký quan sát trong Sandbox Factorio 2.0. Các kết luận phụ thuộc prototype, hướng và phiên bản; không dùng mọi câu trong nhật ký như luật tổng quát. Đối chiếu API và test engine trước khi đưa vào tool.

**Đối chiếu 2026-09-17:** build `2026-09-17-mcp-fixes` đã kiểm tra đọc fluid/ports, insert rương, snapshot vật cản, collect đồ rơi giữ quality/ammo, và đặt hai đầu underground-belt cùng hướng bằng `type` tường minh. `dry-run.can_place` đã độc lập với vật tư từ trước. Các đoạn đo đạc cũ bên dưới là dữ liệu lịch sử.

---

## Mục lục
1. [Hệ quy chiếu Lưới Tile & Hình học Thực thể (Grid Geometry & Bounding Box)](#1-hệ-quy-chiếu-lưới-tile--hình-học-thực-thể)
2. [Hệ thống Ống & Dẫn dịch (Fluidbox Mechanics)](#2-hệ-thống-ống--dẫn-dịch-fluidbox-mechanics)
3. [Hệ thống Băng chuyền (Transport Belt Mechanics)](#3-hệ-thống-băng-chuyền-transport-belt-mechanics)
4. [Tay gắp & Cơ chế Chuyển dịch (Inserter Mechanics)](#4-tay-gắp--cơ-chế-chuyển-dịch-inserter-mechanics)
5. [Đầu vào / Đầu ra của Thiết bị Sản xuất (Machine I/O)](#5-đầu-vào--đầu-ra-của-thiết-bị-sản-xuất-machine-io)
6. [Đặc tả Nâng cấp Tooling (Bridge Tool Specifications)](#6-đặc-tả-nâng-cấp-tooling-bridge-tool-specifications)
7. [Bài Test Sát hạch Tích hợp Sandbox: Mini-Factory Hoàn chỉnh (Phương án A)](#7-bài-test-sát-hạch-tích-hợp-sandbox-mini-factory-hoàn-chỉnh-phương-án-a)
8. [Generic Blueprint Acceptance & Holdout Criteria (PORTING.md §5)](#8-generic-blueprint-acceptance--holdout-criteria-portingmd-5)

---

## 1. Hệ quy chiếu Lưới Tile & Hình học Thực thể

### 1.1. Bản chất Lưới Tile (Tile Grid Standard)
* Bản đồ Factorio được chia thành lưới các ô vuông 1x1 tile.
* Một ô tile (Xt, Yt) với Xt, Yt nguyên bao phủ miền: `[Xt, Xt + 1] x [Yt, Yt + 1]`.
* **Tâm hình học của ô tile** luôn là tọa độ nửa nguyên: `(Xt + 0.5, Yt + 0.5)`.

### 1.2. Quy tắc Tọa độ Đặt Thực thể (Center Snap Rule)
* **Kích thước Lẻ x Lẻ** (ví dụ 1x1, 3x3, 3x5):
  * Cả hai trục bắt buộc đặt tại tọa độ **NỬA NGUYÊN** (`half-integer`): `x = n + 0.5, y = m + 0.5`.
  * Áp dụng cho: `pipe`, `transport-belt`, `small-electric-pole`, `steam-engine`, `inserter`, `assembling-machine-1`. `stone-furnace` là 2×2, tâm số nguyên trên cả hai trục.
* **Kích thước Chẵn x Lẻ** (ví dụ 2x1, 2x3):
  * Trục có kích thước chẵn bắt buộc đặt tại tọa độ **SỐ NGUYÊN** (`integer`): `x = n`.
  * Trục có kích thước lẻ bắt buộc đặt tại tọa độ **NỬA NGUYÊN** (`half-integer`): `y = m + 0.5`.
* **Kích thước Lẻ x Chẵn** (ví dụ 3x2 như `boiler` xoay North/South):
  * Trục X (rộng 3): tọa độ **NỬA NGUYÊN** (`x = n + 0.5`).
  * Trục Y (cao 2): tọa độ **SỐ NGUYÊN** (`y = m`).

*(Đang tiến hành đo đạc thực nghiệm các mục tiếp theo...)*

---

## 2. Hệ thống Ống & Dẫn dịch (Fluidbox Mechanics)

### 2.1. Quy chuẩn Kết nối của Ống nước thường (`pipe`)
* **Kích thước**: $1 \times 1$ tile. Tâm luôn là $(n + 0.5, m + 0.5)$.
* **Tính vô hướng**: Pipe tự động kết nối với mọi fluidbox ở cả 4 hướng (North, East, South, West) nếu khoảng cách tâm giữa 2 entity đúng bằng **1.0 tile**.
* **Cơ chế Bounding Box Biến thiên (Dynamic Flange)**:
  * Khi không có kết nối ở một cạnh: Bounding box co lại cách mép ô gạch $\sim 0.21 - 0.29$ tile (nắp bịt ống, kích thước box $\approx 0.58 \times 0.58$).
  * Khi có kết nối ở một cạnh: Bounding box tự động vươn dài ra sát ranh giới ô gạch ($\approx 0.988$ tile), chạm khít vào flange của ống kế tiếp với khe hở chỉ $\sim 0.023$ tile.
* **Chứng minh thực tế (Runtime Tick 25179 & 25825)**:
  * Pipe #37 $(100.5, -100.5)$ nối Pipe #38 $(101.5, -100.5)$ nối Pipe #41 $(102.5, -100.5)$ -> Tạo đường ống thẳng 3 ô.
  * Đặt thêm Pipe #42 $(101.5, -99.5)$ -> Pipe #38 tự động mở cút phía Nam: `right_bottom.y` đổi từ `-100.21` thành `-100.01`, chạm khít vào `left_top.y` (`-99.99`) của Pipe #42 để tạo cút chữ T hoàn hảo.

---

## 4. Đầu vào / Đầu ra của Thiết bị Sản xuất (Machine I/O)

### 4.1. Cơ chế Nhả trực tiếp từ Miner vào Furnace (Direct Drop)
* **Kích thước**: Cả `burner-mining-drill` và `stone-furnace` đều là $2 \times 2$ tile (tâm là số nguyên $n, m$).
* **Drop Position của Drill**: Nằm cách tâm máy đúng $1.5$ tile theo hướng đào (ví dụ quay South thì drop tại $y + 1.5$).
* **Quy luật Ghép nối Không cần Inserter / Belt**:
  * Khi đặt `stone-furnace` tiếp giáp trực tiếp theo phương dọc: Tâm lò tại $(X_d, Y_d + 2.0)$ (quay North hoặc South).
  * Vị trí nhả $Y_d + 1.5$ của drill rơi trọn vào diện tích chiếm dụng $[Y_d + 1.0, Y_d + 3.0]$ của lò nung.
  * **Kết quả đo thực tế (Runtime Tick 30900)**:
    * Miner #57 $(65, -79)$ nạp 2 wood -> đào `copper-ore`.
    * Furnace #58 $(65, -77)$ nạp 1 wood -> tự động nhận quặng vào slot `source` và nung thành công `copper-plate` trong khoang output.
    * Thu hoạch thành công $3$ `copper-plate` trực tiếp từ output inventory.

---

## 3. Hệ thống Băng chuyền & Tay gắp (Belt & Inserter Lane Dynamics)

### 3.1. Vector Gắp & Thả của Tay gắp (`inserter`)
* **Kích thước**: $1 \times 1$ tile. Tâm luôn là $(n + 0.5, m + 0.5)$.
* **Bảng Ma trận Vector 4 Hướng (Đo thực tế Runtime Tick 31500)**:
  | Hướng (`direction`) | Góc xoay | Vị trí Gắp (`pickup_position`) | Vị trí Thả (`drop_position`) | Mô tả hình học |
  | :--- | :---: | :---: | :---: | :--- |
  | `north` (0) | $0^\circ$ | $(X, Y - 1.0)$ | $(X, Y + 1.2)$ | Gắp phía Bắc, vươn ném về phía Nam |
  | `east` (4) | $90^\circ$ | $(X + 1.0, Y)$ | $(X - 1.2, Y)$ | Gắp phía Đông, vươn ném về phía Tây |
  | `south` (8) | $180^\circ$ | $(X, Y + 1.0)$ | $(X, Y - 1.2)$ | Gắp phía Nam, vươn ném về phía Bắc |
  | `west` (12) | $270^\circ$ | $(X - 1.0, Y)$ | $(X + 1.2, Y)$ | Gắp phía Tây, vươn ném về phía Đông |

### 3.2. Định luật Làn Xa (The Far-Lane Law)
* **Khoảng cách ném**: Inserter vươn cần thả đúng **$1.2$ tile** (vượt qua tâm ô gạch $1.0$ thêm $0.2$ tile).
* **Quy luật bất biến**: Khi Inserter thả vật phẩm vuông góc vào Băng chuyền (`transport-belt`), vật phẩm **LUÔN LUÔN RƠI VÀO LÀN XA (FAR LANE)** so với vị trí đứng của Inserter.
* **Ánh xạ Làn trong Bridge API (`transport_line`)**:
  * Theo quy chuẩn Factorio Engine: Khi nhìn theo chiều chuyển động của Belt:
    * `Line 1` = Làn bên TRÁI (Left lane).
    * `Line 2` = Làn bên PHẢI (Right lane).
  * *Ví dụ thực tế*: Belt chạy hướng `north` (0):
    * Inserter đặt ở sườn Tây (West) thả vào Belt -> Rơi vào Làn Đông (Far lane) = **`Line 2`**.
    * Inserter đặt ở sườn Đông (East) thả vào Belt -> Rơi vào Làn Tây (Far lane) = **`Line 1`**.
* **Ứng dụng thiết kế công nghiệp**:
  * Để nạp đồng thời Quặng và Than lên cùng 1 Belt cấp cho Lò nung: Bố trí nguồn cấp từ 2 bên đối xứng, vật phẩm sẽ tự động chia đều vào 2 làn riêng biệt mà không bao giờ gây tắc nghẽn.

---

## 2. Hệ thống Ống & Dẫn dịch (tiếp theo)

### 2.2. Giải phẫu Hình học & Cổng kết nối của Lò hơi (`boiler`)
* **Bản chất Hình học**: Lò hơi là thực thể $3 \times 2$ (khi xoay dọc North/South) hoặc $2 \times 3$ (khi xoay ngang East/West).
* **Ma trận Tọa độ & Cổng kết nối 4 Hướng (Đo thực tế Runtime Tick 33200)**:
  
  | Hướng (`direction`) | Kích thước $(W \times H)$ | Tọa độ Tâm $(X_c, Y_c)$ | Cổng Nước vào/ra (Water Ports) | Cổng Hơi (Steam Output) | Lò đốt than (Fuel Door) |
  | :---: | :---: | :---: | :--- | :--- | :--- |
  | **`south` (8)** | $3 \times 2$ | $(n + 0.5, m)$ | $2$ cổng xuyên ngang tại hàng Bắc: $(X_c \pm 2.0, Y_c - 0.5)$ | Chĩa về phía Bắc: $(X_c, Y_c - 1.0)$ | Hướng về Nam ($Y_c + 0.5$) |
  | **`north` (0)** | $3 \times 2$ | $(n + 0.5, m)$ | $2$ cổng xuyên ngang tại hàng Nam: $(X_c \pm 2.0, Y_c + 0.5)$ | Chĩa về phía Nam: $(X_c, Y_c + 1.0)$ | Hướng về Bắc ($Y_c - 0.5$) |
  | **`east` (4)** | $2 \times 3$ | $(n, m + 0.5)$ | $2$ cổng xuyên dọc tại cột Tây: $(X_c - 0.5, Y_c \pm 2.0)$ | Chĩa về phía Đông: $(X_c + 1.0, Y_c)$ | Hướng về Tây ($X_c - 0.5$) |
  | **`west` (12)** | $2 \times 3$ | $(n, m + 0.5)$ | $2$ cổng xuyên dọc tại cột Đông: $(X_c + 0.5, Y_c \pm 2.0)$ | Chĩa về phía Tây: $(X_c - 1.0, Y_c)$ | Hướng về Đông ($X_c + 0.5$) |

* **Định luật Kết nối Nước Boiler**:
  1. Khi Boiler quay hướng `south` tại tâm $(X_c, Y_c)$:
     * Đường ống nước xuyên ngang nằm ở **hàng trên** ($Y = Y_c - 0.5$).
     * Ống nối tiếp giáp bên sườn Tây phải đặt tại $(X_c - 2.0, Y_c - 0.5)$.
     * Ống nối tiếp giáp bên sườn Đông phải đặt tại $(X_c + 2.0, Y_c - 0.5)$.
     * *Bẫy kinh điển trước đó*: Đặt ống tại $Y = Y_c$ hoặc $Y = Y_c + 0.5$ sẽ hoàn toàn lệch trục ống ngầm của Boiler, dẫn tới lỗi `no_input_fluid`.
  2. Cổng hơi nước (Steam Output) nằm ở cạnh $3$-tile đối diện với cửa lò than. Khi nối với `steam-engine`:
     * Với Boiler `south` tại $(X_c, Y_c)$, cổng steam chĩa thẳng lên hướng Bắc.
     * Cổng hơi tiếp xúc trực tiếp tại $Y = Y_c - 1.0$, sẵn sàng cắm thẳng vào đầu vào của Steam Engine đặt tại $(X_c, Y_c - 3.5)$ (khi Engine dài 5 ô, tâm $Y_c - 3.5$, mép dưới chạm $Y_c - 1.0$).

---

---

## 2. Hệ thống Ống & Dẫn dịch (tiếp theo)

### 2.3. Quy chuẩn Khớp nối của Ống ngầm (`pipe-to-ground`)
* **Kích thước**: $1 \times 1$ tile. Tâm luôn là $(n + 0.5, m + 0.5)$.
* **Bản chất `direction` của Engine Factorio**:
  * `direction` của entity `pipe-to-ground` chính là **hướng quay của CỔNG NỐI MẶT ĐẤT (Surface Flange)**, còn đoạn ống ngầm (underground connection) luôn đâm vào lòng đất theo **hướng ngược lại (`(dir + 8) % 16`)**.
  * **Quy tắc đặt 2 đầu ngầm đối nhau**:
    * **Đầu Bắc** (nối với ống nổi phía Bắc, chui ngầm về phía Nam): Bắt buộc `direction = 0` (`north`).
    * **Đầu Nam** (nối với ống nổi phía Nam, chui ngầm về phía Bắc): Bắt buộc `direction = 8` (`south`).
    * **Đầu Tây** (nối với ống nổi phía Tây, chui ngầm về phía Đông): Bắt buộc `direction = 12` (`west`).
    * **Đầu Đông** (nối với ống nổi phía Đông, chui ngầm về phía Tây): Bắt buộc `direction = 4` (`east`).
  * *(Cảnh báo sai lầm chết người: Nếu nhầm `direction` là hướng ống ngầm thì 2 cổng nổi sẽ quay vào khoảng trống giữa 2 đầu ngầm, còn 2 đầu ngầm chọc ngược ra ngoài, làm đứt dòng chảy hoàn toàn!)*.
* **Định luật Tầm ngầm Tối đa (Đo thực tế Runtime Tick 121644 & 380500)**:
  * Khoảng cách ngầm tối đa cho phép là **đúng 10 ô tile khoảng trống** ở giữa.
  * Tương ứng với **khoảng cách tâm giữa 2 đầu đúng bằng $11.0$ tile**.
  * *Ví dụ thực tế đã kiểm chứng*:
    * Cặp crossing tại $x = -57.5$: Đầu Bắc tại $(-57.5, 19.5)$ quay `north` (0); Đầu Nam tại $(-57.5, 23.5)$ quay `south` (8). Đoạn ngầm vượt qua 3 tile rỗng $y \in [20, 23]$, nước chảy thông suốt $100.0$ unit.
* **Cổng Nổi trên mặt đất (Surface Flanges)**: Cổng sau lưng của đầu nổi tự động khớp nối với `pipe` thường cùng hướng `direction` khi khoảng cách tâm đúng bằng $1.0$ tile.

### 2.4. Ma trận Cổng Chất lỏng của Nhà máy Hóa chất (`chemical-plant`) và Lọc dầu (`oil-refinery`)
Được kiểm chứng chính xác $100\%$ qua đo đạc độ giãn Bounding Box của `pipe` trên runtime Sandbox:

#### A. Nhà máy Hóa chất (`chemical-plant` $3 \times 3$, tâm $X_c, Y_c$):
* Khi quay hướng `north` (0):
  * **2 Cổng vào (Fluid Inputs)** ở cạnh Bắc ($Y = Y_c - 1.5$):
    * Cổng Trái (Tây): $(X_c - 1.0, Y_c - 1.5)$
    * Cổng Phải (Đông): $(X_c + 1.0, Y_c - 1.5)$
    * *(Ô chính giữa $X_c$ ở cạnh Bắc là tường kín, không có cổng)*.
  * **2 Cổng ra (Fluid Outputs)** ở cạnh Nam ($Y = Y_c + 1.5$):
    * Cổng Trái (Tây): $(X_c - 1.0, Y_c + 1.5)$
    * Cổng Phải (Đông): $(X_c + 1.0, Y_c + 1.5)$
  * **Khoảng cách giữa 2 cổng cùng phía**: Đúng **$2.0$ tile** (cách 1 ô trống ở giữa).
  * Ống cấp dịch ngoài bắt buộc đặt tại $(X_c \pm 1.0, Y_c - 2.0)$ và $(X_c \pm 1.0, Y_c + 2.0)$. Flange của pipe giãn tới ranh giới tile với khe hở chỉ $0.0117$ tile.

#### B. Nhà máy Lọc dầu (`oil-refinery` $5 \times 5$, tâm $X_c, Y_c$):
* Khi quay hướng `north` (0):
  * **3 Cổng vào (Fluid Inputs)** ở cạnh Bắc ($Y = Y_c - 2.5$):
    * Cổng Trái: $(X_c - 2.0, Y_c - 2.5)$
    * Cổng Giữa: $(X_c, Y_c - 2.5)$
    * Cổng Phải: $(X_c + 2.0, Y_c - 2.5)$
  * **3 Cổng ra (Fluid Outputs)** ở cạnh Nam ($Y = Y_c + 2.5$):
    * Cổng Trái: $(X_c - 2.0, Y_c + 2.5)$
    * Cổng Giữa: $(X_c, Y_c + 2.5)$
    * Cổng Phải: $(X_c + 2.0, Y_c + 2.5)$
  * **Quy luật Bước Nhảy 2 Ô**: Cả 3 cổng vào và 3 cổng ra đều nằm cách nhau đúng **$2.0$ tile** theo trục ngang. Cả 3 ống pipe đặt tại $(X_c - 2.0, Y_c - 3.0)$, $(X_c, Y_c - 3.0)$, $(X_c + 2.0, Y_c - 3.0)$ đều tự động kết nối đồng thời mà không bị kẹt chéo!

#### C. Cổng Chất lỏng của Máy lắp ráp 2 & 3 (`assembling-machine-2` / `assembling-machine-3` $3 \times 3$):
* Khi chạy các công thức thuộc danh mục `crafting-with-fluid` (như `electric-engine-unit`, `processing-unit`):
  * Khi máy quay `north` (0): Cổng vào chất lỏng xuất hiện tại **chính giữa cạnh Bắc**: $(X_c, Y_c - 1.5)$.
  * Ống cấp dịch ngoài bắt buộc cắm vào ô $(X_c, Y_c - 2.0)$.


---

## 3. Hệ thống Băng chuyền & Phân luồng (Logistics & Belts)

### 3.3. Giải phẫu Hình học & Cổng của Bộ chia tách (`splitter`)
* **Bản chất Hình học**: Kích thước $2 \times 1$ tile (khi quay North/South) hoặc $1 \times 2$ tile (khi quay East/West).
* **Quy tắc Tọa độ Tâm (Hoán đổi Trục Chẵn/Lẻ)**:
  * Khi quay `north` (0) hoặc `south` (8): Chiều rộng 2 ô (trục X), chiều cao 1 ô (trục Y). Tâm bắt buộc là **`X nguyên, Y nửa nguyên`** $(n, m + 0.5)$. (Đã đo thực tế Splitter #1073 tại $(100.0, -100.5)$).
  * Khi quay `east` (4) hoặc `west` (12): Chiều rộng 1 ô (trục X), chiều cao 2 ô (trục Y). Tâm bắt buộc là **`X nửa nguyên, Y nguyên`** $(n + 0.5, m)$. (Đã đo thực tế Splitter #1074 tại $(103.5, -100.0)$).
* **Bounding Box Thực tế**:
  * Khi quay North/South: $[X_c - 0.898, Y_c - 0.398] \times [X_c + 0.898, Y_c + 0.398]$ (vùng chiếm dụng $1.8 \times 0.8$ tile).
  * Khi quay East/West: $[X_c - 0.398, Y_c - 0.898] \times [X_c + 0.398, Y_c + 0.898]$ (vùng chiếm dụng $0.8 \times 1.8$ tile).
* **Hệ thống Cổng Đầu vào / Đầu ra (2 Inputs, 2 Outputs)**:
  * Khi quay `north` tại $(X_c, Y_c)$:
    * 2 Cổng vào ở phía Nam: Làn trái tại $(X_c - 0.5, Y_c + 0.5)$, Làn phải tại $(X_c + 0.5, Y_c + 0.5)$.
    * 2 Cổng ra ở phía Bắc: Làn trái tại $(X_c - 0.5, Y_c - 0.5)$, Làn phải tại $(X_c + 0.5, Y_c - 0.5)$.
  * Tương tác luồng: Tự động cân bằng tỉ lệ 50/50 qua 2 cổng ra, hỗ trợ bộ lọc vật phẩm (filter) và thiết lập ưu tiên vào/ra (priority input/output).

### 3.4. Đẳng cấp Tốc độ 4 Tầng Băng chuyền (Belt Speed Hierarchy)
Số liệu trích xuất trực tiếp từ Prototype Engine Factorio 2.0 (`tick_rate = 60`):

| Cấp Băng chuyền | Tên Prototype (`name`) | Tốc độ (`belt_speed`) | Vận tốc Thực tế | Thông lượng Tối đa | Thông lượng Mỗi làn |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **Cấp 1 (Vàng)** | `transport-belt` | $0.03125\text{ tile/tick}$ | $1.875\text{ tile/s}$ | **$15.0\text{ items/s}$** | $7.5\text{ items/s}$ |
| **Cấp 2 (Đỏ)** | `fast-transport-belt` | $0.06250\text{ tile/tick}$ | $3.750\text{ tile/s}$ | **$30.0\text{ items/s}$** | $15.0\text{ items/s}$ |
| **Cấp 3 (Xanh)** | `express-transport-belt`| $0.09375\text{ tile/tick}$ | $5.625\text{ tile/s}$ | **$45.0\text{ items/s}$** | $22.5\text{ items/s}$ |
| **Cấp 4 (Turbo)**| `turbo-transport-belt` | $0.12500\text{ tile/tick}$ | $7.500\text{ tile/s}$ | **$60.0\text{ items/s}$** | $30.0\text{ items/s}$ |

* **Định luật Tỷ lệ Vàng**: Tỷ lệ thông lượng giữa 4 tầng belt là **$1 : 2 : 3 : 4$**. Nâng cấp 1 belt đỏ = 2 belt vàng; 1 belt xanh = 3 belt vàng; 1 belt turbo = 4 belt vàng.

---

## 4. Hệ thống Điện năng & Công nghệ Nâng cao (Power & Advanced Tech)

### 4.2. Khảo sát Hình học Cột điện & Lưới điện (Power Grid Anatomy)
* **`small-electric-pole`**: $1 \times 1$ (tâm nửa nguyên). Tầm với dây $7.5$ tile, vùng cấp điện $5 \times 5$ tile.
* **`medium-electric-pole`**: $1 \times 1$ (tâm nửa nguyên). Tầm với dây $9.0$ tile, vùng cấp điện $7 \times 7$ tile. Tiêu chuẩn công nghiệp cho nội bộ nhà máy.
* **`big-electric-pole`**: $2 \times 2$ (tâm số nguyên $n, m$). Tầm với dây $32.0$ tile, vùng cấp điện hẹp $4 \times 4$ tile. Chuyên dụng làm trục truyền tải điện đường dài (High-voltage Backbone).
* **`substation` (Trạm biến áp)**:
  * Kích thước: $2 \times 2$ tile (tâm số nguyên $n, m$). Bounding box thực tế co lại $1.4 \times 1.4$ ở trung tâm: $[X_c - 0.7, Y_c - 0.7] \times [X_c + 0.7, Y_c + 0.7]$ để chừa lối đi bộ cho player/robot.
  * Tầm với dây: $18.0$ tile. Vùng cấp điện cực rộng: $18 \times 18$ tile bao quanh trạm.
* **Cơ chế Bắt dây Tự động**: Mọi cột điện nằm trong tầm với dây của nhau sẽ tự động phóng dây đồng nối vào chung 1 mạng lưới (`electric-network`).

### 4.3. Đường ray Cao tầng & Tự động hóa Robot (Factorio 2.0 Elevated Rails & Robotics)
* **`rail-ramp` (Dốc cầu vượt ray)**: Kích thước khổng lồ $2 \times 16$ tile. Dùng để chuyển tiếp ray mặt đất lên ray tầng 2.
* **`rail-support` (Trụ đỡ ray trên cao)**: Kích thước $3 \times 3$ tile (tâm nửa nguyên).
* **`train-stop` (Ga tàu hỏa)**: Kích thước $2 \times 2$ tile (tâm số nguyên).
* **`roboport` (Nhà chứa robot)**: Kích thước $4 \times 4$ tile (tâm số nguyên).
* **`combinator` (Decider / Arithmetic / Selector)**: Kích thước $1 \times 2$ tile (Lẻ x Chẵn $\to$ tâm hoán đổi theo hướng).

### 4.4. Khảo sát Thiết bị Sản xuất & Khoa học Nâng cao (Assembly, Mining, Labs & Beacons)
* **`electric-mining-drill` (Máy khoan điện $3 \times 3$)**:
  * Tọa độ tâm luôn là nửa nguyên $(n + 0.5, m + 0.5)$. Bounding box chiếm dụng $[X_c - 1.35, Y_c - 1.35] \times [X_c + 1.35, Y_c + 1.35]$.
  * **Vùng khai thác thực tế (Mining Area)**: Phủ rộng **$5 \times 5$ tile** (tràn ra ngoài ranh giới máy đúng 1 tile ở cả 4 phía, từ $X_c - 2.5$ tới $X_c + 2.5$). Nhờ đó 2 drill điện đặt cách nhau 1 ô trống vẫn vét sạch $100\%$ quặng nằm ở giữa!
  * **Vị trí nhả quặng (Drop Position)**: Nằm ở chính giữa mép nhả, cách tâm máy đúng $1.5$ tile theo hướng chĩa (ví dụ quay `south` thì drop tại $Y_c + 1.5$). Nhả trực tiếp vào Belt hoặc Rương mà không cần Inserter.
* **`assembling-machine-1 / 2 / 3` (Máy lắp ráp $3 \times 3$)**:
  * Tọa độ tâm luôn là nửa nguyên $(n + 0.5, m + 0.5)$.
  * Bản đồ 12 ô tiếp giáp bao quanh máy cho phép Inserter nạp liệu/rút hàng từ bất kỳ hướng nào.
  * Tốc độ chế tạo (`crafting_speed`): Assembler 1 = $0.5$; Assembler 2 = $0.75$; Assembler 3 = $1.25$.
* **`lab` (Phòng thí nghiệm $3 \times 3$) & Kỹ thuật Daisy-Chaining**:
  * Tọa độ tâm luôn là nửa nguyên $(n + 0.5, m + 0.5)$.
  * Nhận bình khoa học vào khoang `input` (`defines.inventory.lab_input`).
  * **Định luật Chuyền bình (Daisy-Chaining)**: Khi 2 Lab đặt cách nhau 1 tile trống (khoảng cách tâm $4.0$ tile), một Inserter đặt ở giữa có thể gắp trực tiếp bình khoa học từ Lab A chuyền sang Lab B. Cho phép mở rộng dãy phòng thí nghiệm vô tận chỉ bằng 1 tuyến cấp bình duy nhất ở đầu hàng.
* **`beacon` (Trạm phát sóng hiệu ứng $3 \times 3$)**:
  * Tọa độ tâm luôn là nửa nguyên $(n + 0.5, m + 0.5)$.
  * Chứa module tăng tốc/năng suất để truyền sóng hiệu ứng tới các máy xung quanh.
  * **Vùng phát sóng hiệu ứng**: Hình vuông **$9 \times 9$ tile** bao quanh tâm Beacon (vươn ra ngoài mép Beacon đúng 3 tile mỗi phía). Mọi Assembler hoặc Drill chạm vào vùng này đều được nhận hiệu ứng tăng tốc.


---

## 5. Tổng kết Quy chuẩn Hình học Toàn bộ Thực thể (Master Geometry Table)

| Thực thể (`name`) | Kích thước $(W \times H)$ | Tọa độ Tâm hợp lệ | Cổng Kết nối / Đặc tính Cơ học |
| :--- | :---: | :---: | :--- |
| `pipe` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Vô hướng. Tự mở cút (flange giãn ra $0.988$) khi có entity kế cận cách đúng $1.0$ tile. |
| `pipe-to-ground` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Có hướng đối đầu. Tầm ngầm tối đa đúng **10 ô khoảng trống** (tâm cách nhau $11.0$ tile). |
| `transport-belt` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Có hướng ($0, 4, 8, 12$). Gồm $2$ làn: `Line 1` (Trái), `Line 2` (Phải). Thông lượng $15\text{/s}$. |
| `fast-transport-belt` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Thông lượng $30\text{ items/s}$. Gấp đôi belt vàng. |
| `express-transport-belt`| $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Thông lượng $45\text{ items/s}$. Gấp ba belt vàng. |
| `turbo-transport-belt` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Thông lượng $60\text{ items/s}$. Gấp bốn belt vàng. |
| `splitter` (dọc) | $2 \times 1$ | $(n, m + 0.5)$ | Quay North/South: X nguyên, Y nửa nguyên. 2 vào Nam, 2 ra Bắc. |
| `splitter` (ngang) | $1 \times 2$ | $(n + 0.5, m)$ | Quay East/West: X nửa nguyên, Y nguyên. 2 vào Tây, 2 ra Đông. |
| `inserter` | $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Gắp tại $1.0$ tile (đằng sau). Ném tại $1.2$ tile (đằng trước) -> **Luôn rơi vào LÀN XA** của Belt. |
| `small-electric-pole`| $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Dây với $7.5$ tile. Vùng cấp điện $5 \times 5$ tile. |
| `medium-electric-pole`| $1 \times 1$ | $(n + 0.5, m + 0.5)$ | Dây với $9.0$ tile. Vùng cấp điện $7 \times 7$ tile. |
| `big-electric-pole` | $2 \times 2$ | $(n, m)$ (Số nguyên) | Dây với $32.0$ tile. Vùng cấp điện $4 \times 4$ tile. Trục truyền tải cao thế. |
| `substation` | $2 \times 2$ | $(n, m)$ (Số nguyên) | Dây với $18.0$ tile. Vùng cấp điện $18 \times 18$ tile. Box lõi $1.4 \times 1.4$. |
| `stone-furnace` | $2 \times 2$ | $(n, m)$ (Số nguyên) | Nhận quặng vào slot `source` trực tiếp từ Miner nếu đặt tiếp giáp. |
| `burner-mining-drill`| $2 \times 2$ | $(n, m)$ (Số nguyên) | Vị trí nhả hàng (drop position) cách tâm $1.5$ tile theo hướng chĩa. |
| `electric-mining-drill`| $3 \times 3$ | $(n + 0.5, m + 0.5)$ | Bounding box $3 \times 3$ nhưng vùng đào phủ rộng $5 \times 5$ (tràn ra 1 ô xung quanh). |
| `assembling-machine-1`| $3 \times 3$ | $(n + 0.5, m + 0.5)$ | 12 ô tiếp giáp xung quanh cho Inserter nạp liệu/rút hàng. |
| `chemical-plant` | $3 \times 3$ | $(n + 0.5, m + 0.5)$ | 2 cổng dịch vào, 2 cổng dịch ra. Công suất 210 kW. |
| `oil-refinery` | $5 \times 5$ | $(n + 0.5, m + 0.5)$ | 3 cổng dịch vào, 3 cổng dịch ra. Công suất 420 kW. |
| `storage-tank` | $3 \times 3$ | $(n + 0.5, m + 0.5)$ | Dung tích 25,000 đơn vị dịch. 4 cổng ở 4 phía chính giữa cạnh ($X \pm 1.5$ hoặc $Y \pm 1.5$). |
| `boiler` (xoay dọc) | $3 \times 2$ | $(n + 0.5, m)$ | Quay `south`: Nước xuyên ngang tại $Y - 0.5$; Cổng steam chĩa Bắc tại $Y - 1.0$; Lò than tại $Y + 0.5$. |
| `boiler` (xoay ngang)| $2 \times 3$ | $(n, m + 0.5)$ | Quay `east`: Nước xuyên dọc tại $X - 0.5$; Cổng steam chĩa Đông tại $X + 1.0$; Lò than tại $X - 0.5$. |
| `steam-engine` (dọc) | $3 \times 5$ | $(n + 0.5, m + 0.5)$ | Hai cổng hơi nằm ở 2 đầu cạnh ngắn: $(X, Y \pm 2.5)$. Công suất trần 900 kW, tiêu thụ 30 steam/s. |
| `rail-ramp` | $2 \times 16$ | $(n, m)$ | Cầu vượt dốc ray leo tầng 2. |
| `rail-support` | $3 \times 3$ | $(n + 0.5, m + 0.5)$ | Trụ đỡ cầu vượt ray cao tầng. |
| `roboport` | $4 \times 4$ | $(n, m)$ | Trạm robot vận tải và xây dựng. Vùng logistic $50 \times 50$, xây dựng $110 \times 110$. |
| `combinators` | $1 \times 2$ | Hoán đổi chẵn/lẻ | Mạch logic Decider, Arithmetic, Selector. |

---

## 6. Đặc tả Nâng cấp Bridge Tool

Đề xuất từ Sandbox, đã đối chiếu với code và API 2.0.77 bên dưới. Số dòng cũ chỉ là mốc lịch sử.

### Vá 1: Xóa bỏ "Mù chất lỏng" trong `snapshot` (then in `control.lua`; now `survey.lua` `handle_snapshot`)
* **Hiện trạng**: `entity_data` không đọc `fluidbox`. AI không thể biết ống hoặc máy có nước hay không.
* **Bản vá**: Đọc mảng `entity.fluidbox` và trích xuất `{name, amount, temperature}` vào `data.fluids`.

### Vá 2: Sửa lệnh `insert` hỗ trợ Rương (then in `control.lua`; now `items.lua` `handle_insert`)
* **Hiện trạng**: `handle_insert` coi mọi entity không phải lab/assembler/furnace_source là `fuel`. Khi nạp vào rương (`container`, `logistic-container`), lệnh văng lỗi `entity-has-no-fuel-inventory`.
* **Đã sửa**: Dùng `defines.inventory.chest` cho `container`, `logistic-container`, `linked-container`; chuyển và trừ đúng item thật. Rương vô hạn không thuộc nguồn vật tư gameplay.

### Vá 3: Thêm `fluidbox_prototypes` vào lệnh `spec entity` (then in `control.lua`; now `survey.lua` `handle_spec`)
* **Hiện trạng**: AI không biết vector offset cổng của prototype, phải dùng phương pháp thử-sai.
* **Đã sửa**: Xuất `fluidbox_prototypes` với index, filter, production_type và `pipe_connections` native. API dùng `positions` gồm 4 vị trí tương ứng hướng cardinal, không phải một trường `position`; kèm direction, flow_direction, connection_type và khoảng cách ngầm khi có.

### Vá 4: Tách độc lập `can_place_geometry` trong `place --dry-run` (then in `control.lua`; now `build.lua` `handle_place`)
* **Đính chính**: Code đã trả `can_place = surface.can_place_entity(...)` độc lập với kho. `would_build` mới tổng hợp mọi blocker. Test engine xác nhận `can_place=true`, `would_build=false`, `have=0` khi thiếu lò nhưng đất hợp lệ. Giữ nguyên contract.

### Vá 5: Whitelist `infinity-container` cho Chế độ Sandbox (then in `control.lua`; now the receiver type list in `site.lua`)
* **Hiện trạng**: `CHEST_TYPES` chỉ chứa `container`, `logistic-container`, `linked-container`. Khi chơi Sandbox/Creative, rương vô hạn có prototype type là `infinity-container` nên lệnh `set_treasury` và `collect` hoàn toàn từ chối nhận diện.
* **Phạm vi**: Đây là đề xuất riêng cho fixture Sandbox, không phải lỗi luồng gameplay. Chưa mở rương vô hạn làm nguồn vật tư. Test tự tạo fixture trong bản sao save tách biệt, không thay đổi save đang chơi.

### Vá 6: Xóa bỏ "Mù vật cản tự nhiên" trong `snapshot` (then in `control.lua`; now `survey.lua` `handle_snapshot`)
* **Hiện trạng**: `surface.find_entities_filtered` chỉ lọc danh sách `ENTITY_TYPES` thuộc `force = force` người chơi. Các vật cản tự nhiên như cây cối (`tree`), tảng đá lớn (`simple-entity` / `rock`) và vách đá (`cliff`) bị bỏ qua hoàn toàn, dẫn tới hiện tượng AI thấy tile đất trống nhưng lệnh `place` lại báo lỗi `cannot-place`.
* **Đã sửa**: `snapshot --obstacles` quét riêng cây/đá/vách đá không giới hạn force; trả `obstacles_total` và `obstacles_next_offset`, dùng cùng offset/limit để giới hạn payload.

### Vá 7: Thu gom đồ rơi trong `handle_collect`
* **Đính chính**: Entity type là `item-entity`; `item-on-ground` là tên prototype mặc định. Không suy ra mọi đồ rơi đều chặn mọi công trình; dùng `can_place_entity` cho vị trí cụ thể.
* **Đã sửa**: Collect đúng số lượng từ stack thật, giữ quality/ammo/durability/tags. Chỉ xóa entity khi chuyển hết stack; thiếu đồ hoặc đầy túi giữ nguyên nguồn. `--ground` chọn đồ rơi khi trùng vị trí với máy/rương.

---

## 7. BÀI TEST SÁT HẠCH TÍCH HỢP SANDBOX: MINI-FACTORY HOÀN CHỈNH (Phương án A)

### 7.1. Kiến trúc Tổng thể & Ranh giới Nghiệm thu
* **Tọa độ thi công**: $X \in [162.0, 190.0], Y \in [-169.5, -157.0]$.
* **Lưới điện công nghiệp**: 2 Substation (#1211 tại $(171.0, -167.0)$ và #1184 tại $(183.0, -163.0)$) phủ sóng 100% diện tích mà không xâm lấn trục sản xuất.
* **Nguyên tắc Half-Belt Không Ô Nhiễm (Zero Contamination)**:
  - Trục ngang $Y = -164.5$ (dir=4, east) từ $X = 162.5$ đến $X = 175.5$.
  - Đuôi belt tại $(162.5, -164.5)$ hướng East kích hoạt Side-Loading vuông góc từ nhánh Sắt tại $(163.5, -165.5)$ $\to$ Sắt đổ 100% vào **Làn Bắc (Line 0)**.
  - Inserter #1192 tại $(165.5, -165.5)$ (dir=0, north) thả từ Bắc xuống Nam $\to$ Đồng rơi 100% vào **Làn Nam (Line 1)** (Far-Lane Drop).
  - Độ tinh khiết đo đạc thực tế: Line 0 = 4 `iron-plate`, Line 1 = 4 `copper-plate` từ $X = 165.5$ tới $175.5$, tỷ lệ ô nhiễm 0.000%.
* **Direct Insertion 100% (Không qua Băng chuyền Trung gian)**:
  - Máy 1 (Gear) tại $(169.5, -161.5)$ nạp Sắt từ Làn Bắc qua Inserter #1223 tại $(169.5, -163.5)$.
  - Máy 2 (Bình đỏ) tại $(173.5, -161.5)$ nạp Đồng từ Làn Nam qua Inserter #1226 tại $(173.5, -163.5)$.
  - Inserter Direct Insertion #1225 tại $(171.5, -161.5)$ (dir=12, west) gắp trực tiếp Bánh răng từ Máy 1 chuyền sang Máy 2.
* **Dãy 3 Labs Daisy-Chaining Nối Tiếp**:
  - Inserter #1240 tại $(178.5, -158.5)$ (dir=12, west) gắp Bình đỏ từ băng chuyền xuất $Y = -158.5$ nạp vào Lab 1 tại $(180.5, -158.5)$.
  - Inserter Daisy-Chain 1 #1238 tại $(182.5, -158.5)$ (dir=12, west) chuyền bình từ Lab 1 sang Lab 2 tại $(184.5, -158.5)$.
  - Inserter Daisy-Chain 2 #1239 tại $(186.5, -158.5)$ (dir=12, west) chuyền bình từ Lab 2 sang Lab 3 tại $(188.5, -158.5)$.
  - Kết quả kiểm chứng kho Lab: Lab 1 = 8 bình đỏ, Lab 2 = 4 bình đỏ, Lab 3 = 4 bình đỏ.

### 7.2. Các Quy luật Vật lý & Cơ chế Mới Phát hiện
1. **Quy ước Hướng của Inserter (`direction`)**:
   - Tham số `--direction` khi đặt Inserter là **HƯỚNG QUAY MẶT ĐỂ GẮP (Pickup Direction)**, điểm thả (drop) luôn nằm ở phía đối diện $180^\circ$.
   - `direction = north (0)`: Gắp từ Bắc ($Y - 1$), thả xuống Nam ($Y + 1$).
   - `direction = west (12)`: Gắp từ Tây ($X - 1$), thả sang Đông ($X + 1$).
2. **Hiện tượng Rơi đất (Spill to Ground) & Khóa Ô Đất (`cannot-place`)**:
   - Nếu Inserter có nguồn điện và có vật phẩm ở điểm gắp nhưng điểm thả chưa có entity tiếp nhận, Inserter sẽ thả vật phẩm rơi trực tiếp xuống mặt đất tạo thành entity `item-on-ground`.
   - Khả năng đặt đè phải kiểm tra bằng `can_place_entity` cho prototype/vị trí cụ thể; không coi đồ rơi là vật cản tuyệt đối.
3. **Kỹ thuật Cứu hộ Đất Trống bằng Inserter Nghịch đảo**:
   - Khi không có quyền lệnh admin để xóa item trên đất, Inserter có khả năng tự động gắp `item-on-ground` nếu xoay pickup position trùng với tọa độ vật phẩm rơi, nhấc vật phẩm trả lại băng chuyền và giải phóng mặt bằng sạch 100%.
4. **Cơ chế Kích hoạt Tiếp nhận Bình của Lab**:
   - Khi không có nghiên cứu nào đang chạy (`force.current_research = nil`), Lab có trạng thái `no_research_in_progress` và từ chối nhận mọi bình khoa học.
   - Khi công nghệ được kích hoạt (`--start <tech>`), Lab chuyển trạng thái sang `missing_science_packs` và ngay lập tức mở slot nhận tất cả các loại bình nằm trong công thức của công nghệ đó.
   - Inserter Daisy-Chain chỉ rút bình từ Lab nguồn khi Lab nguồn có lượng bình vượt ngưỡng buffer tối thiểu (đảm bảo Lab nguồn không bị gián đoạn).

### 7.3. Thử Nghiệm Băng Chuyền Ngầm (Underground Belt) & Định Luật Ghép Cặp (Pairing Law)
1. **Khoảng cách ngầm tối đa**: Băng chuyền ngầm vàng (`underground-belt`) có tầm ngầm tối đa đúng **4 ô đất trống ở giữa** (khoảng cách tâm giữa đầu vào và đầu ra tối đa là 5.0 tile).
2. **Cơ chế Ghép Cặp & Bẫy Đặt Lệnh Bridge Tool**:
   - `handle_place` trong `control.lua` hiện chỉ gọi `surface.create_entity { name = "underground-belt", position = pos, direction = direction, force = force }` mà **không truyền tham số `type = "input" | "output"`**.
   - Do đó, nếu đặt đầu vào với `direction = west` (12), rồi đặt tiếp đầu ra cũng với `direction = west` (12), Factorio engine sẽ hiểu đây là một hầm ngầm mới độc lập và tạo ra một đầu **INPUT thứ hai**. Kết quả: Cả 2 cái đều là INPUT chĩa về phía Tây, không kết nối được và dòng hàng bị tắc hoàn toàn.
   - **Cách đặt đã kiểm chứng trong tool mới**: Hai đầu dùng cùng hướng dòng chảy; đầu vào `type=input`, đầu ra `type=output`. Quan sát auto-flip cũ không được dùng làm luật của `create_entity`.
   - **Đo kiểm thực tế**: Đã thử nghiệm dòng sắt từ Rương #1180 $(163.5, -169.5) \to$ belt cấp $(161.5) \to$ chui ngầm tại $(160.5) \to$ trồi lên tại $(157.5) \to$ xả trơn tru 4 đĩa sắt vào belt đón hàng $(156.5, -169.5)$. Sau đó đã dọn sạch phế tích theo đúng sắc lệnh.

### Vá 8: Tham số `type` ("input" | "output") chỉ cho `underground-belt`
* **Hiện trạng**: `handle_place` bỏ qua tham số `type`, ép mọi entity ngầm phải phụ thuộc vào thuật toán auto-flip của engine vốn dễ bị lỗi khi đặt cùng chiều dòng chảy.
* **Đã sửa**: CLI `place --type input|output`, MCP `place(type=...)`; Lua kiểm tra loại entity trước khi trừ vật tư. Snapshot/receipt trả `belt_to_ground_type`. `pipe-to-ground` không có tham số này và bị từ chối nếu truyền nhầm. Test engine xác nhận hai belt có `neighbours` trỏ nhau; chưa bổ sung tự chọn/ghép cặp.

---

## 8. Generic Blueprint Acceptance & Holdout Criteria (PORTING.md §5)

Input schema contract for generic blueprint executor (`factorio_goal_mcp.py` + Lua executor core). Defines ground resource prerequisites, initial fueling/priming, and holdout audit metrics for `bp-f30d8a84af3098ee` (2 coal miners) and `bp-985eb5fc230538b4` (1:2 steam power station).

### 8.1. FLE Holdout Protocol Rules (`PORTING.md` §5)
* **Window Duration**: 60 seconds (`window_ticks = 3600` @ 60 ticks/s).
* **Intervention Freeze**: Audit starts immediately after last executor mutation (placement, wiring, primer insertion). Zero external inventory injection, cheat craft, or agent command during audit windows.
* **Window Loop**: Measure production / state window-by-window until non-increasing.
* **Terminal Condition (Pass/Fail)**: **LAST window MUST satisfy target metrics** (`last_window >= quota`). Prevents false PASS from depleting starter buffers.
* **Audit Receipt**: Store all window measurements verbatim in goal receipt.

---

### 8.2. Blueprint 1: `bp-f30d8a84af3098ee` — Coal Mining Outpost (2 Drills)

* **Schema Pattern ID**: `bp-f30d8a84af3098ee`
* **Entity Manifest (10 total)**:
  - `burner-mining-drill`: 2
  - `transport-belt`: 6
  - `burner-inserter`: 1
  - `wooden-chest`: 1
* **Relative Centers Span**: `[min_x: 0, min_y: 0]` to `[max_x: 7.0, max_y: 1.5]`.

#### A. Ground & Resource Contracts
| Requirement | Specification | Enforcement / Verification |
| :--- | :--- | :--- |
| **Ground Resource** | `coal` entity on resource layer | Both drills (2x2) mining footprint must sit 100% on `coal` resource tiles. |
| **Minimum Tile Amount** | $\ge 100$ per tile | Reject candidate site if any drill footprint tile has $< 100$ resource count. |
| **Total Patch Reserve** | $\ge 800$ coal per drill | Ensures outpost lifetime $> 53$ minutes continuous mining. |
| **Terrain / Collision** | Land, buildable | Zero water / cliff / obstacle collision across all 10 entity bounding boxes. |

#### B. Fuel Priming & Bootstrap Buffer
| Entity | Target Inventory | Fuel Type | Min Primer Count | Self-Sustaining Feed |
| :--- | :--- | :--- | :---: | :--- |
| `burner-mining-drill` #1 | `fuel` | `coal` / `wood` | $\ge 1$ (rec. 5) | No loop-back; runs on primer + buffer. Burn rate: 1 coal / 26.7s @ 150 kW. 5 coal = 133s run. |
| `burner-mining-drill` #2 | `fuel` | `coal` / `wood` | $\ge 1$ (rec. 5) | Same as drill #1. |
| `burner-inserter` | `fuel` | `coal` | $\ge 1$ | **Yes**; self-fuels automatically from coal on incoming belt when energy drops. |
| `wooden-chest` | `chest` | N/A | 0 | Destination container for produced coal. |

#### C. Numeric Holdout Acceptance Matrix (60s Window = 3600 Ticks)
* **Nominal Theoretical Production**:
  - Drill mining speed = $0.25\text{ items/s}$.
  - 2 drills = $0.50\text{ coal/s} \times 60\text{s} = 30\text{ coal/window}$.
  - Burner inserter consumption = $\sim 0.5 - 1.0\text{ coal/window}$ (self-fueling).
  - Theoretical net deposit to chest = $29\text{ coal/window}$.
* **Audit Acceptance Thresholds**:
  | Metric Key | Operator | Threshold Value | Failure Meaning |
  | :--- | :---: | :---: | :--- |
  | `layout_intact` | `==` | `true` | Entity destroyed, decommissioned, or missing. |
  | `entity_count` | `==` | `10` | Exact match with catalog manifest. |
  | `active_drills` | `==` | `2` | Drill status $\ne$ `working` (out of fuel or blocked output). |
  | `coal_gained` (per 60s window) | $\ge$ | **$20$** | Throughput choked, belt jam, or fuel starvation. |
  | `last_window.coal_gained` | $\ge$ | **$20$** | **Terminal holdout rule**: Must sustain $\ge 20$ in final window. |

---

### 8.3. Blueprint 2: `bp-985eb5fc230538b4` — Steam Power Column (1:2)

* **Schema Pattern ID**: `bp-985eb5fc230538b4`
* **Entity Manifest (5 total)**:
  - `boiler`: 1
  - `steam-engine`: 2
  - `burner-inserter`: 1
  - `iron-chest`: 1
* **Relative Centers Span**: `[min_x: 0, min_y: 0]` to `[max_x: 0.0, max_y: 11.0]`.

#### A. Ground, Fluid, Grid & Load Connection Contracts
| Requirement | Specification | Enforcement / Verification |
| :--- | :--- | :--- |
| **Terrain** | Land, buildable | 100% dry land under boiler (3x2), steam engines (3x5 x 2), inserter, chest. |
| **Fluid Source Input** | `water` | Boiler input port connected to offshore supply / pipe network. |
| **Water Supply Flow** | $\ge 60\text{ fluid/s}$ | Boiler maximum consumption rate at full 1.8 MW output = 60 water/s. |
| **Water Temperature** | $\le 25^\circ\text{C}$ (ambient) | Native fresh water input. |
| **Electric Network Link** | `electric-network` | Small/medium electric pole covering steam engine connection boxes. |
| **Declared Electric Load** | `declared_load_mw` | Blueprint declaration specifies connected grid load $\ge 0.1\text{ MW}$ (e.g. existing base load or dedicated test load like assemblers/radars/accumulators). Zero load produces zero actual power (`no power demand`). |

#### B. Fuel Priming & Bootstrap Buffer
| Entity | Target Inventory | Fuel Type | Min Primer Count | Consumption Dynamics |
| :--- | :--- | :--- | :---: | :--- |
| `iron-chest` | `chest` | `coal` | $\ge 50$ | Fuel depot for burner inserter. 50 coal sustains 1.8 MW full load for 111 seconds. |
| `burner-inserter` | `fuel` | `coal` | $\ge 1$ | Grabs coal from `iron-chest`, feeds boiler fuel box; self-fuels from chest. |
| `boiler` | `fuel` | `coal` | $\ge 5$ | Initial fuel buffer. Burn rate: 1.8 MW / 4 MJ = 0.45 coal/s = 27 coal / 60s window. |

#### C. Numeric Holdout Acceptance Matrix (60s Window = 3600 Ticks)
* **Real Production vs Nominal Capacity**:
  - Without load, steam engines idle (`generator.status == no_power_demand`), generating $0\text{ J}$.
  - Nominal capacity = $1.80\text{ MW}$ ($2 \times 900\text{ kW}$).
  - Audit target power: $P_{\text{target}} = \min(\text{declared\_load\_mw}, 1.80\text{ MW}) \times 0.95$.
  - Energy generated in 60s window: $E_{\text{window}} = \int_{t}^{t+60} P(t) dt$ queried from `network.electric_statistics.output_counts["steam-engine"]` or network energy production delta.
  - Required average window power: $P_{\text{avg}} = \frac{E_{\text{window}}}{60\text{s}} \ge P_{\text{target}}$.
* **Audit Acceptance Thresholds**:
  | Metric Key | Operator | Threshold Value | Failure Meaning |
  | :--- | :---: | :---: | :--- |
  | `layout_intact` | `==` | `true` | Entity missing or destroyed. |
  | `entity_count` | `==` | `5` | Exact match with catalog manifest. |
  | `boiler_temperature` | $\ge$ | **$165.0^\circ\text{C}$** | Insufficient heat; lack of fuel or water flow stall. |
  | `boiler_fuel_remaining` | $>$ | `0` | Fuel ran dry during window. |
  | `actual_power_output_mw` | $\ge$ | $\min(\text{load}, 1.80) \times 0.95$ | **Real runtime output**: Failed actual energy generation against declared load. |
  | `last_window.actual_power_output_mw` | $\ge$ | $\min(\text{load}, 1.80) \times 0.95$ | **Terminal holdout rule**: Real power production sustained through final window. |
  | `last_window.boiler_temperature` | $\ge$ | **$165.0^\circ\text{C}$** | No heat decay in terminal window. |
  | `last_window.boiler_fuel_remaining` | $>$ | `0` | Fuel supply sustained through terminal window. |

