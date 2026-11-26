# Chính sách bảo mật

MoMa xử lý dữ liệu tài chính cá nhân. Mọi lỗ hổng được xử lý ưu tiên cao nhất.

## Báo cáo lỗ hổng

- **Không** mở issue công khai cho lỗ hổng bảo mật.
- Liên hệ trực tiếp chủ sở hữu dự án qua kênh riêng (email hoặc GitHub Security Advisories khi repository đã được đưa lên GitHub).
- Nêu rõ: phiên bản (`VERSION`), các bước tái hiện, tác động dự kiến. Không gửi dữ liệu tài chính thật.

## Phiên bản được hỗ trợ

| Phiên bản | Hỗ trợ bảo mật |
|---|---|
| Nhánh `main`, bản phát hành mới nhất | Có |
| Bản cũ hơn | Không |

## Nguyên tắc bắt buộc (trích AGENTS.md)

- Một chủ sở hữu duy nhất; đăng ký công khai của Supabase luôn tắt.
- Không có service-role/secret key trong ứng dụng hay trong repository. Secret chỉ nằm ở Cloudflare Worker secrets.
- Khóa ký APK (`*.jks`, `*.keystore`) và `key.properties` không bao giờ được commit.
- Không ghi log nội dung thông báo gốc, OTP, mật khẩu hoặc khóa.
- Sổ cái chỉ được ghi qua RPC nguyên tử phía cơ sở dữ liệu; AI không ghi sổ trực tiếp.
- Mọi secret đã từng xuất hiện trong chat, ảnh chụp màn hình hoặc nhật ký phải được **xoay vòng (rotate)**.

## Quét bí mật

CI chạy `gitleaks` trên mỗi pull request. Chạy cục bộ trước khi push: `gitleaks detect --source .`.
