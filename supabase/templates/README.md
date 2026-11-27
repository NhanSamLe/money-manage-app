# Mẫu thư Supabase Auth cho MoMa

Dán từng mẫu vào Supabase → Authentication → Emails (Templates). Mỗi mẫu dùng `{{ .Token }}`; không có nút liên kết nên không phụ thuộc Site URL.

| Mẫu Supabase | File | Subject (tiêu đề thư) |
|---|---|---|
| Invite user | `invite.html` | Mã xác nhận thiết lập MoMa |
| Reset password | `recovery.html` | Mã đặt lại mật khẩu MoMa |
| Confirm sign up | `confirmation.html` | Xác nhận email MoMa |
| Magic link | `magic_link.html` | Mã đăng nhập MoMa |
| Change email address | `email_change.html` | Xác nhận đổi email MoMa |
| Reauthentication | `reauthentication.html` | Xác thực lại thao tác MoMa |

Tên người gửi "MoMa": Authentication → SMTP Settings → Sender name (cần SMTP riêng; với SMTP mặc định Supabase vẫn hiện "Supabase Auth").
Site URL: đặt `https://moma-api.superaicore.indevs.in` (không dùng localhost).
