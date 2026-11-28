# Decision log

| ID | Date | Decision | Why |
|---|---|---|---|
| D-001 | 2026-11-27 | Brand MoMa (MoneyManage). Repo `moma/` with spec copied to `spec/` unchanged. | Owner request; spec requires repo layout in docs/11 section 2. |
| D-002 | 2026-11-27 | Owner decision: write code first, run tests later (single-user app). Nothing is reported as tested until actually run. | Owner instruction overrides the test-first workflow in docs/11 section 6. Release gates in docs/11 section 5 still apply before any production use. |
| D-003 | 2026-11-27 | Additive columns on `pf_tx` (amount, account_id, to_account_id, category_id, fee) as RPC-written projections; journal stays the financial truth. | Needed for transaction list without re-deriving from journal lines. |
| D-004 | 2026-11-27 | Extra system ledger account `SYS_FEE_EXPENSE` for transfer fees (BR-15). | Not in the reserved list of docs/12; spec change to report/confirm. |
| D-005 | 2026-11-27 | API validates only implemented commands (ACCOUNT_CREATE, TX_CREATE w/o splits/refunds, TX_REVERSE); others return NOT_IMPLEMENTED. | No fake success (AGENTS.md). |
| D-006 | 2026-11-27 | TX_CORRECT voids the old transaction and creates a NEW linked one (`related_tx_id`) instead of keeping the same id. | Spec wants the same id only to preserve source-event links; none exist before Gate 3. Revisit then. |
| D-007 | 2026-11-27 | Offline outbox stores whole commands with a fixed `command_id` in Keystore-backed secure storage; rejected commands stay visible until the owner discards them. | F04 "no silent data loss"; idempotency makes retries safe. |
| D-008 | 2026-11-27 | JWT verification supports legacy HS256 only when `SUPABASE_JWT_SECRET` is set; default is JWKS (asymmetric). | New Supabase projects use JWKS; older ones may not. |
| D-009 | 2026-11-27 | CSV import = client-side parse + one idempotent TX_CREATE per row with a deterministic command id (account + file fingerprint + row). | Gives re-import safety without new server tables; cross-source dedup stays in Gate 3. |
| D-010 | 2026-11-27 | Dashboard counts transfer fees, bad debt and interest as classified income/expense; only SYS_ADJUSTMENT_* is excluded. | docs/03 BR-15, BR-19, section 7. |


## D-011 — Hiển thị lỗi: hộp thoại cho lỗi hệ thống, inline cho validate
Chủ sở hữu yêu cầu: lỗi từ máy chủ/mạng/không mong đợi hiện bằng hộp thoại modal (`showErrorDialog`); chỉ lỗi kiểm tra dữ liệu nhập (thiếu số tiền, mật khẩu < 8 ký tự…) hiện inline cạnh form. Thông báo thành công/thông tin dùng SnackBar.

## D-012 — Đăng ký bằng email chủ sở hữu + mã qua thư, bỏ khóa triển khai
Chủ sở hữu yêu cầu luồng đăng ký/đăng nhập thông thường. `POST /v1/setup/start` chỉ nhận `OWNER_EMAIL`; quyền kiểm soát hộp thư (mã dùng một lần) chứng minh danh tính. `BOOTSTRAP_SECRET` không còn dùng. Lệch có chủ đích so với spec 02 (bootstrap bằng khóa triển khai); đổi lại dễ dùng hơn.

## D-013 — Trợ lý AI chỉ đề xuất
DeepSeek `deepseek-flash` qua Worker (khóa chỉ ở Worker). AI trả đề xuất đã kiểm tra id/số tiền/ngày; chủ sở hữu bấm Xác nhận thì lệnh `TX_CREATE` idempotent mới ghi. Chặn chi phí theo spec 05 mục 5 (đặt trước chi phí xấu nhất, trần 1 USD/tháng).

## D-014 — Nhắc việc thông minh và phân tích chi tiêu (migration 008)
- Cron Worker 15 phút (`scheduled()`) + dự phòng `POST /v1/internal/tick` (header `x-cron-secret` = secret `CRON_SECRET`, gọi từ GitHub Actions `moma-tick.yml`) vì tài khoản Cloudflare chưa đăng ký được cron. Mỗi push được "claim" một lần trong `pf_push_log` nên gọi trùng vô hại.
- Bữa ăn "đã ghi" = có khoản chi POSTED thuộc danh mục "Ăn uống" (theo tên hoặc icon `restaurant`) hoặc danh mục con, trong khung giờ địa phương (sáng 04:00–10:30, trưa 10:30–15:00, tối 15:00–23:00). Nhắc bữa ăn/kiểm tra tiền mặt chỉ gửi trong 3 giờ sau giờ hẹn; cảnh báo ngân sách chỉ 07:00–22:00.
- Số liệu phân tích do SQL/TS tính; AI (DeepSeek, qua trần chi phí) chỉ viết lời; tắt/hết hạn mức thì dùng văn bản theo luật. Mức chi đề xuất = trung vị các kỳ gần nhất (4 tuần / 3 tháng / 14 ngày, bỏ kỳ không ghi chép), kéo một nửa về mục tiêu ngân sách nếu cao hơn, làm tròn lên 10.000 đ. So sánh với kỳ trước cùng số ngày đã trôi qua.

## D-015 — Bỏ trần chi phí AI theo tháng
Chủ sở hữu quyết định không giới hạn chi phí AI. `MONTHLY_CAP_MICRO` đặt rất lớn (không chặn thực tế); mỗi lần gọi vẫn ghi lại chi phí trong `pf_ai_usage`. Thay thế mức trần 1 USD/tháng ở D-013.

## D-016 — Đánh phiên bản mỗi bản phát hành
Mỗi bản phát hành có phiên bản mới theo SemVer. Trước bản phát hành hoàn chỉnh dùng 0.MINOR.PATCH (MINOR khi có tính năng mới, PATCH khi chỉ sửa lỗi); bản hoàn chỉnh đầu tiên là 1.0.0. Số build (+N) luôn tăng 1, không đặt lại. Không phát hành khi phiên bản/tag đã tồn tại, cây git chưa sạch, hoặc analyze/test chưa đạt. Bản kế tiếp: 0.2.0+2.

## D-017 — Khóa ứng dụng
Khóa khi mở lại sau khi app bị tắt hẳn, hoặc khi quay lại sau thời gian ở nền vượt mức chọn (15 phút / 30 phút mặc định / 1 giờ / 2 giờ). Sai PIN 5 lần thì chờ cố định 10 giây. Back ở màn hình gốc đưa app xuống nền thay vì đóng.

## D-018 — Tự ghép chuyển tiền giữa tài khoản của chủ sở hữu (migration 010)
Tiền ra ở một tài khoản + tiền vào ở tài khoản khác của chủ sở hữu, đúng cùng số tiền, cách nhau ≤ 15 phút, ít nhất một chiều từ BANK/NOTIFICATION, không gắn công nợ/định kỳ → một giao dịch TRANSFER. Duy nhất và đủ mạnh (≤ 5 phút, hoặc ≤ 15 phút kèm gợi ý nội dung: từ khóa ví/chuyển tiền, tên chủ sở hữu, tên ngân hàng/4 số cuối tài khoản kia) → tự ghép (AUTO): đảo hai giao dịch gốc (giữ lịch sử), ghi một TRANSFER qua code sổ cái thường. Nhiều ứng viên hoặc khớp yếu → chỉ đề xuất (SUGGESTED), chủ sở hữu chọn Đúng/Không; Không thì không bao giờ đề xuất lại cặp đó. Cùng mã tham chiếu ngân hàng (FT…, token chữ+số ≥ 10 ký tự) ở hai chiều → chắc chắn, tự ghép dù cách tới 24 giờ. Chỉ một chiều (ví dụ MoMo không báo tiền ra) mà nội dung nêu tên chủ sở hữu + đúng một tài khoản khác của mình (tiền vào), hoặc nêu đúng một ví của mình (tiền ra), và hết 15 phút vẫn không có chiều kia → lượt đối soát định kỳ ghi TRANSFER với chiều còn thiếu được tạo ra; chiều đó đến muộn thì được gộp vào, không tính hai lần. "Tách ra" hoàn tác mọi kiểu ghép. Hook sau sự kiện ngân hàng APPLIED và TX_CREATE nguồn NOTIFICATION (không bao giờ làm hỏng lệnh gốc); cron quét lại 48 giờ.

## D-019 — Sửa, hoàn tác và xóa công nợ (migration 014)
Chủ sở hữu cần gỡ khoản nợ nhập nhầm. Sổ cái vẫn chỉ ghi thêm: không xóa dòng nào. `DEBT_CANCEL` ("Xóa khoản nợ") đảo mọi lần thu/trả/xóa nợ còn hiệu lực và giao dịch gốc (các giao dịch thành VOID), khoản nợ chuyển CANCELLED và biến mất khỏi danh sách, số dư, tài sản ròng; dòng nợ được giữ (docs/12 §4). `DEBT_PAYMENT_REVERSE` hoàn tác một lần thu/trả hoặc xóa nợ: đảo giao dịch đó, số còn lại và trạng thái tính lại. `DEBT_UPDATE` đổi người, hạn, ghi chú; đổi số tiền gốc chỉ khi chưa có lần thu/trả nào còn hiệu lực (đảo + bút toán thay thế trên cùng giao dịch gốc), ngược lại báo DEBT_HAS_PAYMENTS để chủ sở hữu hoàn tác trước. Khác spec cũ ("no principal mutation") có chủ đích, theo yêu cầu của chủ sở hữu.

## D-020 — Tự phân loại giao dịch + "Chọn loại nhanh" (migration 015, 1.2.0)
Tiền ghi từ thông báo/SePay hay nằm ở "chưa phân loại" hoặc "Khác". Máy chủ phân loại theo thứ tự tin cậy:
(1) quy tắc đã học của chủ sở hữu (CATEGORY_RULE), (2) lịch sử của chính chủ sở hữu (cùng "chữ ký" nội dung ≥ 2 lần,
≥ 80% cùng một loại), (3) từ điển cửa hàng/từ khóa Việt Nam (Grab, Highlands, EVN, Shopee…; tránh tên người như
Thương/Lương/Trương), (4) DeepSeek với danh mục thật của chủ sở hữu + ví dụ gần đây (không bịa danh mục; độ tin của
model tối đa 0.88, "Khác" tối đa 0.5). Từ 0.75 trở lên và không phải "Khác"/"Thu nhập khác" → áp dụng ngay **trên cùng
giao dịch** (đảo + bút toán thay thế, giữ id nên ảnh chứng từ, ghép chuyển khoản, link thông báo vẫn đúng); thấp hơn →
lưu gợi ý. `TX_ANNOTATE` nhận cả UNKNOWN_* (cùng quy tắc) nên một chạm của chủ sở hữu cũng giữ nguyên giao dịch; lựa
chọn đó được ghi CONFIRMED/CORRECTED (máy không bao giờ ghi đè) và dạy quy tắc "cửa hàng/chữ ký → loại" cho lần sau.
Chạy sau TX_CREATE UNKNOWN_* (sau ghép chuyển khoản), sau sự kiện SePay (webhook chỉ dùng tầng xác định để trả lời
nhanh; phần AI chạy nền), và cron 15 phút (tối đa 8 khoản/lượt). Khoản còn chưa rõ → **một** thông báo đẩy + hộp thư
("Khoản -200.000đ ở VCB lúc 12:30 chưa rõ loại" hoặc "N khoản chưa rõ loại"), mỗi khoản chỉ báo một lần, tối đa một lần
mỗi 10 phút khi vừa ghi, phần còn lại gộp ở lượt cron; im lặng 23:00–06:59. Màn "Chọn loại nhanh" (/classify, banner
trang chủ, chuông "Cần xử lý"): mỗi thẻ một khoản, 4 gợi ý lớn + "Khác…", ghi chú tùy chọn, chạm là lưu và sang khoản
tiếp theo — không hỏi lại những gì hệ thống đã biết (tài khoản, số tiền, giờ, nội dung).

## D-021 — Offline-first: có mạng dùng mạng, mất mạng dùng dữ liệu đã lưu (1.2.0)
- **Đọc:** mọi `GET` đi qua `ApiClient.get` → mạng trước; lỗi mạng (`OFFLINE`) thì trả bản đã lưu trong SQLite
  (`moma_cache.db`, bảng `api_cache(owner, key, json, at)`, theo từng chủ sở hữu). Không cần sửa từng màn hình.
  Dữ liệu ít đổi (`/categories`, `/profile`, `/settings`, `/banks/sepay/qr` 6 giờ; `/banks/sepay/accounts`,
  `/banks/links` 30 phút) dùng lại từ máy không gọi mạng; mọi lệnh ghi thành công làm mới hết (không dùng lại).
  Không lưu `/auth`, `/setup`, `/health`, `/devices`; không lưu bí mật (token chỉ ở Supabase/Keystore).
- **Trạng thái mạng:** `NetStatus` (offline khi một request không tới được máy chủ, online lại khi có phản hồi).
  Dải "Đang offline · cập nhật lúc HH:mm" thay cho lỗi đỏ; `ErrorView` khi offline và chưa có bản lưu hiển thị
  "Đang offline" nhẹ nhàng và tự tải lại khi có mạng. Lỗi thật (từ chối, kiểm tra dữ liệu) vẫn hiện như cũ.
- **Ghi:** giao dịch nhập offline nằm trong outbox (D-007), hiện ngay đầu danh sách "Chờ đồng bộ" và đã tính vào
  số dư tài khoản; ảnh chứng từ chọn lúc offline được giữ trong bộ nhớ riêng của app ("Chờ tải lên").
  Vòng đồng bộ (`offlineSyncProvider`): khi có mạng lại, khi app trở lại màn hình, và mỗi 20 giây khi đang offline
  hoặc còn việc chờ → gửi outbox, tải ảnh lên, rồi tải lại dữ liệu đang hiển thị.
- **Ảnh:** ảnh chứng từ đã xem được lưu trong thư mục cache theo id (nội dung bất biến) nên mở được khi offline;
  chưa có thì hiện "Ảnh sẽ hiện khi có mạng". Logo ngân hàng/ví đều là tài nguyên đóng gói, không tải mạng.
- **QR nhận tiền:** offline dựng lại mã có số tiền/nội dung ngay trên máy từ mã QR thường đã lưu (cùng định dạng
  VietQR với máy chủ, `lib/core/vietqr.dart`); tiện ích QR giữ bản cuối cùng, không bị ghi đè bằng dữ liệu cũ.
- **Ngân hàng (SePay):** offline hiện danh sách và số dư đã lưu kèm giờ cập nhật; "Kết nối" và "Đồng bộ" tạm khóa.
- Đăng xuất xóa toàn bộ bản lưu và ảnh; Cài đặt → "Dữ liệu ngoại tuyến" cho xem trạng thái, dung lượng, đồng bộ
  ngay, xóa bộ nhớ đệm (giữ nguyên việc đang chờ đồng bộ).
## D-022 — Quy tắc định kỳ tự nhận + chia tiền, đọc ảnh hóa đơn (migration 016, 1.2.0)

- **Bối cảnh:** chủ sở hữu muốn "tự động hết": tiền nhà 1.600.000đ trả khoảng ngày 5–10, chia 3 (cả mình) thì Nam
  và Lan mỗi người nợ 535.000đ; tải ảnh hóa đơn lên thì tự cập nhật danh mục/ghi chú và đề xuất chia tiền.
- **Quy tắc** (`RECURRING_SPLIT_UPSERT` = RECURRING_UPSERT + `pf_recurring_split`): khoảng ngày, sai số số tiền
  (mặc định 10%), chữ trong nội dung chuyển khoản, người cùng trả (chia đều / số cố định / %), làm tròn phần người
  khác LÊN bội 0/1.000/5.000/10.000 (mặc định 5.000, chủ sở hữu giữ phần dư), tự ghi hay luôn hỏi.
- **Khớp** (Worker, `modules/split/split.ts matchRule`) sau mỗi khoản tiền ra (SePay webhook/đồng bộ, lệnh TX_CREATE
  từ thông báo/thủ công) và trong cron 15 phút (72 giờ gần nhất): bắt buộc đúng khoảng ngày (±3 ngày) và trong sai số;
  điểm theo độ khớp số tiền, đúng tài khoản, chữ khớp. Chắc (≥0,8, quy tắc cho phép, không mơ hồ giữa 2 quy tắc) →
  tự ghi: danh mục tại chỗ, khớp kỳ, tạo nợ, push "Đã ghi tiền nhà 1.600.000đ · Nam nợ 535.000đ, Lan nợ 535.000đ"
  (chạm để hoàn tác). Vừa (≥0,5) → đề xuất một chạm (chuông "Cần xử lý"). Khoản định kỳ thường (không có cài đặt
  khoảng ngày, vd Netflix) phải đúng số tiền ±1% VÀ đúng tài khoản hoặc tên — tránh "Có phải Netflix?" cho ly cà phê.
  Hết khoảng ngày mà chưa thấy → push "Chưa thấy khoản tiền nhà tháng 12" (một lần, pf_push_log).
- **Sổ cái:** hóa đơn vẫn là một khoản chi (tiền ra một lần). Mỗi phần chia là một khoản phải thu có giao dịch gốc
  Nợ phải thu / Có tài khoản chi phí của hóa đơn → tiền mặt không đổi, chi phí chỉ còn phần của chủ sở hữu. Hoàn tác
  = DEBT_CANCEL các khoản nợ (bút toán đảo, D-019) + kỳ định kỳ về "chờ". Hóa đơn đã chia không thể hủy/sửa/đổi danh
  mục bên dưới các khoản nợ (trigger `SPLIT_LINKED`); hoàn tác bị từ chối khi đã có người trả lại.
- **Dùng chung** cho mọi đường (khớp tự động, ảnh hóa đơn, Trợ lý): `computeShares` + `POST /v1/splits/propose`,
  `POST /v1/splits/apply` (tên người chưa có thì tự tạo người quen), `SPLIT_APPLY/SPLIT_UNDO/SPLIT_DISMISS`.
- **Ảnh hóa đơn:** mỗi ảnh thêm vào "Ảnh chứng từ" được đọc chữ trên máy (ML Kit) rồi `POST /v1/bills/analyze`
  (DeepSeek, dự phòng bằng từ khóa + bộ phân loại D-020): chắc → cập nhật danh mục/nơi chi/ghi chú món tại chỗ
  ("Đã cập nhật: Ăn uống · Lẩu Hội An · Hoàn tác"); chưa chắc → thẻ xác nhận một chạm; tổng hóa đơn khác số tiền →
  cảnh báo + nút sửa một chạm (không bao giờ tự đổi tiền); có quy tắc → áp ngay; hóa đơn ăn chung → thẻ đề xuất chia
  ("Nhóm hay đi", "Chọn người…", "Không chia"); hóa đơn một mình → không hỏi chia.

## D-023 — Trợ lý tài chính điều khiển 100% API tài chính, học thói quen, hỏi một chạm (1.2.0)

- **Bối cảnh:** chủ sở hữu muốn "tự động hết, tôi ít thao tác nhất có thể"; Trợ lý là người bạn đồng hành, AI thao
  tác được mọi khoản trong app tài chính.
- **Công cụ = mọi lệnh:** mỗi lệnh trong `command-schemas.ts` (26 lệnh, gồm 4 lệnh chia tiền của D-022) là một công cụ
  của agent qua bước `CMD`; gợi ý payload sinh tự động từ zod (`modules/ai/tools.ts`), nên lệnh mới chỉ cần thêm hạng
  rủi ro + mô tả tiếng Việt (test `agent-tools.test.ts` báo lỗi nếu thiếu). Id chỉ được lấy từ dữ liệu đã cho agent xem
  hoặc kết quả bước trước (`$sN.tx_id`…); mọi payload vẫn qua đúng schema và lệnh idempotent như app.
- **Tìm trước, làm sau:** bước `LOOKUP` (giao dịch theo chữ/danh mục/tài khoản/khoảng tiền/ngày giờ Việt Nam, nợ, định
  kỳ, ngân sách, người quen, mục tiêu) chạy giữa các lượt model (tối đa 2 lượt thêm), ví dụ "hủy khoản cà phê hôm qua".
- **Hạng rủi ro:** tự chạy (có Hoàn tác) cho ghi thu chi, điền danh mục, cho vay/đi vay, thu/trả nợ, mục tiêu, ngân sách,
  định kỳ, chia tiền; cần một chạm cho hủy/sửa số tiền giao dịch, xóa nợ, hoàn tác lần trả, xóa nợ khó đòi, thêm/lưu
  trữ tài khoản, số tiền > 20.000.000đ, hoặc hơn 6 bước một lần. (Thay đổi so với trước: cho vay/thu nợ/ngân sách/
  mục tiêu/định kỳ trước đây luôn chờ xác nhận, nay tự chạy vì đã hoàn tác được.)
- **Hoàn tác do máy chủ giải:** mỗi bước kèm mô tả hoàn tác (`REVERSE_TX`, `CANCEL_DEBT`, `REVERSE_DEBT_PAYMENT`,
  `SPLIT_UNDO`, khôi phục giá trị cũ…); `POST /v1/ai/undo` đọc version hiện tại rồi chạy lệnh ngược với mã lệnh suy ra
  từ bước gốc (bấm hai lần = một lần). Hoàn tác cũng làm yếu thói quen liên quan trong ghi nhớ.
- **Ảnh hóa đơn trong chat:** đọc trên máy (OCR) → `analyzeBill` (tổng tiền, món, số khách/combo/số món → số người, mục
  đích: nhu yếu phẩm cá nhân / ăn uống / giải trí / sinh hoạt). Tìm giao dịch đã ghi sẵn cùng số tiền (+0–10% tiền
  típ) trong 12 giờ trước: có một → điền vào đó (TX_ANNOTATE), có hai → hỏi một chạm, không có → ghi mới; ảnh luôn được
  kèm vào giao dịch đó (hàng đợi khi offline). Ăn/chơi theo nhóm → hỏi "Chia hóa đơn … cho ~N người?" với nhóm hay chia
  chọn sẵn, "Chia đều N người", "Chọn người…", "Không chia"; cá nhân/một mình → không hỏi. Câu trả lời ("chia Nam với
  Lan", "riêng Huy 2 bia") → SPLIT: phần mỗi người tính bằng `computeShares` dùng chung (làm tròn lên 5.000đ mặc định,
  theo thói quen), rồi `SPLIT_APPLY` trên chính giao dịch hóa đơn (tiền ra = tổng hóa đơn, chi tiêu = phần của chủ).
- **Thói quen (pf_ai_memory, không cần migration):** HABIT "chia bill <nhóm>" (mạnh lên khi xác nhận, yếu đi khi hoàn
  tác, phai theo thời gian), HABIT "không chia <loại hóa đơn>" sau khi trả lời "không chia", PREFERENCE làm tròn; REMEMBER/
  FORGET ("quên cái đó đi" xóa đúng mục). Danh mục thiếu được điền từ gợi ý hóa đơn hoặc bộ phân loại D-020 trước khi hỏi.
- **Thói quen theo buổi:** `modules/ai/routine.ts` học từ sổ (≥3 ngày trong 30 ngày, ưu tiên gần đây, cùng kiểu ngày
  thường/cuối tuần): món, giá thường, tài khoản, danh mục cho sáng/trưa/tối. Nhắc bữa ăn trở thành "Sáng nay bạn ăn gì?"
  với 2 nút món quen + "Hôm nay không" (đã ghi/bỏ qua/tắt trong Cài đặt thì không nhắc như cũ); chip giống vậy ở Trang
  chủ và Trợ lý; `POST /v1/ai/routine/record` ghi ngay (mã lệnh theo ngày + món: chạm hai lần chỉ ghi một). Sáng
  8:30–11:00: "Hôm qua bạn chưa ghi gửi xe, cà phê như mọi ngày?" (món có ≥10/14 ngày) với nút "Ghi".
- **Persona:** "Trợ lý tài chính", xưng mình – bạn, ấm áp, ngắn; làm trước, hỏi đúng phần thiếu; chúc mừng/nhắc rủi ro
  khi phù hợp, không spam.

## D-024 — Một lần trả tiền được báo 2 lần thành MỘT giao dịch (migration 018, 1.2.0)

- **Bối cảnh:** trả MoMo/Grab/ShopeePay... bằng tài khoản ngân hàng liên kết (VCB...) sinh 2 khoản tiền ra cho cùng
  một lần trả: ngân hàng (nội dung là mã của ví, không đọc được) và thông báo "thanh toán thành công" của ví/app; app
  còn đăng lại thông báo với khóa mới. Trước đây cả hai đều được ghi → chi tiêu tính đôi, số dư ví sai. Ngoài ra luật
  "một chiều" của D-018 biến khoản VCB "MOMO … THANH TOAN" thành nạp tiền vào ví sau 15 phút.
- **Trên máy (đăng lại):** mã lệnh TX_CREATE ổn định theo lần trả thật: mã giao dịch MoMo → mã tham chiếu ngân hàng
  (FT…) → số dư sau giao dịch (+ ngày) → khóa thông báo; không có mã nào thì dấu vân tay nội dung (bỏ giờ/ngày) trong
  10 phút, lưu cục bộ 100 mục. Máy chủ trả DUPLICATE_KEY_MISMATCH cho bản sao → coi là "đã ghi".
- **Máy chủ (`pf_same_payment`):** cùng chiều, đúng số tiền, cách ≤10 phút, chưa gắn nợ/định kỳ/chia/chuyển tiền,
  chưa bị từ chối; cùng tài khoản: cùng mã tham chiếu, hai thông báo (đăng lại), hoặc một nhập tay + một tự ghi (chỉ
  đề xuất); khác tài khoản (chỉ tiền ra): một bên là ví, hoặc nội dung ngân hàng nêu trung gian thanh toán / tài khoản
  kia. Không bao giờ khi hai mã tham chiếu khác nhau, có chữ nạp/chuyển/rút tiền, hoặc ví nhận đúng số tiền ±15 phút
  (nạp rồi trả = chuyển tiền + chi tiêu). Giữ bên tiền thật đi (ngân hàng hơn ví, BANK hơn NOTIFICATION, bên đã phân
  loại, bên sớm hơn); gộp = bổ sung danh mục (khi bên giữ chưa phân loại hoặc chỉ do AI đoán, không đè lựa chọn của
  chủ sở hữu), nơi chi thật thay cho nội dung thô, ghi chú, ảnh chứng từ chuyển sang, rồi đảo bên kia (giữ lịch sử).
  Tự gộp khi duy nhất hai chiều và chắc (cùng mã; khác tài khoản ≤5 phút có trung gian/tài khoản; bên ví ≤2 phút;
  đăng lại cùng nội dung ≤3 phút), còn lại đề xuất "Gộp / Không trùng". "Tách ra" khôi phục đúng như trước và không
  bao giờ gộp lại hai giao dịch đó. Luật một chiều (D-018) bỏ qua khoản có chữ thanh toán hoặc đã qua xem xét trùng.
- **Danh sách từ khóa** ở một chỗ: `pf_private.same_intermediaries()`, `same_topup_words()`, `same_payment_words()`.

## D-025 — Đòi nợ lịch sự kèm QR + tự gạch nợ khi tiền về; mục tiêu tiết kiệm tự chạy (migration 019, 1.3.0)

- **Bối cảnh:** chủ sở hữu muốn "tự động hết" (D-023): người nợ thì nhắc giúp, tiền về thì tự gạch nợ; mục tiêu tiết
  kiệm thì tự gợi ý trích tiền khi lương về / cuối tháng chi ít.
- **Mã nội dung:** mỗi khoản nợ có mã 6 ký tự (≥2 chữ + ≥2 số, không giống từ hay mã ngân hàng) in trong mã QR nhắc nợ
  ("MOMA 8F3A2B"). Tiền về có mã đó = chắc chắn đúng khoản.
- **Tự gạch nợ (`pf_debt_settle`):** tiền vào khớp khoản PHẢI THU, tiền ra khớp khoản PHẢI TRẢ (kể cả nợ chia hóa
  đơn D-022). Điểm: mã nội dung (chắc chắn), đủ họ tên người trong nội dung (mạnh, tên 1 chữ chỉ là yếu), đúng số còn nợ
  (đủ) hoặc nhỏ hơn (một phần), "đang chờ" (quá hạn / vừa nhắc trong 30 ngày). Tự ghi khi: đúng mã, hoặc họ tên + đủ số
  tiền và chỉ một người (nhiều khoản của cùng người: khoản cũ nhất trước). Còn lại (≥40 điểm): đề xuất "Có phải Nam trả
  nợ?" một chạm; hai người cùng số tiền không tên → đề xuất cả hai, chọn một thì bỏ cái kia. Ghi = đảo giao dịch đã bắt
  (giữ lịch sử) + `DEBT_REPAY` cùng tài khoản/số tiền/giờ/nội dung/nguồn → tiền chỉ tính một lần, không thành thu nhập
  hay chi tiêu. Hoàn tác = đảo lần trả + tạo lại đúng giao dịch ban đầu, cặp đó không bao giờ đề xuất lại; "Hoàn tác"
  trong sổ nợ cũng đi đường này. Cron tự sửa nếu lần trả bị hủy nơi khác (tiền ban đầu được tạo lại).
- **Nhắc nợ:** lần đầu vào hạn trả, hoặc sau số ngày người đó hay trả (trung vị lịch sử) + 2 (mặc định 7); sau đó mỗi 7
  ngày (10 ngày từ lần 3), tối đa 6 lần; "Để sau 3 ngày". Tin nhắn soạn sẵn, giọng tăng dần nhưng lịch sự (đầu / nhắc
  lại / chắc chắn), kèm thẻ QR đúng số tiền + mã nội dung, gửi qua Zalo/Messenger một chạm (chỉ ghi "đã nhắc" khi thật
  sự gửi). Khoản PHẢI TRẢ: nhắc trước hạn 2 ngày, "Trả ngay" = tài khoản người nhận (lưu một lần) để sao chép + mã QR
  để quét trong app ngân hàng. Trợ lý có bước `REMIND_DEBT` → thẻ "Nhắc Nam trả 535.000 ₫? [Soạn tin & gửi]", và khi
  nói về nợ thì chủ động gợi ý nhắc các khoản phải thu quá hạn (tối đa 2).
- **Mục tiêu tự chạy:** kế hoạch mỗi mục tiêu (cần mỗi tháng, tốc độ 90 ngày, dự kiến xong, đúng/chậm tiến độ). Lương
  / thưởng / khoản về lớn (≥3tr và ≥40% thu nhập tháng thường) → "Trích X vào mục tiêu Y?" (X = mức cần mỗi tháng làm
  tròn lên 50.000đ, không có hạn thì 10% khoản về; không quá phần còn thiếu và tiền còn rảnh của tài khoản). Cuối tháng
  (2 ngày cuối, hoặc ngày 1 cho tháng trước) chi ít hơn ngân sách tổng (hoặc trung bình 3 tháng) ≥100k → "Dồn X dư vào
  mục tiêu?". Ưu tiên mục tiêu đang chậm, rồi hạn gần nhất. Một chạm "Trích" chạy `GOAL_ALLOCATE` trong cùng giao dịch.
  Bỏ qua 3 lần liên tiếp cùng loại → thôi gợi ý loại đó. Mốc 25/50/75/100% chúc mừng một lần. Không cần lệnh mới:
  GOAL_CREATE/UPDATE/ALLOCATE/RELEASE đủ cho trợ lý.
- **Thông báo:** im lặng 23:00–06:59 (để cron gửi gộp sau), nhắc người khác chỉ 08:00–20:59; mỗi việc báo một lần
  (`pf_push_log`), nhiều việc gộp một thông báo.

## D-026 — Ngân sách tự điều chỉnh + nhắc tốc độ chi; ghi nhanh ngoài ứng dụng (migration 020, 1.3.0)

Chủ sở hữu không phải tự đặt hạn mức, và ghi được một khoản mà không mở app.

- **Đề xuất ngân sách (`modules/budgets/plan.ts`, thuần, không I/O):** 90 ngày chi tiêu thật (đến hôm qua) từ RPC chỉ đọc
  `pf_budget_history` (một dòng mỗi giao dịch × danh mục, số tiền đã ghi sổ — chia hóa đơn chỉ còn phần của chủ sở hữu;
  giao dịch đã hủy/sửa tự triệt tiêu; cờ `recurring` = khớp lần định kỳ hoặc quy tắc chia tiền D-022). Gộp danh mục con vào
  danh mục chính (như `budget_spent`). Bỏ khoản cố định (đã có kế hoạch riêng) và khoản bất thường (≥5 giao dịch: > max(3 ×
  trung vị, 1.000.000đ); ít hơn: một khoản ≥10.000.000đ chiếm >60% tổng). Tốc độ = 60% 30 ngày gần nhất + 40% cả cửa sổ
  khi có hơn 1 tháng dữ liệu, nhân số ngày của tháng, +5%, làm tròn lên 50.000đ; dưới 30.000đ/tháng thì bỏ; cần ≥7 ngày
  lịch sử. So với hạn mức hiện tại: chênh ≥15% → "Nên tăng"/"Có thể giảm", không thì "Giữ nguyên". Tổng chi tiêu = tổng các
  đề xuất + chi cố định hằng tháng (`pf_read_recurring`, phần của chủ sở hữu khi có chia tiền).
- **Học thay vì cằn nhằn:** danh mục vượt >10% trong ≥2/3 tháng gần nhất → đề xuất "Mức thực tế" = trung bình đã chi
  những tháng vượt (không thấp hơn tốc độ hiện tại); danh mục đó không bị nhắc tốc độ hằng ngày, chỉ một gợi ý mỗi tháng.
- **Áp dụng:** `POST /v1/budgets/proposals/apply` ghi bằng `BUDGET_UPSERT` (kèm `expected_version`), bỏ qua hạn mức không
  đổi, id lệnh xác định (bấm hai lần = một lần). **Tháng mới tự chạy:** tháng chưa có ngân sách mà tháng trước có → cron
  ghi lại đúng các danh mục đó với hạn mức đề xuất mới (giữ "chuyển phần dư"), báo một lần. Lệnh do máy chủ khởi tạo
  dùng `p_device` null (pf_execute_command cho phép). Tắt được trong Cài đặt → Nhắc nhở.
- **Tốc độ chi (`GET /v1/budgets/pacing`):** mỗi ngân sách: còn lại trước hôm nay chia đều số ngày còn lại (tính cả hôm
  nay) = "mỗi ngày nên"; trừ phần đã chi hôm nay = "hôm nay còn tiêu được" (làm tròn xuống 1.000đ). "Nhanh" = vượt nhịp
  đều ≥20%, từ ngày 5 và đã dùng ≥25% hạn mức (một khoản lớn đầu tháng không phải xu hướng). Thẻ trang chủ, tiện ích Chi
  tiêu ("Hôm nay nên ≤ X") và thanh ghi nhanh dùng cùng số.
- **Thông báo:** tối đa 1 nhắc tốc độ/ngày (danh mục chạy nhanh nhất), chỉ 09:00–21:00, kiểm tra mỗi giờ một lần;
  "vượt" đã có cảnh báo 80%/100% sẵn; mỗi tháng tối đa 1 gợi ý mức thực tế. Khóa `pace:<ngày>`, `budget_fix:<tháng>`,
  `budget_auto:<tháng>` trong `pf_push_log`.
- **Ghi nhanh ngoài app (Android, `QuickSurfaces.kt`):** ô Cài đặt nhanh "Ghi chi nhanh" (TileService; màn hình khóa →
  mở khóa trước; Android 13+ có nút "Thêm" một chạm); "Thanh ghi nhanh" — thông báo cố định, mặc định TẮT, độ ưu tiên
  thấp, không âm thanh: Ghi chi / Ghi thu / Nhận tiền + "hôm nay đã chi / còn tiêu được"; khi Trợ lý có món quen của buổi
  hiện tại (D-023) thì hiện "Bánh mì 20k" một chạm. Màn hình khóa chỉ hiện "MoMa" (bản công khai, không số tiền); "Ẩn số
  tiền trên tiện ích" che số cả trên thanh. Tự hiện lại sau khởi động máy / cập nhật app. Lối tắt biểu tượng thêm "Chọn
  loại". Mọi nút chỉ mở khung ghi nhanh sẵn có (QuickEntryActivity) → khóa ứng dụng và hàng đợi offline áp dụng như cũ.
- **Món quen ngoài app:** khung ghi nhanh hiện "Sáng nay bạn ăn gì? [Bánh mì 20k]" (bản lưu của tiện ích trước, hết giờ
  buổi thì bỏ, rồi bản mới); chạm = `POST /v1/ai/routine/record` như chip trong app; mất mạng = xếp `TX_CREATE` với đúng id
  máy chủ tự tính (`moma-routine|chủ|ngày|buổi|món`) nên chỉ ghi một lần.

## D-027 — Kế hoạch & Dự toán: dự toán sự kiện, so thực tế, dự báo kế hoạch lớn (migration 021, 1.3.0)

Chủ sở hữu nói "tối thứ 7 đi nhậu với nhóm Nam" hay "bao giờ mua được nhà 2,5 tỷ"; MoMa dự toán từ chính thói quen của
họ, nhắc trước, rồi so với thực tế.

- **Dữ liệu kế hoạch, không phải sổ cái:** bảng pf_event_plan (sự kiện: thời gian, số người, người đi cùng, bạn bao hay
  chia, đi Grab/tự đi, dự toán, ngân sách = phần dự kiến của chủ sở hữu, thực tế khi chốt) và pf_life_plan (giá, % trả
  trước, vay, lạm phát giá/thu nhập — null = mặc định thị trường, mục tiêu liên kết). Không thêm loại lệnh vào
  pf_execute_command (tránh chồng bộ điều phối với 016–020); app và Trợ lý dùng RPC theo chủ sở hữu qua /v1/plans/*,
  id do client chọn nên gửi lại không tạo trùng. Tiết kiệm thật vẫn đi qua mục tiêu (GOAL_*, D-025).
- **Dự toán (modules/plans/estimate.ts, thuần):** 120 ngày chi tiêu (pf_plan_spend_rows, tối đa 1.200 dòng: tiền ra,
  phần của chủ sở hữu sau khi chia, số người của lần chia; bỏ tiền nợ, khoản định kỳ, chuyển khoản). Chi phí/người của các
  lần tương tự (hóa đơn chia → tổng/số người), pha với mức phổ biến theo trọng số n/(n+2) (nhậu 250k, ăn 150k, cà phê
  55k, tiệc 300k, du lịch 1,2tr/người/ngày). Grab đi-về = trung vị chuyến của chủ sở hữu (chưa có: 70k), về sau 22:00 ×1,3.
  Phát sinh 12% (nhậu)/8%. Tiệc/sinh nhật mặc định chủ sở hữu bao; tiệc tốt nghiệp thêm địa điểm (≥1tr) và chụp ảnh. Phần
  của chủ sở hữu = phần chung chia đều + Grab của mình. Khoảng thấp/cao từ phân vị của chính họ (≥4 mẫu) hoặc 0,75×/1,4×.
  Giả định luôn được nói rõ.
- **Học:** kế hoạch đã chốt cùng loại → tỷ lệ thực tế/dự toán (trung vị, giới hạn 0,6–1,8, kéo về 1 khi ít mẫu) nhân vào lần
  sau.
- **Thực tế:** chuyến Grab trong [bắt đầu − 2h, kết thúc + 4h] (đi và về khuya), khoản khác trong [−1h, +2h]; tính phần của
  chủ sở hữu (sau chia), chia nhóm ăn uống / đi lại / khác; so sánh "Thực tế 1.020.000đ, vượt 20% so với dự toán, chủ yếu do
  ăn uống" (±10% = đúng dự toán). Khi sự kiện đang diễn ra chỉ tính tới hiện tại.
- **Cron (unPlanSweep, ngoài giờ yên lặng 23:00–06:59):** nhắc trước 30h–3h một lần ("Ngày mai: … dự kiến ~900k (bạn
  ~350k) · VCB còn 2,1tr, đủ"); trong sự kiện chi ≥85% ngân sách → báo một lần; 8h sau khi kết thúc tự chốt thực tế + báo
  "Thực tế vs Dự toán"; ngày 1 hằng tháng từ 09:00 một dòng tiến độ các kế hoạch lớn (khóa plan-done:, plan-month:).
- **Kế hoạch lớn (modules/plans/project.ts, thuần):** thu/chi tháng = trung vị tối đa 6 tháng đủ gần nhất (một tháng chi
  bất thường không làm lệch; tháng hiện tại bỏ). Tiền sẵn có = tài sản − nợ phải trả − tiền đã dành cho mục tiêu; kế hoạch
  có mục tiêu riêng chỉ tính tiền của mục tiêu đó. Mô phỏng theo tháng (≤600): thu nhập tăng theo % (mặc định = lạm phát),
  chi tăng theo lạm phát 3,5%, tiền để dành lãi 4,5%/năm, giá tăng theo loại (nhà 6%, xe 1,5%…); đạt khi đủ phần trả
  trước; vay = phần còn lại, trả góp niên kim. Thêm "nếu tiết kiệm thêm 1tr/2tr", "thu nhập +7%/năm", "trả trước 20%".
  Giả định thị trường qua MarketAssumptions — để thay bằng nguồn dữ liệu thị trường (giá vàng, CPI, lãi suất) sau này.
  App có bản sao công thức (plans_models.dart) để kéo thanh trượt thấy kết quả ngay, cả khi offline; số lưu luôn từ máy chủ.
- **Trợ lý:** bước PLAN_EVENT / PLAN_LIFE thành lệnh gọi rủi ro thấp (POST /plans/events, /plans/life; hỏi giá thì
  /plans/events/estimate không lưu); máy chủ điền sẵn số dự toán/dự báo vào thẻ trước khi gửi về; ANSWER PLANS liệt kê.
- **Giới hạn CPU (gói miễn phí, 10 ms/yêu cầu):** chuẩn hóa chữ và cờ "chuyến xe"/"ăn uống"/giờ VN tính trong Postgres
  (pf_private.ai_norm), Worker chỉ so chuỗi: 1.200 dòng ≈ 2 ms; mô phỏng 600 tháng × 5 kịch bản < 1 ms.
- App: tab "Dự toán" trong Kế hoạch, trang sự kiện (dự toán + "Thực tế vs Dự toán"), trang kế hoạch lớn (biểu đồ tích lũy
  vs cần có, thanh trượt), đường dẫn /plans, /plans/event/:id, /plans/life/:id.

## D-028 — Vòng đời dữ liệu, giám sát dung lượng, tối ưu chi phí AI; chỉ dùng gói miễn phí (migration 022)

- **Quyết định chủ sở hữu (2026-11-29):** không bao giờ dùng gói trả phí (Workers Paid, Supabase Pro). Chỉ trả tiền AI.
  Khi gần đầy chỉ dùng phương án miễn phí: siết thời gian giữ, lưu trữ năm cũ sang R2 (JSONL nén), hoặc chuyển sang
  Postgres miễn phí khác (schema lõi giữ Postgres thuần). Việc nặng chạy ở GitHub Actions (repo công khai) thay vì Worker.
- **Giữ / nén / xóa theo bảng chính sách** pf_private.retention_policy (thêm bảng mới = thêm 1 dòng; bảng/cột chưa có thì
  bỏ qua). Giữ mãi sổ cái, dữ liệu cốt lõi, ghi nhớ đã học, quyết định chống đề xuất lại. Nén payload webhook (90 ngày, giữ
  mã tham chiếu), bỏ lời giải thích phân loại (180 ngày), gộp chi phí AI theo tháng/model/tính năng (90 ngày) và kiểm toán
  theo tháng (365 ngày). Xóa idempotency (60 ngày > outbox 30 ngày), feed đồng bộ (30), khóa push (90), job xong (14),
  thông báo đã đọc (120), rate-limit hết hạn, ảnh R2 mồ côi. Chạy theo lô có LIMIT, lặp tới khi hết, idempotent.
- **Chưng cất:** tháng đã khóa sổ → pf_month_stat (đếm, tổng, trung bình, trung vị theo danh mục) từ sổ cái; mốc
  month_stat_through tránh quét lại tháng rỗng; tính lại tháng trước trong 10 ngày đầu tháng.
- **Lịch:** GitHub Actions moma-maintenance.yml 03:30 VN → POST /v1/internal/maintenance (cron secret; ≤ 15 lô,
  snapshot tuần, 2 trang quét R2, tối đa 15 lần xóa/trang để dưới ~50 subrequest). Worker cron: 1 lô lúc 03:30, snapshot
  thứ Hai 04:00, quét R2 ngày 1–7 lúc 04:15.
- **Dung lượng:** pf_capacity_snapshot mỗi tuần (2 năm), dự báo tháng tới 80% bằng hồi quy 13 tuần, cảnh báo push +
  hộp thư một lần ở 60% / 80% (tự mở lại khi xuống dưới). GET /v1/system/capacity, POST /v1/system/cleanup; màn hình
  Cài đặt → "Dung lượng & chi phí". Đo e2e: ≈ 2,2 KB/giao dịch trước, ≤ 1,25 KB sau chính sách → ~35–40 năm trên 500 MB
  với 15 giao dịch/ngày (chi tiết docs/capacity.md).
- **Chi phí AI:** tắt thinking (deepseek-flash mặc định bật, tính token suy luận như output); tiền tố prompt ổn định
  (system không chứa dữ liệu theo yêu cầu; dữ liệu ít đổi trước, dữ liệu theo yêu cầu sau) để DeepSeek cache; quy tắc trước
  AI sau, memo cùng nội dung trong một lượt quét; giới hạn output theo việc; ghi chi phí thật theo cache hit/miss và giờ
  cao/thấp điểm, gắn nhãn tính năng (pf_ai_usage.feature, pf_ai_reserve 6 tham số; gateway tự lùi về 5 tham số nếu chưa
  chạy 022). Ước ≈ $0,45–0,5/tháng cho một người (~12–13 nghìn đồng), dùng rất nhiều ≈ $1,2.
