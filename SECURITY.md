# Chính sách bảo mật

MoMa xử lý dữ liệu tài chính cá nhân, nên mọi báo cáo lỗ hổng được ưu tiên cao nhất.

## Báo cáo lỗ hổng

- **Không** mở issue công khai, pull request hay thảo luận công khai cho lỗ hổng.
- Gửi báo cáo riêng qua GitHub: **Security → Report a vulnerability**
  ([mở form](https://github.com/NhanSamLe/money-manage-app/security/advisories/new)). Nếu form chưa mở, tạo issue chỉ ghi
  "Cần kênh liên hệ bảo mật" (không kèm chi tiết) để được liên hệ riêng.
- Nêu rõ: phiên bản (`VERSION` hoặc **Cài đặt → Giới thiệu MoMa**), thành phần (app, API, cơ sở dữ liệu), các bước tái hiện,
  tác động dự kiến. Dùng dữ liệu giả; không gửi dữ liệu tài chính, mật khẩu hay khóa thật.
- Chủ dự án cố gắng phản hồi trong vòng 7 ngày, thống nhất thời điểm công bố sau khi có bản sửa và ghi nhận người báo cáo nếu
  bạn muốn.

Ngoài phạm vi: tấn công từ chối dịch vụ, kỹ thuật xã hội, máy đã root hoặc đã bị chiếm quyền, lỗ hổng của dịch vụ bên thứ ba
(Supabase, Cloudflare, SePay, OneSignal, DeepSeek) không do cách MoMa dùng chúng.

## Phiên bản được hỗ trợ

| Phiên bản | Hỗ trợ bảo mật |
|---|---|
| Bản phát hành mới nhất trên GitHub Releases và nhánh `main` | Có |
| Bản cũ hơn | Không — app tự đề nghị cập nhật |

## Tóm tắt mô hình mối đe dọa

| Tài sản | Mối đe dọa | Biện pháp |
|---|---|---|
| Sổ cái | Ghi sai, ghi trùng, sửa lịch sử | Chỉ ghi qua RPC nguyên tử; bút toán cân bằng và bất biến (sửa bằng đảo); lệnh idempotent theo `command_id`; `expected_version` chống ghi đè |
| Tài khoản chủ sở hữu | Người lạ đăng ký hoặc dùng API | Tắt đăng ký công khai; chỉ `OWNER_EMAIL` kích hoạt bằng mã qua email; JWT kiểm tra issuer, audience, hạn và gắn chủ sở hữu + thiết bị đã đăng ký; thu hồi được thiết bị |
| Khóa dịch vụ | Lộ service-role key, khóa AI, SePay, OneSignal | Chỉ là Cloudflare Worker secrets; app chỉ có publishable key; gitleaks trong CI; khóa lộ phải được xoay vòng |
| Dữ liệu trong DB | Truy cập trực tiếp bằng khóa công khai | RLS trên mọi bảng; hàm `SECURITY DEFINER` chỉ cấp cho `service_role` |
| Webhook ngân hàng | Giả mạo giao dịch | Xác thực SePay bằng API key hoặc HMAC, so sánh thời gian hằng; sự kiện nguồn có id duy nhất |
| Lệnh định kỳ | Gọi `/internal/tick` trái phép | Header `x-cron-secret`; mỗi thông báo chỉ gửi một lần |
| AI | Prompt injection khiến ghi sai, lộ dữ liệu | AI chỉ đề xuất; máy chủ kiểm tra từng id, số tiền, ngày và schema lệnh; việc rủi ro cao chờ xác nhận; mọi bước tự ghi hoàn tác được. AI không nhận số tài khoản, số dư hay ảnh |
| Điện thoại | Người khác cầm máy, sao lưu lộ dữ liệu | Khóa PIN (PBKDF2-SHA256, 120.000 vòng) + sinh trắc học; phiên và hàng đợi trong Android Keystore; `allowBackup=false`; chỉ HTTPS |
| Thông báo trên máy | Thu thập quá mức | Phân tích trên máy, chỉ gửi giao dịch đã tách; không xin quyền SMS hay Trợ năng |
| Bản cập nhật | APK giả | APK ký bằng khóa riêng (Android từ chối cài đè khác khóa); app chỉ đọc GitHub Releases của repo này |
| Nhật ký | Lộ nội dung nhạy cảm | Chỉ ghi `request_id`, đường dẫn, mã lỗi; không ghi nội dung thông báo, OTP, mật khẩu, khóa |

Rủi ro còn lại đã biết: chưa có sao lưu/khôi phục tự động đã diễn tập (xem `docs/DEPLOYMENT.md` mục 6); thông báo Android không
phải nguồn đã xác minh của ngân hàng nên chênh lệch số dư được đưa ra để chủ sở hữu xử lý.

## Quy tắc cho người đóng góp

- Không commit secret, `.env`, `*.jks`, `*.keystore`, `key.properties`. Chạy `gitleaks detect --source .` trước khi push.
- Không ghi log nội dung thông báo gốc, OTP, mật khẩu hoặc khóa.
- AI không bao giờ ghi sổ trực tiếp; mọi thay đổi sổ cái đi qua RPC trong `supabase/migrations`.
- Secret đã từng xuất hiện trong chat, ảnh chụp màn hình hoặc nhật ký phải được xoay vòng.
