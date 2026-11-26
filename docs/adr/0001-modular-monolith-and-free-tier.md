# ADR-0001: Kiến trúc nguyên khối mô-đun, gói miễn phí, một chủ sở hữu

- Trạng thái: Chấp nhận
- Ngày: 2026-11-27
- Nguồn: `spec/docs/11-engineering-standards.md` (ADR-001), `spec/docs/06-architecture-security.md`

## Bối cảnh
Ứng dụng tài chính cá nhân cho một người, chi phí hạ tầng bằng 0, không tự lưu trữ máy chủ.

## Quyết định
- Flutter (Android) + Cloudflare Worker (Hono/TypeScript) + Supabase PostgreSQL/Auth.
- Nguyên khối mô-đun, phụ thuộc một chiều presentation → application → domain; không vi dịch vụ, không broker.
- Sự thật tài chính nằm trong PostgreSQL: sổ cái kép, ràng buộc, RPC nguyên tử. Không nhân đôi logic tài chính ở TypeScript/Dart.
- Một chủ sở hữu duy nhất (singleton), đăng ký công khai tắt. Worker giữ service key; ứng dụng chỉ giữ publishable key.

## Hệ quả
- Đơn giản, rẻ, dễ kiểm thử bất biến ở tầng cơ sở dữ liệu.
- Hạn chế quota miễn phí, không SLA; cần đối soát và hàng đợi offline.
- Mở rộng đa người dùng cần thiết kế lại phần singleton (xem ADR-0002 khi có quyết định).
