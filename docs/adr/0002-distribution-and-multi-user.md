# ADR-0002: Phân phối cho người khác dùng

- Trạng thái: **Đề xuất, chờ chủ sở hữu quyết định**
- Ngày: 2026-11-27

## Lựa chọn
- **A. Mỗi người một bản riêng** (dự án Supabase + Worker riêng): dữ liệu tách biệt, nằm trong gói miễn phí, phù hợp thiết kế singleton hiện tại. Cần ứng dụng cho phép nhập địa chỉ API (đã có ở Cài đặt).
- **B. Hệ thống dùng chung nhiều người**: phải bỏ ràng buộc singleton, cách ly dữ liệu theo người dùng, hạn mức AI/chi phí theo người, chịu trách nhiệm bảo vệ dữ liệu của người khác; gói miễn phí sẽ không đủ.

## Khuyến nghị
Hoàn thiện bản một chủ trước. Khi cần phân phối, chọn A. Cột `owner_id` đã có trong mọi bảng để mở đường cho B.
