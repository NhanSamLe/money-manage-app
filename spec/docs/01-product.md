# 01 — BRD / SRS: Product scope

## 1. Business objective
Một nơi duy nhất để biết đang có bao nhiêu tiền, tiền đi đâu, tháng này thu/chi/tích lũy bao nhiêu, ai nợ ai, còn ngân sách nào. Hệ thống ưu tiên đọc giao dịch thay vì bắt chủ sở hữu ghi từng khoản. Mỗi user là một chủ sở hữu duy nhất của một deployment, nhiều thiết bị Android của chính họ; không marketplace, không phân quyền tổ chức, không chuyển tiền thực.

### Success criteria (mục tiêu cần đo, không phải cam kết)
- Thao tác quick entry dưới 5 giây với câu đơn giản; xác nhận mục đích 1–2 chạm; không bắt nhập trường không biết.
- 100% bút toán cân; 0 ghi trùng trong bộ fixture; đối soát sao kê cuối kỳ chênh 0 hoặc hiển thị chênh rõ ràng.
- Mục tiêu recall ≥95% trên tập giao dịch từ nguồn đã POC, không áp dụng cho nguồn không có API/notification; precision phân loại ≥95% trên tập quen thuộc; không tự ghi khi thiếu dữ kiện quan trọng.
- Chi phí hạ tầng mục tiêu 0đ/tháng trong hạn mức. AI trả phí tự chọn, mặc định trần 1 USD/tháng khi bật; không auto-upgrade.

## 2. Actor và phạm vi
Owner: cấu hình, thao tác toàn bộ tài chính. Android collector: thu sự kiện được phép, gửi đã lọc. Backend worker: auth, commands, ingestion, jobs. External provider: API read-only / webhook / SMTP / AI. Scheduler: sync, reconciliation, reminders. Không actor admin thứ hai; người triển khai dùng dashboard cloud ngoài app. Contacts là người liên quan công nợ, không phải tài khoản đăng nhập.

P0: setup/auth, account, quick transaction, ledger, API + Notification toggles, review/dedup/reconcile, dashboard, debt, saving, budget, AI quick actions, export. P1: recurring, analytics, notifications/reminders, split bill, attachment scan/voice, richer search. P2: investment lots/valuation, multi-currency (không triển khai logic quy đổi hiện tại), email receipt ingestion, import thêm định dạng, web UI. MVP theo gates, không cần chờ P2.

## 3. Functional requirements

| ID | Priority | Requirement / acceptance |
|---|---|---|
| AUTH-01 | P0 | First launch: đã có tài khoản / chưa có tài khoản. Không public signup. Wizard chỉ tạo/bind một owner sau invite xác minh. |
| AUTH-02 | P0 | Đăng nhập email/password; show/hide; lỗi chung, rate limit, phiên refresh, khóa biometric cục bộ tùy chọn. |
| AUTH-03 | P0 | Quên/reset password bằng email link HTTPS, một lần, hết hạn; resend cooldown; logout mọi phiên theo policy. |
| AUTH-04 | P0 | Danh sách thiết bị/phiên, revoke, logout local hoặc toàn bộ; owner email đổi bằng reauth và xác minh. Không mất dữ liệu ledger. |
| SET-01 | P0 | Wizard resumable: backend domain → invite → password → locale → tài khoản → nguồn → baseline số dư → kiểm thử → finish. Bỏ qua nguồn tùy chọn. |
| ACC-01 | P0 | Thêm bank/wallet/cash/savings/credit card, tên tùy chỉnh, last4, opening balance và as-of; một bank có nhiều account. |
| ACC-02 | P0 | Lưu trữ account (archive); không xóa khi đã có bút toán; ẩn dashboard tùy chọn; số dư tại thời điểm và freshness. |
| ACC-03 | P1 | Tài khoản tài sản/đầu tư thủ công, định giá as-of, không tự giả định tăng trưởng. |
| TX-01 | P0 | Thu/chi/chuyển nội bộ/hoàn tiền/điều chỉnh/cho vay/vay/trả nợ/lãi/phí; nhập nhanh số tiền + mô tả; account mặc định rõ ràng. |
| TX-02 | P0 | Chi tiết, tìm kiếm, lọc kỳ, account, danh mục, contact, tag, nguồn, pending, review; edit/reversal có audit. |
| TX-03 | P0 | Giao dịch nhận từ nguồn tự động có source provenance, thời gian, ID, phân loại, status, amount; thiếu trường cho review. |
| TX-04 | P0 | Import CSV theo mapping preview, detect duplicate; import PDF/ảnh P1 qua xác nhận; không upload file nhạy cảm công khai. |
| TX-05 | P0 | Split danh mục trong một giao dịch; tổng split đúng số tiền; hoàn tiền liên kết giao dịch gốc. |
| TX-06 | P1 | Attach hóa đơn, ghi âm nhập nhanh, chia sẻ ảnh qua Android share sheet; OCR local trước; review số tiền. |
| CAT-01 | P0 | Danh mục cha/con, icon, thu/chi; danh mục tự tạo; archive; category sửa không đổi amount. |
| CAT-02 | P0 | Rules do owner xác nhận, merchant mapping, tags; ưu tiên rule cụ thể và phiên bản; một giao dịch nhiều tags. |
| INT-01 | P0 | API và Notification toggle độc lập global/account/device, 4 tổ hợp; bật khi capability hợp lệ, tắt không xóa lịch sử. |
| INT-02 | P0 | Adapter registry đa ngân hàng/ví, account mapping, verification, health, last sync, gap, source permissions. |
| INT-03 | P0 | Webhook auth, retry/poll/backfill nếu có, dedup nhiều nguồn và nhiều thiết bị, sync checkpoint. |
| INT-04 | P0 | Listener allowlist, on-device sanitize, offline durable queue, parser version, không đọc OTP. |
| INT-05 | P0 | Dữ liệu thiếu/trùng/mismatch → Inbox review; đối soát số dư/sao kê; không tự bù. |
| INT-06 | P0 | Provider fee guard: chỉ kết nối live sau xác minh không tính phí ngoài ý muốn; disconnect upstream có hướng dẫn. |
| DEBT-01 | P0 | Tôi nợ / người khác nợ tôi; contact, gốc, lý do, ngày phát sinh, đến hạn tùy chọn; nhiều khoản mỗi contact. |
| DEBT-02 | P0 | Cho vay/đi vay, thanh toán một phần/toàn bộ, lãi, gia hạn, xóa nợ, lịch sử; principal không phải thu/chi. |
| DEBT-03 | P1 | Ứng hộ/chia tiền nhóm, link giao dịch, nhắc nợ cho chính mình; không tự gửi tin cho người khác. |
| SAV-01 | P0 | Mục tiêu, số tiền, hạn, phân bổ từ tài khoản thật; chuyển ngân hàng tiết kiệm không là chi. |
| SAV-02 | P0 | Withdraw allocation, progress, mục tiêu hoàn thành; tổng phân bổ không vượt số dư khả dụng theo policy. |
| BUD-01 | P0 | Ngân sách tháng/danh mục, cảnh báo 80%/100%, remaining và carry-over tùy chọn, không tự chặn chuyển tiền thật. |
| REC-01 | P1 | Recurring income/expense templates, nhận diện kỳ, reminder, match actual, không tự book forecast. |
| REP-01 | P0 | Tổng tài sản ròng, số dư, thu nhập, chi tiêu ròng, dư thu chi, tỷ lệ tiết kiệm, cash flow; kỳ tháng/năm/tùy chọn. |
| REP-02 | P0 | MoM, YoY, top merchant/danh mục, unresolved amount và coverage; 0 denominator → N/A. |
| REP-03 | P1 | Trend, forecast dựa trên lịch và ngân sách, không là số dư thật; xuất CSV/JSON. |
| AI-01 | P0 | Chat/quick entry tiếng Việt, slang, ngày tương đối; structured proposal; confirmation khi ambiguous/high impact. |
| AI-02 | P0 | Tự phân loại bằng rule trước, AI fallback; sửa category ghi nhận rule nếu đồng ý; model không tự đoán amount. |
| AI-03 | P0 | Natural language query qua whitelisted read tools; trả lời dựa trên số liệu DB; không tự tính tiền. |
| AI-04 | P0 | Free mode, paid opt-in, budget hard guard, tắt AI toàn bộ; redact dữ liệu. |
| AI-05 | P1 | Tổng kết, cảnh báo bất thường, gợi ý mục tiêu, recurring detection; không tự chuyển tiền. |
| OFF-01 | P0 | Xem cache + ghi nhanh offline; hàng đợi retry; giao dịch pending được phân biệt. |
| OPS-01 | P0 | Export toàn bộ dữ liệu, backup mã hóa, restore preview; usage/health/diagnostics, data retention. |
| OPS-02 | P0 | Mọi mutation audit; xóa dữ liệu cá nhân bằng typed confirm + recent auth; không xóa account nguồn ngân hàng. |

## 4. Non-functional requirements
| ID | Requirement |
|---|---|
| NFR-01 | Không thuê VPS, không cần máy cá nhân chạy liên tục; mọi thành phần cloud free trừ AI opt-in. Không upgrade tự động. |
| NFR-02 | API P95 đọc cached <1s, mutation online <2s mục tiêu điều kiện bình thường; AI async >2s hiển thị progress. Không SLA free-tier. |
| NFR-03 | Android min API 26 đề xuất; target theo SDK release và Play policy lúc build; Android 13+ POST_NOTIFICATIONS chỉ cho app tự gửi, không nhầm quyền listener. |
| NFR-04 | TLS, verified JWT, singleton, RLS deny, secrets server-side, local encryption, no OTP/password collection. |
| NFR-05 | WCAG-style contrast, TalkBack, font scaling, tiếng Việt rõ, dark mode, VND không dấu thập phân; action undo/confirm. |
| NFR-06 | Offline retry exponential jitter, idempotency, bounded batches, stale data 표시; không xóa queue trước ACK durable. |
| NFR-07 | 500 MB DB / free-tier quota; theo dõi dung lượng, raw event retention; không mất ledger vì retention. |
| NFR-08 | Log redacted, correlation id, audit immutable; không log JWT, financial raw notification, AI prompts nhạy cảm. |
| NFR-09 | Mỗi adapter versioned, capability-driven, contract tests; không hardcode nhà cung cấp vào ledger. |
| NFR-10 | RPO mục tiêu 7 ngày với backup định kỳ + offline cache; RTO mục tiêu một ngày thao tác thủ công; free không đảm bảo. |
