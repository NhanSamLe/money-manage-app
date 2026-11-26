# 02 — UX/UI và Setup Wizard

## Design system
Android Material 3, light/dark theo hệ thống, spacing 4/8/12/16/24, touch ≥48dp, font hệ thống; xanh cho tiền vào, đỏ cho tiền ra nhưng kèm dấu +/− và text. Không ép người dùng qua form dài. 5 bottom tabs: Tổng quan, Giao dịch, nút +/AI, Kế hoạch, Tài khoản. FAB mở sheet Quick entry với bàn phím, mic, ảnh, thu/chi/chuyển/nợ. Mỗi màn hình có empty, loading, partial/stale, offline, retry, error. Vietnamese copy, không hiển thị mã kỹ thuật mặc định. Đơn vị VND, format 1.250.000 ₫. Dữ liệu demo chỉ ở dev, banner rõ.

## 1. First launch — chưa có tài khoản hoặc đã có

| Step / Screen | UI và hành vi | Validation / lỗi |
|---|---|---|
| W00 Welcome | Logo, "Quản lý tiền của bạn, ít nhập liệu hơn". 2 CTA: Tôi đã có tài khoản / Thiết lập lần đầu. | Không nút Đăng ký. Không xin quyền Android ở welcome. |
| W01 Connect | Domain backend mặc định từ build config hoặc nhập domain HTTPS của chính mình; nút Kiểm tra kết nối; hiện instance name/version. | Không chấp nhận HTTP/redirect khác host, IP private/localhost trong production. GET health trả minimal, không tiết lộ owner email. Sai domain → sửa. |
| W02 Existing | Email, password, Đăng nhập, Quên mật khẩu. | Generic lỗi; network retry; owner chưa setup thì gợi ý setup, không tự tạo. |
| W03 Setup permission | Hướng dẫn: đã triển khai cloud qua tài liệu, tạo mã thiết lập một lần và email chủ sở hữu. Nhập email và mã. | Server chỉ cho email đã cấu hình; mã secret dài ngẫu nhiên, rate limit, hết hạn. Không auto sign-up. Nếu owner tồn tại → đăng nhập. |
| W04 Invite | "Kiểm tra email của bạn"; Mở ứng dụng email; Gửi lại (cooldown 60s); Đổi địa chỉ chỉ qua operator trước khi bind. | Backend gửi Supabase invite tới email cố định. Nếu email provider lỗi, báo resend có kiểm soát, không tạo owner thứ hai. |
| W05 Verify & password | HTTPS App Link được xác minh; xử lý invite/recovery type đúng SDK; đặt mật khẩu + confirm; hiển thị checklist ≥12 ký tự; continue. | Token invalid/expired → resend; không mở link host lạ, không log token; không lưu token clipboard. |
| W06 Profile | Tên hiển thị, tiếng Việt, VND, Asia/Ho_Chi_Minh mặc định. | Không bắt địa chỉ/CCCD/số điện thoại. |
| W07 Accounts | Chọn VCB, MoMo, Tiền mặt mặc định; thêm TPBank/MB/ZaloPay/VNPAY/Khác; nickname, last4 hoặc tự đặt. | Không yêu cầu password/OTP. Nhiều account cùng bank được phép. |
| W08 Sources | Hai switch API / Notification cho từng account. Có giải thích phạm vi và phí. API unknown disabled; Notification có checklist quyền. | Bật API cần chọn adapter, mapping + xác nhận quota. Tắt cả hai vẫn dùng manual. |
| W09 Notification permission | Hiện chính xác app nào được thu; CTA Mở cài đặt quyền truy cập thông báo; kiểm tra quyền khi quay lại; chọn app, tài khoản. | Android cấp listener quyền rộng, app lọc allowlist. Không yêu cầu Accessibility/SMS. Cho phép Bỏ qua. |
| W10 Opening balance | Mỗi account: số dư hiện tại + thời điểm snapshot, hoặc chưa biết. Tùy chọn import từ đầu tháng; giải thích không cộng hai lần. | Không mặc định 0 khi chưa biết. Chọn cutoff, xem preview; không nhập password. |
| W11 Test | Trạng thái nguồn, nhận một giao dịch thực tế tự phát sinh hoặc dùng fixture demo (không book); đối chiếu với app ngân hàng. | Không yêu cầu phải chuyển tiền để setup; có thể bỏ qua, source Unverified. |
| W12 Preferences | Ngân sách tùy chọn, mục tiêu, AI mode OFF/FREE/PAID, privacy, nhắc hàng ngày tùy chọn. | Paid off mặc định; hiện giá và consent trước khi bật. |
| W13 Finish | Summary tài khoản/nguồn/coverage, Hoàn tất. | Lưu wizard step server và local, restart tiếp tục. Không setup owner lại. |

Owner creation state: UNINITIALIZED → INVITE_PENDING → VERIFIED_UNBOUND → ACTIVE. Deployment secret disabled after bind. On interruption resume from auth state, not local flags alone. Profile setup completion separate from auth activation. Existing user on new device login then fetch configuration; device collection starts disabled until permission and allowlist explicitly configured.

## 2. Authentication screens
Login email/password; forgot: nhập email, luôn phản hồi "Nếu tài khoản hợp lệ, liên kết đã được gửi"; reset link mở màn hình xác minh nguồn, đặt lại password, success rồi yêu cầu login lại. Token expiry/replay handled by Supabase; after password reset revoke refresh sessions globally, access JWT TTL ngắn còn tồn tại tới hết hạn unless server epoch/revocation check. Change password recent auth; revoke devices, change email qua flow verify old/new and update owner record after verified. Optional local app lock biometric when resumed >5min; never replace server auth. Logout stops collector, clears tokens/cache per choice and warns unsynced events; do not silently discard queue. Recovery when lost phone: dashboard revoke session, login new device; provider webhook still server-side.

## 3. Main screens and flows

| Screen | Main components | Actions and edge cases |
|---|---|---|
| H01 Tổng quan | Net worth; income/expense/remaining; month selector; assets list; data freshness/unknown amount; today; due debt; budget; AI insight. | Tap card opens filtered list. Hide amounts privacy toggle. Stale badge, no fake zero. |
| H02 Giao dịch | Timeline grouped day; amount, account, category, contact, status, source icons; search/filter. | Review inbox count. Long press multi-select category only; destructive changes require confirm. |
| H03 Transaction detail | Amount/direction, date, account, category, purpose, note, merchant/contact, evidence sources, linked transfer/debt, audit. | Edit category/note, split, mark transfer, match, reverse; amount correction reversal preview. |
| H04 Quick entry | Text field "Ăn sáng 45k", shortcuts account/category, voice/image/share. | Parse deterministic, AI optional; preview one card with save/correct; if trusted simple and owner enables quick-save, save + undo. Ambiguous ask 1 targeted question. |
| H05 Review inbox | Unclassified, ambiguous duplicates, unknown account, parse failed, missing leg, balance mismatch. | One-tap suggested category; merge only with evidence; keep separate; defer. Show pending vs booked explicitly. |
| H06 Accounts | Bank/wallet/cash/savings/card, balance as-of, freshness, reserved; add/archive. | Per account source switches, diagnostics, reconciliation, manual balance snapshot. |
| H07 Source detail | API switch, provider capability, auth health, last cursor, quota & upstream billing state; Notification switch, device permission, package mapping, parser. | Test, Sync now, pause, disconnect, revoke; confirm cost warning. Unknown API cannot enable. |
| H08 Debts | Phải thu / phải trả, overdue, contact totals, detail timeline. | Create, repay, partial, extend, write-off; match existing transaction (no duplicate). |
| H09 Saving goals | Progress, amount/target/date, funding account/reserved; available to spend. | Allocate/release/transfer to actual savings account; do not double count. |
| H10 Budgets | Month/category caps, used, remaining, uncategorized; threshold. | Create/edit budget; rollover optional; budget overspend warn not block money movement. |
| H11 Recurring | Due, expected amount, next date, matched/unmatched; subscription. | Pause, skip, mark paid by matching; never create actual expense merely when due. |
| H12 Analytics | Month/year range, charts, compare, top merchants/categories, cash flow, net worth, coverage. | Export; filters affect both metrics and chart; 0 denominator N/A. |
| H13 AI chat | History optional, suggested prompts; cards for proposals and read query answers. | Cancel; accept/edit; show estimated cost mode; free quota exhausted → manual/rule, not charged. |
| H14 Settings | Profile/security, device list, app lock, categories/rules, sources, AI provider/model/budget, export/backup, diagnostics. | No secrets displayed. Destructive action recent auth + confirm text. |

## 4. UX microflows
- Push from bank arrives → local notification parsing → quiet ingestion → optional own notification: "−120.000 ₫ • Chưa rõ mục đích" with classify/defer. Android notification action requires unlocking for sensitive data; default lock-screen content hidden. Never show PII on lock screen. Daily digest only if enabled.
- "500k tối qua là cho Nam mượn" → search candidate(s) → one candidate with evidence → proposed reclassification + debt create atomically; multiple candidates pick; no candidate ask create; no duplicate debit.
- Transfer VCB to MoMo: show one transfer, two legs, missing leg pending; no expense. If funding bank pays merchant directly via MoMo, classify expense on bank, not wallet movement; ambiguous review.
- Offline create shows pending, cached totals labeled; on server conflict show side-by-side, not silent last-write-wins. Undo creates compensating command if already posted.
