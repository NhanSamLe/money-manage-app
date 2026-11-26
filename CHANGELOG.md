# Changelog

Định dạng theo [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), đánh số phiên bản theo
[Semantic Versioning](https://semver.org/lang/vi/). Số phiên bản gốc nằm ở file `VERSION`.

## [Unreleased]

### Added
- Migration 003: danh bạ, công nợ (cho vay/đi vay, thu/trả nợ có lãi, xóa nợ), mục tiêu tiết kiệm (đặt dành, không đổi sổ cái), ngân sách tháng (chuyển phần dư), danh mục cấp cha-con, khoản định kỳ và kỳ đến hạn.
- API: `/contacts`, `/debts`, `/goals`, `/budgets`, `/recurring` và 12 lệnh mới (tổng 15 lệnh).
- Ứng dụng: tab Kế hoạch (công nợ, tiết kiệm, ngân sách, định kỳ), nhập nhanh bằng câu tiếng Việt, nhập sao kê CSV.

### Fixed
- Bảng tổng quan tính phí chuyển khoản và nợ xấu là chi tiêu (BR-15, BR-19); trước đó bị loại nhầm.
- Giao dịch gắn với công nợ không thể bị đảo bằng `TX_REVERSE` (phải sửa trong mục công nợ).

## [0.1.0] - 2026-11-27

Phiên bản nền tảng đầu tiên (pre-release, chưa dùng cho dữ liệu thật).

### Added
- Monorepo: `apps/api` (Cloudflare Worker, Hono, TypeScript), `apps/android` (Flutter), `supabase/` (migration, mẫu thư), `spec/` (đặc tả v1.0).
- Cơ sở dữ liệu: baseline PostgreSQL (sổ cái kép, RLS, bảo vệ bút toán bất biến) và RPC lõi: thiết lập chủ sở hữu duy nhất, đăng ký thiết bị, `pf_execute_command` idempotent, các hàm đọc.
- Lệnh tài chính: `ACCOUNT_CREATE`, `TX_CREATE` (thu, chi, chuyển khoản có phí, tiền chưa phân loại), `TX_REVERSE`.
- API v1: xác thực JWT Supabase gắn với chủ sở hữu duy nhất, `/commands`, `/accounts`, `/transactions`, `/categories`, `/reports/summary`, `/setup/*`.
- Ứng dụng Android: màn chào, đăng nhập, thiết lập lần đầu, tổng quan, giao dịch, nhập nhanh, tài khoản, cài đặt.

### Quality
- Kiểm thử: bộ kiểm thử bất biến SQL (`supabase/tests`), 19 test đơn vị API (Vitest), 5 test Flutter; CI định nghĩa tại `.github/workflows/ci.yml`.
- Đóng gói: Application ID `vn.moma.app`, đánh phiên bản đồng bộ có kiểm tra tự động, ký phát hành bắt buộc khóa riêng.

### Known limitations
- Các lệnh khác trong `spec/contracts/commands.schema.json` trả `NOT_IMPLEMENTED` (công nợ, tiết kiệm, ngân sách, định kỳ, tích hợp ngân hàng, thông báo Android, AI).
- Chưa có kiểm thử trên thiết bị thật; xem `IMPLEMENTATION_STATUS.md` để biết chính xác phần nào đã chạy.
