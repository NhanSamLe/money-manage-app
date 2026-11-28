# Nền tảng "Cuộc sống" dùng chung backend MoMa (đề xuất, chờ CEO duyệt)

Trạng thái: **ĐỀ XUẤT** (2026-11-29). Chưa triển khai. Quyết định chính thức sẽ ghi vào `docs/decision-log.md` khi CEO duyệt.

## 1. Mục tiêu

Một app thứ hai (**LiMa** = Life Manage, anh em với MoMa = Money Manage; CEO chốt tên 2026-11-29; app quản lý thời gian, công việc, thói quen và đời sống) cùng **một tài khoản, một
backend, một Trợ lý** với MoMa. AI có cái nhìn tổng quát về chủ sở hữu (tiền, thời gian, ăn uống, học tập, sức khỏe) để
đề xuất và điều chỉnh lối sống. Chủ sở hữu chủ yếu **nhắn tin** để AI xây lịch trình; tự sửa khi muốn.

## 2. Kiến trúc

```
 MoMa (Android, tài chính) ─┐                     ┌─ Supabase Postgres
                            ├─ Cloudflare Worker ─┤   pf_*  (tài chính, đã có)
 LiMa (Android, cuộc sống) ─┘   moma-api          │   lf_*  (đời sống: lịch, việc, thói quen, nhật ký)
                                 /v1/...  (MoMa)   │   kn_*  (tri thức tóm tắt: giá vàng, chứng khoán, mẹo)
                                 /v1/life/...      │   ai_*  (hồ sơ & ghi nhớ chung của Trợ lý)
                                 /v1/knowledge/... └─ R2: ảnh/tệp; KV/Cache: dữ liệu thô tạm thời
                                 cron */15: tick tài chính + thu thập tri thức
```

- **Một Worker, chia module theo tiền tố route** (`/v1/life/*`, `/v1/knowledge/*`): dùng chung xác thực (Supabase,
  chủ sở hữu duy nhất), thiết bị, đẩy thông báo (OneSignal, hộp thông báo), giới hạn tốc độ, AI (DeepSeek, không cap D-015).
  Tách Worker riêng chỉ khi vượt giới hạn CPU/subrequest của gói miễn phí.
- **Bảng riêng theo tiền tố** (`lf_`, `kn_`), cùng quy tắc: RLS bật, chỉ service_role, RPC `security definer` +
  `assert_owner`, lệnh idempotent qua `pf_execute_command` (hoặc dispatcher `lf_execute_command` song song).
- **Trợ lý chung**: một bộ công cụ (tools.ts) phủ cả lệnh tài chính và đời sống; ghi nhớ/thói quen chuyển dần sang
  "hồ sơ chung" để LiMa và MoMa cùng học (vd: giờ ăn sáng → nhắc ghi chi + lịch ăn uống).
- **App LiMa**: Flutter riêng trong monorepo (`apps/life`), dùng chung package lõi (`packages/core`: auth, api client,
  offline cache, theme, trợ lý chat) tách ra từ `apps/android` khi bắt đầu.

## 3. Dữ liệu đời sống (lf_*) — phác thảo

| Bảng | Nội dung |
|---|---|
| `lf_event` | Lịch trình (giờ bắt đầu/kết thúc, loại: làm việc, học, ăn, di chuyển, nghỉ, thể thao…), nguồn: AI/tự tạo/lặp lại |
| `lf_task` | Việc cần làm, hạn, ưu tiên, liên kết mục tiêu |
| `lf_habit` / `lf_habit_log` | Thói quen và lần thực hiện (uống nước, ngủ, đọc sách, tập thể dục…) |
| `lf_log` | Nhật ký nhanh qua chat ("12h ăn cơm", "về nhà 18h, học tiếng Anh 1 tiếng") |
| `lf_goal` | Mục tiêu sống (học tập, sức khỏe, nghề nghiệp), liên kết mục tiêu tài chính khi có chi phí |

Liên kết chéo: một sự kiện "đi nhậu tối thứ 7" ở LiMa = một **dự toán sự kiện** ở MoMa (D-027) → thực tế tự gom.

## 4. Tri thức thế giới (kn_*) — nguyên tắc

- Thu thập bằng cron trên Worker; **dữ liệu thô không vào database** (chỉ ở bộ nhớ đệm tạm KV/Cache).
- AI đọc sơ bộ, chỉ lưu mục ngắn, hữu ích, đã khử trùng: `kn_item(type, title, summary ≤ 300 ký tự, numbers jsonb,
  source_url, valid_until, tags)`; số liệu thị trường lưu dạng chuỗi thời gian gọn `kn_price(symbol, at, value)`.
- Phục vụ: giá vàng/tỷ giá/chứng khoán cho MoMa (quan sát, dự báo đơn giản, có ghi rõ "không phải lời khuyên đầu tư"),
  lạm phát/giá nhà cho kế hoạch dài hạn, mẹo học tập/sức khỏe/lối sống cho LiMa.
- Nguồn dữ liệu cụ thể: chờ báo cáo nghiên cứu `docs/research/market-data-sources.md`.

## 4b. Ngân sách và lịch thu thập tri thức (CEO duyệt trần ~100 tin/ngày, 2026-11-29)

Nguyên tắc **"đọc nhiều tiêu đề, lưu rất ít"**: chỉ đọc tiêu đề + mô tả ngắn từ RSS (không tải bài), lọc trùng bằng băm
link, xếp hạng theo mối quan tâm của chủ sở hữu (tài chính cá nhân, vàng, lãi suất, chứng khoán theo dõi, học tập, sức
khỏe, nghề nghiệp — học dần từ những mục được mở/lưu/bỏ qua), rồi AI chỉ tóm tắt các mục đứng đầu.

| Lượt (giờ VN) | Vì sao giờ này | Đọc (tối đa) | AI tóm tắt & lưu |
|---|---|---|---|
| **06:30** bản tin sáng | Tin đêm qua + thế giới; trước giờ đi làm; ngoài giờ cao điểm DeepSeek | ~40 tiêu đề | 5–6 mục |
| **11:30** trưa | Giá vàng/tỷ giá đã điều chỉnh buổi sáng; giờ nghỉ trưa | ~25 tiêu đề + giá | 3–4 mục |
| **17:30** chiều tối | Sau đóng cửa chứng khoán (15:00); giá vàng chốt chiều; trên đường về | ~35 tiêu đề + chứng khoán | 5–6 mục |
| Tổng/ngày | | **≤ 100** | **~15 mục** |

- Số liệu thị trường (vàng, tỷ giá, VN-Index, mã theo dõi) không cần AI: tính bằng công thức, lưu 1 ảnh chụp/ngày;
  AI chỉ viết 1 câu giải thích khi có biến động đáng kể (vd vàng ±1,5%/ngày).
- Hạn lưu: tin thời sự 7 ngày; mục chủ sở hữu bấm "Lưu" hoặc mẹo học tập/sức khỏe "dùng lâu dài" giữ đến khi xóa;
  số liệu thị trường theo ngày giữ 2 năm, sau đó gộp theo tháng (chính sách vòng đời D-028).
- Chạy bằng GitHub Actions cron (miễn phí), gửi kết quả gọn về API; cuối tuần chỉ 2 lượt (08:00, 18:00), không có chứng khoán.
- Chi phí AI ước tính: ~100 tiêu đề × ~60 token + 15 bản tóm tắt × ~120 token/ngày ≈ 0,3 triệu token/tháng → **< 0,1 USD/tháng**
  (giờ thấp điểm).

## 4c. Nguồn tin cậy và bộ lọc do AI tự điều chỉnh (CEO yêu cầu 2026-11-29)

**Phân tầng nguồn (chỉ lấy từ danh sách được duyệt; mỗi mục lưu kèm tầng và link gốc):**

| Tầng | Nguồn | Dùng cho |
|---|---|---|
| 1 · Chính thống | Ngân hàng Nhà nước (lãi suất điều hành, tỷ giá trung tâm), Cục Thống kê/NSO (CPI, GDP), Bộ Tài chính, Bộ Y tế, Bộ GD&ĐT, Chính phủ (chinhphu.vn, văn bản luật), WHO, Vietcombank (tỷ giá), sở giao dịch (HOSE/HNX qua nguồn dữ liệu đã nghiên cứu) | Số liệu, chính sách, quy định, sức khỏe |
| 2 · Báo chí lớn, kiểm chứng tốt | VnExpress, Tuổi Trẻ, Thanh Niên, VnEconomy, Báo Đầu tư, VietnamPlus/TTXVN, Dân trí | Tin thời sự, kinh tế, đời sống |
| 3 · Chuyên ngành | CafeF/CafeBiz (thị trường), PNJ/BTMC (giá vàng), nguồn học tập uy tín | Thị trường, mẹo, kiến thức |

- Không dùng mạng xã hội, diễn đàn, trang tổng hợp không rõ nguồn, nội dung quảng cáo/PR (AI gắn cờ "bài PR" và loại).
- **Kiểm chứng chéo**: tin có số liệu/chính sách chỉ được lưu khi đến từ tầng 1, hoặc ≥ 2 nguồn tầng 2 cùng đưa; tin chỉ
  có 1 nguồn tầng 2–3 được ghi "chưa kiểm chứng" hoặc bỏ qua tùy mức quan trọng. Số liệu luôn ưu tiên con số gốc tầng 1.
- Danh sách nguồn là dữ liệu (bảng cấu hình), sửa được không cần phát hành app; AI chỉ được **đề xuất** thêm nguồn mới,
  chủ sở hữu duyệt một chạm.

**Bộ lọc thích nghi do AI quản lý:**
- **Hồ sơ quan tâm** (trong ghi nhớ của Trợ lý): chủ đề + trọng số + từ khóa, khởi tạo từ dữ liệu thật (vd đang tiết
  kiệm mua nhà → lãi suất vay, giá căn hộ; có mục tiêu học → học bổng/kỹ năng; hay ăn ngoài → an toàn thực phẩm).
- Mỗi tuần AI xem tín hiệu (mục được mở, lưu, bỏ qua, câu hỏi trong chat, mục tiêu/kế hoạch mới) rồi **tự chỉnh** trọng
  số, thêm/bớt từ khóa và **truy vấn tìm kiếm động** (vd tuần sau có kế hoạch du lịch Đà Lạt → thời tiết, giá vé, lễ hội).
  Thay đổi được ghi lại, chủ sở hữu xem/hoàn tác trong trang Ghi nhớ.
- Ngoài RSS cố định, AI dùng **công cụ tìm kiếm web phía máy chủ của DeepSeek** (không tính phí theo lượt từ 18/11/2026,
  chỉ tính token kết quả) cho các truy vấn động, **giới hạn trong tên miền của danh sách nguồn** và trần ~100 tiêu đề/ngày.
- Chấm điểm mỗi tiêu đề: liên quan (theo hồ sơ) × độ tin cậy (tầng) × độ mới × tính mới (khử trùng theo sự kiện, không chỉ
  theo link) → chỉ ~15 mục/ngày được tóm tắt.

## 4d. Tin tức ≠ Tri thức (CEO 2026-11-29)

| | **Tin tức** (đọc trong ngày) | **Tri thức** (app dùng lâu dài) |
|---|---|---|
| Ví dụ | Tin IT, thời sự, kinh tế, đời sống | Giá vàng/tỷ giá/VN-Index theo ngày, lãi suất, CPI, giá nhà — đầu vào cho dự toán, kế hoạch dài hạn |
| Lưu ở đâu | **Không vào Postgres.** Bản tin của lượt chạy = 1 khóa Workers KV có `expirationTtl` 48 giờ (1 lần ghi/lượt, xa dưới giới hạn 1.000 ghi/ngày); app giữ bản sao offline trong SQLite tối đa 2 ngày | Bảng `kn_*` gọn, theo chính sách vòng đời D-028 |
| Ghi nhớ học được | Chỉ lưu **hồ sơ quan tâm** (chủ đề/từ khóa/trọng số) trong ghi nhớ Trợ lý, không lưu bài | — |

**Chuyên mục IT (chủ sở hữu đang học IT):** bản tin IT riêng mỗi ngày (~6–8 mục trong ~15 mục/ngày), ưu tiên theo những gì
đang học/dùng (khởi tạo từ chính stack của MoMa: Flutter/Dart, Android/Kotlin, TypeScript, Cloudflare Workers, Postgres/
Supabase, AI/LLM), AI tự chỉnh theo câu hỏi/học tập của chủ sở hữu.

| Tầng | Nguồn IT |
|---|---|
| 1 · Chính thức | Blog/changelog chính thức: Flutter, Dart, Android Developers, Kotlin, TypeScript, Node.js, Cloudflare, Supabase, PostgreSQL, GitHub; thông báo bảo mật (CVE/GitHub Security Advisories) cho thư viện đang dùng |
| 2 · Báo công nghệ uy tín | VnExpress Số hóa, VietNamNet ICT (ICTnews), The Verge, Ars Technica, TechCrunch, InfoQ |
| 3 · Cộng đồng có chọn lọc | Hacker News (chỉ mục điểm cao, AI lọc), dev.to/Medium **chỉ** khi trùng chủ đề đang học và có tác giả/nguồn rõ ràng |

Mục "Học hôm nay": 1 khái niệm/mẹo ngắn gắn với chủ đề đang học (có link tài liệu chính thức) — cũng là tin tức, hết hạn
48 giờ trừ khi chủ sở hữu bấm "Lưu" (khi đó lưu tiêu đề + 2 câu + link vào sổ tay học tập của LiMa).

## 5. Lộ trình đề xuất

1. **MoMa 1.2.0** (đang hoàn tất), **Kế hoạch & Dự toán** (đang làm).
2. **Tri thức P1**: giá vàng + tỷ giá + lãi suất → kế hoạch dài hạn và quan sát đầu tư trong MoMa.
3. **Tách package lõi** `packages/core` từ `apps/android` (không đổi hành vi MoMa).
4. **LiMa MVP**: chat → lịch trình, nhật ký nhanh, thói quen, gợi ý cải thiện hằng tuần; dùng chung Trợ lý.
5. **Tri thức P2**: chứng khoán, tin kinh tế, mẹo học tập/sức khỏe; báo cáo "toàn cảnh" tuần (tiền + thời gian).

## 6. Rủi ro

- Giới hạn gói miễn phí Cloudflare (CPU 10 ms/lần, 50 subrequest). **CEO quyết định 2026-11-29: chỉ dùng gói miễn phí,
  không trả 5 USD.** Việc nặng (thu thập tri thức, tóm tắt AI, quét lớn) chạy bằng **GitHub Actions cron** (repo công khai,
  miễn phí) rồi gửi kết quả gọn về API qua endpoint nội bộ có `x-cron-secret`; Worker chỉ phục vụ app. Giữ backend dễ
  chuyển nhà (Postgres thuần, HTTP chuẩn) để có thể sang host miễn phí khác nếu cần.
- Điều khoản sử dụng nguồn tin/giá: chỉ lưu tóm tắt + link, tôn trọng ToS (xem báo cáo nghiên cứu).
- Dữ liệu đời sống nhạy cảm hơn tài chính: giữ nguyên chuẩn chủ sở hữu duy nhất, không chia sẻ ra ngoài.
