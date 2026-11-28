# Dung lượng, vòng đời dữ liệu và chi phí AI (D-028)

Chủ sở hữu chỉ trả tiền cho **AI (DeepSeek)**. Mọi thứ khác ở gói miễn phí và giữ như vậy lâu dài: Supabase Free
(Postgres 500 MB / dự án), Cloudflare Workers Free (100k request/ngày, 10 ms CPU, ~50 subrequest/lần), R2 miễn phí
(10 GB), GitHub Actions (repo công khai, phút chạy miễn phí). Số liệu nền tảng kiểm tra ngày 2026-11-29.

## 1. Chính sách giữ dữ liệu (migration 022, bảng `pf_private.retention_policy`)

Chạy mỗi đêm 03:30 giờ VN theo **lô có giới hạn** (LIMIT mỗi bảng, lặp tới khi hết), nên không bao giờ khóa DB lâu và
vừa trong giới hạn của Worker. Việc nặng chạy ở GitHub Actions (`.github/workflows/moma-maintenance.yml` →
`POST /v1/internal/maintenance`, có `x-cron-secret`); cron 15 phút của Worker chỉ chạy 1 lô/đêm làm dự phòng.
Bảng mới (4Life `lf_*`, tri thức `kn_*`) chỉ cần thêm một dòng chính sách; dòng nào trỏ tới bảng/cột chưa có thì bị bỏ qua.

| Dữ liệu | Hành động | Sau | Vì sao |
|---|---|---|---|
| Sổ cái `pf_tx` / `pf_journal` / `pf_entry` | **Giữ mãi** | — | Sự thật tài chính, chỉ ghi thêm |
| Tài khoản, danh mục, người quen, công nợ + lần trả, mục tiêu, ngân sách, định kỳ, chia hóa đơn | **Giữ mãi** | — | Dữ liệu cốt lõi |
| Ghi nhớ của Trợ lý `pf_ai_memory`, quyết định ghép/không trùng | **Giữ mãi** | — | Giá trị đã học; chống đề xuất lại |
| Metadata ảnh chứng từ (ảnh nằm trên R2) | **Giữ mãi** | — | Bằng chứng |
| `pf_month_stat` (chưng cất), ảnh chụp dung lượng | **Giữ** | 2 năm (snapshot) | Lịch sử gọn, rẻ để đọc |
| `pf_inbound_event` (webhook ngân hàng) | Nén payload | 90 ngày | Chỉ giữ mã tham chiếu, số tiền, thời điểm, 4 số cuối, nội dung ≤ 200 ký tự (đúng thứ ghép chuyển khoản đọc) |
| `pf_tx_classification` APPLIED/SUGGESTED | Bỏ lời giải thích | 180 ngày | Giữ quyết định |
| `pf_ai_usage` | Gộp theo tháng/model/tính năng → `pf_ai_usage_month` | 90 ngày | Thống kê chi phí còn nguyên |
| `pf_audit` | Gộp số lượng theo tháng → `pf_audit_month` | 365 ngày | |
| `pf_command` (kết quả idempotency) | Xóa | 60 ngày | Outbox offline giữ lệnh ≤ 30 ngày; dư 30 ngày an toàn |
| `pf_change` (feed đồng bộ) | Xóa | 30 ngày | Không ai đọc lịch sử; app làm mới toàn bộ |
| `pf_push_log` (khóa chống gửi trùng) | Xóa | 90 ngày | Khóa dài nhất theo tháng |
| `pf_notification` đã đọc | Xóa | 120 ngày | Chưa đọc thì giữ; vẫn giới hạn 500 mục |
| `pf_job` DONE/DEAD, `pf_rate_limit` hết hạn, `pf_reminder_skip`, nhận xét theo ngày, đề xuất mục tiêu đã bỏ qua | Xóa | 14–180 ngày | Hết tác dụng |
| `kn_item` (tri thức, tương lai) | Xóa | khi `valid_until` qua | Dữ liệu thô không bao giờ vào DB |
| Ảnh R2 không còn dòng nào trỏ tới | Xóa | > 1 ngày | Quét mồ côi theo trang, tối đa 15 lần xóa/trang |

**Chưng cất trước khi xóa:** mỗi tháng đã khóa sổ được tính vào `pf_month_stat` (số giao dịch, tổng, trung bình, trung
vị theo danh mục và tổng theo loại) từ chính sổ cái: giao dịch bị hủy tự triệt tiêu, hóa đơn chia chỉ tính phần của chủ
sở hữu. 10 ngày đầu tháng mới tính lại tháng trước một lần/ngày (giao dịch ghi muộn). Trợ lý/báo cáo đọc qua
`pf_month_stats` thay vì quét chi tiết.

Xóa xong thì autovacuum của Supabase tái sử dụng chỗ trống (không cần VACUUM thủ công; RPC trong transaction cũng không
gọi được VACUUM).

## 2. Đo thực tế (e2e `lifecycle.e2e.test.ts`, Postgres 17)

1.000 giao dịch thật qua `pf_execute_command` (bút toán, dòng sổ cái, idempotency, feed đồng bộ), kèm 2 webhook ngân
hàng đầy đủ:

| | Tổng các bảng liên quan | Mỗi giao dịch |
|---|---|---|
| Trước chính sách | 2,19 MB | **≈ 2,2 KB** |
| Sau chính sách (sau VACUUM FULL để đo phần dữ liệu sống) | 1,25 MB (tính cả phần nền) | **≤ 1,25 KB** |

Tức là giảm ~50% phần phình theo thời gian; phần còn lại là sổ cái + chỉ mục, được giữ mãi.

## 3. Dự báo dùng được bao lâu (gói miễn phí)

Giả định một người dùng: 15 giao dịch/ngày (ghi tay + thông báo + ngân hàng) ≈ 5.500/năm.

| | Tăng / năm | Tới 80% (400 MB), trừ ~30 MB nền hệ thống |
|---|---|---|
| Có chính sách (≈ 1,25 KB/gd + ~0,5 KB dữ liệu kèm) | ≈ 9–10 MB | **≈ 35–40 năm** |
| Không dọn (≈ 2,2 KB + payload/command/audit không giới hạn) | ≈ 20 MB | ≈ 18 năm |
| Dùng rất nhiều (50 gd/ngày) có chính sách | ≈ 32 MB | ≈ 11–12 năm |

Ảnh R2: ~200 KB/ảnh sau nén. 2 ảnh/ngày ≈ 146 MB/năm → 10 GB đủ ~68 năm; 10 ảnh/ngày → ~14 năm.

Con số thật được đo mỗi tuần (`pf_capacity_snapshot`), màn hình **Cài đặt → Dung lượng & chi phí** hiển thị dự báo
"Đủ dùng ~N năm" từ độ dốc 13 tuần gần nhất, và đẩy cảnh báo một lần khi chạm 60% và 80%.

**Khi chạm 80% (chỉ phương án miễn phí, theo quyết định chủ sở hữu):**
1. Siết chính sách (rút ngắn các mốc ở bảng trên, bỏ thêm chi tiết phụ).
2. Lưu trữ các năm đã khóa sổ sang R2 dạng JSONL nén (gzip), đọc lại khi cần; trong DB chỉ giữ `pf_month_stat` và số dư
   đầu kỳ của năm. (Mô tả, chưa xây.)
3. Chuyển sang một máy chủ Postgres miễn phí khác: schema lõi là Postgres thuần (không dùng tính năng riêng của Supabase
   trong bảng lõi), `pg_dump`/`pg_restore` được nguyên vẹn.

## 4. Chi phí AI (khoản duy nhất có phí)

Giá chính thức `deepseek-flash` (USD / 1 triệu token, kiểm tra 2026-11-29): cache hit 0,003 / miss 0,15 / output 0,6
giờ thấp điểm; gấp đôi giờ cao điểm (01–04 và 06–10 UTC = 08–11 và 13–17 giờ VN, thứ Hai–thứ Sáu).

### Các sửa đổi tiết kiệm (đã làm, có test `test/unit/ai-cost.test.ts`)
- **Tắt chế độ "suy nghĩ"** (`thinking: {type: "disabled"}`) cho mọi lệnh gọi. `deepseek-flash` mặc định bật suy nghĩ
  và tính token suy luận ẩn như output (phần đắt nhất), lại chậm thêm vài giây. Trước đây MoMa không gửi tham số này.
- **Tiền tố ổn định cho bộ nhớ đệm**: system prompt (cả danh sách công cụ của agent) không chứa ngày giờ/dữ liệu riêng;
  trong phần dữ liệu, thứ ít đổi (danh mục, tài khoản, người quen, mục tiêu; danh mục + ví dụ của bộ phân loại) đứng
  trước, thứ theo từng yêu cầu (hôm nay, kế hoạch trước, hội thoại, câu nói) đứng sau. DeepSeek tự cache tiền tố trùng →
  phần lớn input tính giá cache (~50 lần rẻ hơn). Danh sách công cụ của agent vì vậy gửi lại mỗi lượt gần như miễn phí,
  không cần mô tả lười (sẽ tốn thêm vòng gọi).
- **Quy tắc trước, AI sau**: bộ phân loại dùng ghi nhớ → lịch sử → từ điển, chỉ gọi AI khi chưa chắc; webhook ngân hàng
  không gọi AI; nội dung trùng nhau trong một lượt quét chỉ gọi AI **một lần** (memo theo chữ ký nội dung).
- **Giới hạn output** theo việc: phân loại 120, hóa đơn 400, nhận xét 700, ghi nhớ 500, agent 1.400 token.
- **Việc nền chạy giờ thấp điểm**: dọn dữ liệu 03:30, ghi nhớ thói quen sau 23:00, nhận xét buổi tối, tri thức (tương
  lai) xếp vào khung thấp điểm.
- **Ghi đúng chi phí**: mỗi lượt gọi được tính theo token cache hit/miss thật và giá đúng khung giờ, gắn nhãn tính năng
  (`pf_ai_usage.feature`) → màn hình chi phí theo tính năng.

### Ước tính mỗi lượt (đo kích thước prompt thật; ~2,8 byte/token tiếng Việt)
| Lượt gọi | Input (cache / miss) | Output | Thấp điểm | Cao điểm |
|---|---|---|---|---|
| Agent chat (system 15,5 KB ≈ 5.500 tok, dữ liệu 5,3 KB ≈ 1.900 tok) | ~6.400 / ~1.000 | ~250 | ≈ $0,00032 | ≈ $0,00064 |
| Phân loại (0,7 + 1,4 KB) | ~640 / ~90 | ~40 | ≈ $0,00004 | ≈ $0,00008 |
| Đọc hóa đơn | ~0 / ~1.500 | ~200 | ≈ $0,00035 | ≈ $0,0007 |
| Nhận xét ngày/tuần/tháng | ~0 / ~1.200 | ~400 | ≈ $0,0004 | — (buổi tối) |
| Ghi nhớ thói quen (đêm) | ~0 / ~2.000 | ~400 | ≈ $0,00054 | — |

### Một tháng của một người
| Hạng mục | Khối lượng | Chi phí |
|---|---|---|
| Chat với Trợ lý (20 lượt/ngày, ~1,3 lần gọi/lượt, 40% giờ cao điểm) | ~780 lần gọi | ≈ $0,35 |
| Phân loại bằng AI (sau các lớp quy tắc) | ~150 | ≈ $0,01 |
| Hóa đơn | ~30 | ≈ $0,015 |
| Nhận xét + ghi nhớ | ~65 | ≈ $0,03 |
| Kế hoạch/dự toán | vài lần | < $0,01 |
| Tri thức tóm tắt (tương lai, 2 lô/ngày thấp điểm) | ~60 | ≈ $0,09 |
| **Tổng** | | **≈ $0,45–0,5 / tháng (~12–13 nghìn đồng)** |

Dùng rất nhiều (50 lượt chat/ngày, nhiều giờ cao điểm): ≈ $1,2/tháng (~30 nghìn đồng). Trước các sửa đổi (bật suy nghĩ
mặc định, không tận dụng cache): ước ≈ 2–3 lần.
