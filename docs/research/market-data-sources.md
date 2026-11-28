# Nguồn dữ liệu thị trường & kiến thức cho MoMa (research)

- Ngày khảo sát: **29/11/2026**. Probe bằng `curl` từ máy owner (IP dân dụng VN), **chưa** probe từ Cloudflare Worker.
- Phạm vi: vàng, chứng khoán VN, tỷ giá, CPI, lãi vay mua nhà, giá căn hộ, tin tức/kiến thức; tính khả thi trên Workers Free + chi phí DeepSeek.
- Ký hiệu: ✅ probe OK · ⛔ bị chặn (Cloudflare challenge / WAF) · ⚠️ không chính thức (endpoint nội bộ của web/app, không có ToS công khai cho API).

> Kết luận chính: **không có API chính thức, miễn phí, có ToS rõ ràng** cho giá vàng VN, giá cổ phiếu VN, lãi vay hay giá nhà. Gần như mọi nguồn "dùng được" là endpoint nội bộ của website. Vì vậy thiết kế phải coi mỗi nguồn là **không ổn định**: luôn có fallback, lưu lại giá trị cuối cùng tốt (last-known-good), và để AI/heuristic đánh dấu "dữ liệu cũ".

---

## 1. Giá vàng

| Nguồn | Endpoint (đã thử) | Kết quả 29/11/2026 | Định dạng / đơn vị | Ghi chú |
|---|---|---|---|---|
| **PNJ** | `GET https://edge-api.pnj.io/ecom-frontend/v1/get-gold-price?zone=00` | ✅ 200, có `updateDate` 28/11/2026 15:14 | JSON; `giamua/giaban` = **nghìn đồng/chỉ** (SJC 13.100/13.600 → 131–136 tr/lượng); có cả SJC, nhẫn trơn, 18K… | ⚠️ endpoint frontend ecom. Không auth, không cookie. Tốt nhất về cấu trúc. |
| **BTMC** (Bảo Tín Minh Châu) | `GET https://api.btmc.vn/api/BTMCAPI/getpricebtmc?key=3kd8ub1llcg9t45hnoh8hmn7t5kc2v` | ✅ 200 (HTTPS; HTTP thì timeout) | JSON; `@pb_n` mua / `@ps_n` bán, **đồng/chỉ**; `@pt_n` = giá thế giới; có SJC, VRTL, nhẫn tròn | ⚠️ key công khai nhúng trong widget của BTMC, có thể bị đổi bất kỳ lúc nào. Trường đánh số `@n_1..n` — parse theo tên, không theo vị trí. |
| **SJC** | `sjc.com.vn/GoldPrice/Services/PriceService.ashx`, `sjc.com.vn/xml/tygiavang.xml` | ⛔ 403 "Just a moment…" (Cloudflare challenge) | — | Không lấy trực tiếp được nếu không dùng trình duyệt. Giá SJC đã có trong PNJ và BTMC. |
| **DOJI** | `banggia.doji.vn/api/giavang/?api_key=…` (key cũ lan truyền) | ⛔ 403 | XML (cũ) | Không có API công khai; cần liên hệ DOJI. Bỏ qua. |
| **XAU thế giới: gold-api.com** | `GET https://api.gold-api.com/price/XAU` | ✅ 3.650 USD/oz, `updatedAt` 28/11/2026 17:04Z | JSON | Free, không cần key, docs ghi "không giới hạn request real-time" ([docs](https://gold-api.com/docs)). ToS chưa đọc được nội dung. |
| **XAU fallback: Yahoo Finance** | `GET https://query1.finance.yahoo.com/v8/finance/chart/GC=F?range=5d&interval=1d` | ✅ 200 | JSON (giá futures COMEX, không phải spot) | ⚠️ API không chính thức, ToS Yahoo cấm dùng tự động/thương mại; có lịch sử bị chặn theo IP. Chỉ fallback. |
| goldprice.org | `data-asg.goldprice.org/dbXRates/USD` | ⛔ 403 | — | Bỏ. |
| vapi.vnappmob.com | `/api/gold/sjc`, `/api/gold/doji` | Không thử; docs ghi **deprecated**, xin key qua email ([docs](https://vapi-vnappmob.readthedocs.io/en/latest/gold.html)) | — | Không dùng. |

Tần suất cập nhật thực tế: các tiệm thay giá vài lần/ngày trong giờ làm việc (PNJ cập nhật lúc 15:14, BTMC lúc 15:xx ngày 28/11). **Poll 30–60 phút trong 8h–17h giờ VN là đủ**, ngoài giờ 1 lần.

**Đề xuất:** Primary = PNJ (vàng VN: SJC + nhẫn) + gold-api (XAU). Fallback = BTMC (cả hai: có SJC và `@pt` thế giới) → Yahoo GC=F cho XAU. Tự tính **chênh lệch SJC vs thế giới quy đổi** (XAU × tỷ giá VCB bán × 37,5/31,1035) — đây là chỉ báo hữu ích nhất cho người mua vàng.

---

## 2. Chứng khoán Việt Nam

| Nguồn | Endpoint (đã thử) | Kết quả | Auth | Ghi chú |
|---|---|---|---|---|
| **VNDirect finfo** | `GET https://api-finfo.vndirect.com.vn/v4/stock_prices?q=code:FPT&sort=date&size=1` | ✅ FPT 27/11/2026 đóng cửa 44,6 | Không | ⚠️ Giá EOD từng mã (đơn vị nghìn đồng), có `ratios`… (cần tham số `order`). **Bắt buộc `sort=date`**, không thì trả dữ liệu 2018. Host cũ `finfo-api.vndirect.com.vn` đã chết. |
| **VNDirect dchart** | `GET https://dchart-api.vndirect.com.vn/dchart/history?resolution=D&symbol=VNINDEX&from=…&to=…` | ✅ OHLC VN-Index | Không | ⚠️ Định dạng TradingView UDF. Dùng cho VNINDEX/HNX/UPCOM và mã lẻ. |
| **DNSE / Entrade** | `GET https://services.entrade.com.vn/chart-api/v2/ohlcs/index?symbol=VNINDEX&resolution=1D&from=…&to=…` (mã lẻ: `/ohlcs/stock`) | ✅ | Không | ⚠️ Fallback tốt cho OHLC. |
| **SSI iBoard** | `GET https://iboard-query.ssi.com.vn/stock/FPT` | ✅ (giá trần/sàn/tham chiếu, thông tin mã) | Không | ⚠️ endpoint web iBoard. |
| **Vietcap (VCI)** | `POST https://trading.vietcap.com.vn/api/chart/OHLCChart/gap-chart` body `{"timeFrame":"ONE_DAY","symbols":["VNINDEX"],"to":<unix>,"countBack":3}` | ✅ | Không | ⚠️ Nguồn chính của vnstock; vnstock ghi VCI không chạy từ Google Cloud (Colab/Kaggle) → **có thể chặn IP datacenter, cũng có thể chặn Cloudflare**. |
| TCBS | `apipubaws.tcbs.com.vn/...` | ⛔ 403 Cloudflare challenge | — | vnstock đã đánh dấu TCBS **deprecated**, gỡ ở v3.5.0 ([pypi vnstock](https://pypi.org/project/vnstock/)). Bỏ. |
| Fireant | `restv2.fireant.vn/symbols/FPT/fundamental` | 401 | Bearer token | Cần tài khoản/token. Bỏ. |
| **SSI FastConnect Data** (chính thức) | REST + streaming | Không thử | ConsumerID/Secret + PrivateKey | Chính thức, có SLA. **Yêu cầu tài khoản chứng khoán SSI**, đăng ký tại quầy/bưu điện/môi giới, hiệu lực 1 năm, có thể đăng ký IP cố định ([guide SSI](https://guide.ssi.com.vn/ssi-products/tieng-viet/fastconnect-data)). Phí chưa xác nhận được. Lưu ý: Worker **không có IP cố định**. |
| vnstock (thư viện Python) | — | — | Guest 20 req/phút, key Community 60 req/phút | Là Python, không chạy trong Worker; chỉ hữu ích để tham khảo endpoint. |
| Toàn cầu (tuỳ chọn) | Yahoo `v8/finance/chart/^GSPC`, `^DJI`… | ✅ (cùng host với GC=F) | Không | ⚠️ như trên. Phương án chính thức free: Alpha Vantage / Financial Modeling Prep (cần key, giới hạn ngày thấp) — chưa verify trong đợt này. |

**Đề xuất:** Primary = VNDirect (`dchart` cho chỉ số + OHLC, `finfo` cho EOD/ratio từng mã trong watchlist). Fallback = DNSE Entrade chart-api. Tần suất: **EOD 1 lần ~15h15 giờ VN (08:15 UTC) T2–T6** cho watchlist ≤ 20 mã; tuỳ chọn 1 lần giữa phiên (~11h30). App này là quan sát/dự báo đơn giản, không cần realtime.

"Dự báo đơn giản" nên làm **tất định trong code** (MA20/MA50, % thay đổi tuần/tháng, độ biến động, khoảng cách tới đỉnh 52 tuần), AI chỉ diễn giải số đã tính, kèm disclaimer "không phải khuyến nghị đầu tư". Không cho LLM tự đưa ra giá mục tiêu.

---

## 3. Tỷ giá, CPI, lãi vay, giá nhà

| Loại | Nguồn | Kết quả | Ghi chú |
|---|---|---|---|
| **Tỷ giá** primary | Vietcombank `GET https://portal.vietcombank.com.vn/Usercontrols/TVPortal.TyGia/pXML.aspx` | ✅ XML, `DateTime` 11/29/2026; Buy/Transfer/Sell ~20 ngoại tệ | Trong XML có comment: **"For reference only. Only one request every 5 minutes!"** → poll 1–2 lần/giờ là thoải mái. Số có dấu phẩy ngàn ("16,761.24"). |
| Tỷ giá fallback | `GET https://open.er-api.com/v6/latest/USD` (ExchangeRate-API free) | ✅ có VND, cập nhật 1 lần/ngày | Free, không key, yêu cầu ghi nguồn ([terms](https://www.exchangerate-api.com/terms)). Là tỷ giá thị trường quốc tế, không phải giá ngân hàng VN. |
| Tỷ giá trung tâm NHNN | `sbv.gov.vn/...` | ⛔ "Request Rejected" (WAF F5) | Không máy đọc được. Bỏ. |
| **CPI / lạm phát** | Cục Thống kê `GET https://www.nso.gov.vn/feed/` (WordPress RSS; GSO cũ → NSO) | ✅ RSS; báo cáo CPI tháng ra dạng **PDF** khoảng ngày 6 tháng sau (vd. [PDF tháng 10/2026](https://www.nso.gov.vn/wp-content/uploads/2026/11/CPI-chi-so-gia-vang-va-chi-so-gia-do-la-My-thang-Muoi-va-10-thang-nam-2026.pdf)) | Không có API. Cách làm: 1 lần/ngày quét RSS tìm bài có "CPI", lấy title+excerpt, AI trích 3 số (CPI so tháng trước, so cùng kỳ, bình quân YTD) → lưu 1 dòng/tháng. Số tham chiếu: 10T/2026 CPI bình quân +4,57%, lạm phát cơ bản +4,24% ([Nhân Dân](https://nhandan.vn/10-thang-nam-2026-cpi-tang-457-so-voi-cung-ky-post999862.html)). Có thể nhập tay 1 lần/tháng — chỉ 12 dòng/năm. |
| **Lãi vay mua nhà** | Không có nguồn máy đọc được. Các bank công bố trên web/PDF, mức ưu đãi thay đổi theo gói. Báo chí tổng hợp định kỳ (vd. [CafeF 15/11/2026](https://cafef.vn/lai-vay-mua-nha-hien-tai-la-bao-nhieu-188261115071446931.chn): VCB ~9%/12 tháng đầu, BIDV 9–10% cố định 12–24 tháng, Agribank NOXH <35 tuổi 6,5%) | Đề xuất: **bảng tham chiếu nhập tay** (owner sửa 1 lần/quý) + AI trích từ tin RSS CafeF "tài chính - ngân hàng" khi có bài lãi suất, chỉ gợi ý cập nhật, không tự ghi đè. Luôn tính kịch bản lãi **thả nổi sau ưu đãi** (~10–12%). |
| **Giá căn hộ** | Không có chỉ số mở dạng máy đọc. Bộ Xây dựng công bố báo cáo quý (văn bản), các bên tư vấn (CBRE, Knight Frank, One Mount, Batdongsan) công bố qua báo chí, số liệu lệch nhau | Đề xuất: AI trích từ tin RSS (kinh doanh/bất động sản), lưu **1 dòng/quý/thành phố** (giá sơ cấp TB tr/m², % QoQ, nguồn). Vd. Q3/2026 HN nội đô sơ cấp ~102 tr/m², −6% QoQ ([Thời báo Tài chính](https://thoibaotaichinhvietnam.vn/gia-ban-so-cap-can-ho-chung-cu-noi-do-ha-noi-dat-trung-binh-102-trieu-dong-m2-205481.html)). |

---

## 4. Tin tức / kiến thức (RSS)

Tất cả dưới đây ✅ 200, RSS 2.0, 40–130 KB/feed (29/11/2026):

| Chủ đề | Primary | Fallback |
|---|---|---|
| Kinh tế / kinh doanh | `https://vnexpress.net/rss/kinh-doanh.rss` | `https://tuoitre.vn/rss/kinh-doanh.rss`, `https://thanhnien.vn/rss/kinh-te.rss` |
| Chứng khoán | `https://cafef.vn/thi-truong-chung-khoan.rss` | `https://vneconomy.vn/tai-chinh.rss` |
| Tài chính – ngân hàng (lãi suất) | `https://cafef.vn/tai-chinh-ngan-hang.rss` | `https://vneconomy.vn/tai-chinh.rss` |
| Sức khỏe | `https://vnexpress.net/rss/suc-khoe.rss` | `https://tuoitre.vn/rss/suc-khoe.rss`, `https://dantri.com.vn/rss/suc-khoe.rss` |
| Giáo dục / học tập | `https://vnexpress.net/rss/giao-duc.rss` | — |
| Đời sống / kỹ năng | `https://cafebiz.vn/rss/song.rss` | VnExpress `/rss/doi-song.rss` (chưa probe) |
| Tiếng Anh – sức khỏe uy tín | `https://www.who.int/rss-feeds/news-english.xml` (✅ nhưng **~770 KB** — nặng) | Harvard Health blog feed (301, cần theo redirect; chưa xác nhận) |
| Thống kê chính thức | `https://www.nso.gov.vn/feed/` | — |

**Bản quyền / ToS:**
- VnExpress: [điều khoản](https://vnexpress.net/dieu-khoan-su-dung) — nội dung thuộc sở hữu báo, cấm sao chép/phân phối **vì mục đích thương mại** khi chưa có văn bản đồng ý. Không có điều khoản riêng cho RSS.
- VnEconomy: [điều khoản](https://vneconomy.vn/dieu-khoan-su-dung) cho phép trích dẫn **≤ 300 từ** khi ghi nguồn và link bài gốc.
- Quy tắc an toàn cho MoMa (app cá nhân, 1 người dùng): **chỉ lưu** tiêu đề gốc (hoặc diễn giải), **tóm tắt AI tự viết ≤ 2 câu (~50 từ)**, tên báo, URL, thời gian. **Không** lưu full text, ảnh, description nguyên văn. **Không** cào trang bài viết — chỉ dùng title+description trong RSS. Luôn hiển thị nguồn + link. Nếu sau này app phân phối rộng/thu phí → xin phép bằng văn bản hoặc chuyển sang chỉ hiển thị headline + link.
- Tin sức khỏe: AI chỉ tóm tắt nội dung tổng quát kèm câu "tham khảo, không thay thế tư vấn y tế"; ưu tiên WHO/nguồn y khoa cho tip "evergreen".

---

## 5. Cloudflare Workers Free – ràng buộc & cách thiết kế

Giới hạn (docs [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), cập nhật 25/11/2026; [KV limits](https://developers.cloudflare.com/kv/platform/limits/), cập nhật 30/10/2026):

| Giới hạn Free | Giá trị | Hệ quả |
|---|---|---|
| CPU / invocation (HTTP **và** Cron) | **10 ms** | Thời gian chờ `fetch()`/DeepSeek **không** tính CPU, nhưng parse XML/JSON có tính. Parse 5–10 feed 60 KB + JSON.stringify prompt có thể sát 10 ms → **chia việc theo tick**, parse bằng regex nhẹ, cắt `items` sớm, không dùng thư viện XML DOM nặng. Bỏ WHO feed 770 KB hoặc chỉ đọc N KB đầu. |
| Subrequests / invocation | 50 | Mỗi tick ≤ ~15 fetch là an toàn (nguồn + DeepSeek + Supabase). |
| Cron triggers / account | 5 | Dùng **cron 15 phút sẵn có**, rẽ nhánh theo `scheduledTime` (giờ/phút) — không cần thêm cron. |
| Requests / ngày | 100.000 | Không đáng kể. |
| KV free | 100k read, **1.000 write/ngày** (key khác nhau), 1 write/s/key, 1 GB | Đủ cho "last-known-good" + hash dedupe (~100–200 write/ngày). |
| Cache API | Dùng chung quota subrequest | Lưu ý: Cache API **không hoạt động trên `*.workers.dev`** (chỉ trên custom domain) — đừng dựa vào nó cho cron. *(Theo hiểu biết hiện có, nên kiểm tra lại docs Cache.)* |

**Kiến trúc lưu trữ (không để raw vào DB):**
1. Raw response chỉ sống **trong bộ nhớ** của invocation. Không ghi raw vào Postgres/R2.
2. **KV** (namespace `MARKET`): `gold:latest`, `fx:latest`, `idx:latest` (JSON nhỏ đã chuẩn hoá, last-known-good, phục vụ app đọc nhanh), `seen:<source>` (danh sách ~200 hash URL gần nhất để dedupe trước khi gọi AI).
3. **Postgres (Supabase)**: chỉ dữ liệu đã chọn lọc:
   - `market_snapshot` (1 dòng/ngày/loại: vàng SJC/nhẫn mua-bán, XAU, chênh lệch, USD/VND, VNINDEX, mã watchlist) → đủ cho biểu đồ và dự báo đơn giản; vài nghìn dòng/năm.
   - `macro_indicator` (CPI tháng, lãi vay quý, giá căn hộ quý) — vài chục dòng/năm.
   - `insight_item` (tóm tắt AI: `id, topic, title, summary ≤ 300 ký tự, source, url, url_hash UNIQUE, published_at, score, expires_at`) — giữ tối đa ~10–20 item/ngày, xoá item hết hạn sau 30–90 ngày (tip evergreen giữ lâu hơn).
4. R2: không cần ở giai đoạn này.

**Lịch đề xuất (trên cron 15 phút; giờ VN = UTC+7):**

| Việc | Lịch | Fetch/tick |
|---|---|---|
| Vàng (PNJ + XAU, fallback BTMC) | 30 phút/lần 08:00–17:30 VN, ngoài giờ 3 giờ/lần | 2–3 |
| Tỷ giá VCB | 1 giờ/lần 08:00–17:00 VN, ngoài giờ 1 lần | 1 |
| VN-Index + watchlist EOD | 15:15 VN T2–T6 (+ tuỳ chọn 11:35) | 2–20 |
| XAU/chỉ số toàn cầu snapshot ngày | 1 lần/ngày | 1–3 |
| RSS: quay vòng 1–2 feed/tick, mỗi feed 2–3 lần/ngày | rải đều | 1–2 |
| Gọi DeepSeek tóm tắt batch | 2 lần/ngày (vd. 06:30 và 18:30 VN — rơi vào giờ **off-peak** DeepSeek) | 1–3 |
| Tóm tắt thị trường ngày (vàng/tỷ giá/chỉ số → 3–5 câu) | 1 lần/ngày sau 15:30 VN | 1 |
| CPI/NSO feed, quét lãi vay/giá nhà từ tin đã lọc | 1 lần/ngày | 1 |

Luồng tin: fetch RSS → parse title/link/description/pubDate → bỏ trùng bằng `hash(url)` và gần trùng theo tiêu đề chuẩn hoá (KV `seen:*` + UNIQUE `url_hash`) → lọc từ khoá rẻ trong code → gom vào hàng đợi KV → batch 2 lần/ngày gửi DeepSeek **một prompt** trả JSON: chọn top N hữu ích, gán topic, viết summary ≤ 2 câu, điểm hữu ích; drop phần còn lại. Nếu batch quá 10 ms CPU, tách thành nhiều tick.

**Chi phí DeepSeek** ([pricing](https://api-docs.deepseek.com/quick_start/pricing), xem 29/11/2026): `deepseek-flash` (V4.1-Flash) cache miss **$0,30/1M input, $1,20/1M output** giờ cao điểm; **giảm 50% off-peak** (cao điểm = 01–04h & 06–10h UTC T2–T6, tức 08–11h & 13–17h VN). Thinking mode bật mặc định → **tắt thinking** cho tác vụ tóm tắt.

Ước tính: ~8 feed × ~40 item mới/ngày ≈ 300 item → sau dedupe/lọc từ khoá ~150 item × ~80 token = 12k + prompt/system 2×2k + tóm tắt thị trường 2k + CPI/giá nhà 3k ≈ **~25–40k token input/ngày, ~5–8k output/ngày**.
→ Peak: ~0,012 + ~0,010 ≈ **$0,02/ngày (~$0,6/tháng)**; off-peak ≈ **$0,3/tháng**. Kể cả gấp 10 lần vẫn < $6/tháng. Dùng prefix system prompt cố định để hưởng giá cache hit ($0,006/1M).

---

## 6. Bộ nguồn tối thiểu khuyến nghị

| Dữ liệu | Primary | Fallback | Tần suất | Lưu ở đâu |
|---|---|---|---|---|
| Vàng VN (SJC, nhẫn) | PNJ edge-api | BTMC API | 30' giờ hành chính | KV latest + 1 snapshot/ngày Postgres |
| XAU thế giới | gold-api.com | BTMC `@pt` → Yahoo GC=F | 30' | như trên |
| Tỷ giá | Vietcombank XML | open.er-api.com | 1 giờ | như trên |
| VN-Index/HNX/UPCOM | VNDirect dchart | DNSE Entrade chart-api | EOD 15:15 | snapshot ngày |
| Cổ phiếu watchlist (≤20) | VNDirect finfo `stock_prices` | DNSE `ohlcs/stock` | EOD | snapshot ngày; chỉ báo tính trong code |
| CPI | NSO RSS + AI trích | Nhập tay | Ngày (quét) / tháng (ghi) | `macro_indicator` |
| Lãi vay mua nhà | Bảng nhập tay | AI gợi ý từ CafeF tài chính-ngân hàng | Quý | `macro_indicator` |
| Giá căn hộ | AI trích từ tin RSS | Nhập tay | Quý | `macro_indicator` |
| Tin kinh tế/tài chính | VnExpress kinh doanh, CafeF chứng khoán + TC-NH | Tuổi Trẻ, Thanh Niên, VnEconomy | 2–3 lần/ngày/feed | KV hàng đợi → `insight_item` sau AI |
| Sức khỏe/giáo dục/đời sống | VnExpress sức khỏe, giáo dục; CafeBiz sống | Tuổi Trẻ, Dân trí; WHO (EN) | 1–2 lần/ngày | `insight_item` |

---

## 7. Rủi ro & lưu ý pháp lý / ToS

1. **Endpoint không chính thức** (PNJ, BTMC, VNDirect, DNSE, SSI iBoard, Vietcap, Yahoo): không có cam kết, có thể đổi schema/chặn bất kỳ lúc nào; ToS website thường cấm thu thập tự động. Giảm rủi ro: tần suất thấp, User-Agent rõ ràng (tên app chung, không chứa thông tin cá nhân), chỉ dùng cá nhân, không phân phối lại số liệu, có fallback + cảnh báo "dữ liệu cũ > X giờ".
2. **Chưa test từ IP Cloudflare.** Probe ở trên chạy từ IP dân dụng VN. Worker đi ra từ IP datacenter Cloudflare (thường không ở VN), có header `CF-Worker`. Rủi ro cao nhất: Vietcap (đã biết chặn IP cloud), SSI, Vietcombank, PNJ (đều có WAF). **Bước đầu tiên khi triển khai: deploy một route `/admin/probe` chạy toàn bộ danh sách endpoint từ Worker và ghi kết quả** trước khi viết parser.
3. SJC, DOJI, TCBS, NHNN chặn bằng challenge/WAF → **không** cố vượt (không dùng headless browser/proxy né chặn).
4. Vietcombank yêu cầu tối đa 1 request/5 phút — tuân thủ.
5. Nội dung báo: chỉ headline + tóm tắt tự viết ngắn + link; không lưu full text/ảnh; không dùng cho mục đích thương mại khi chưa xin phép.
6. Dự báo chứng khoán/vàng: hiển thị disclaimer, chỉ số tất định, không đưa khuyến nghị mua/bán.
7. Ngày nghỉ lễ VN: thị trường đóng cửa → code phải chấp nhận "không có dữ liệu mới" mà không coi là lỗi.

## 8. Việc owner cần làm (key/đăng ký)

| Việc | Bắt buộc? |
|---|---|
| DeepSeek API key (đã có trong dự án) — đặt bằng `wrangler secret` | Đã có |
| Tạo KV namespace `MARKET` và bind vào Worker | Có (miễn phí) |
| PNJ, BTMC, gold-api, VCB, open.er-api, VNDirect, DNSE, RSS | Không cần key |
| SSI FastConnect Data — chỉ khi muốn nguồn **chính thức** cho chứng khoán: cần tài khoản SSI + đăng ký dịch vụ (1 năm), nhận ConsumerID/Secret/PrivateKey; phí chưa rõ | Tuỳ chọn |
| Alpha Vantage / FMP key — chỉ khi cần dữ liệu toàn cầu chính thức thay Yahoo | Tuỳ chọn |
| Custom domain cho Worker — nếu muốn dùng Cache API | Tuỳ chọn |

## Nguồn đã tra (29/11/2026)
- Cloudflare Workers limits: https://developers.cloudflare.com/workers/platform/limits/ · KV limits: https://developers.cloudflare.com/kv/platform/limits/
- DeepSeek pricing: https://api-docs.deepseek.com/quick_start/pricing
- gold-api docs: https://gold-api.com/docs · ExchangeRate-API terms: https://www.exchangerate-api.com/terms
- SSI FastConnect Data: https://guide.ssi.com.vn/ssi-products/tieng-viet/fastconnect-data · https://www.ssi.com.vn/en/individual-customer/fast-connect-api
- vnstock (trạng thái nguồn TCBS/KBS/VCI, rate limit): https://pypi.org/project/vnstock/ · https://github.com/thinh-vu/vnstock
- vnappmob gold API (deprecated): https://vapi-vnappmob.readthedocs.io/en/latest/gold.html
- Điều khoản VnExpress: https://vnexpress.net/dieu-khoan-su-dung · VnEconomy: https://vneconomy.vn/dieu-khoan-su-dung
- CPI 10T/2026: https://nhandan.vn/10-thang-nam-2026-cpi-tang-457-so-voi-cung-ky-post999862.html · NSO: https://www.nso.gov.vn/tag/cpi-vi/
- Lãi vay mua nhà 11/2026: https://cafef.vn/lai-vay-mua-nha-hien-tai-la-bao-nhieu-188261115071446931.chn
- Giá căn hộ Q3/2026: https://thoibaotaichinhvietnam.vn/gia-ban-so-cap-can-ho-chung-cu-noi-do-ha-noi-dat-trung-binh-102-trieu-dong-m2-205481.html
- Các endpoint trong bảng mục 1–4: probe trực tiếp bằng curl ngày 29/11/2026.
