# Changelog

Mọi thay đổi đáng chú ý của MoMa. Định dạng theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/), đánh số
theo [Semantic Versioning](https://semver.org/lang/vi/): trước bản hoàn chỉnh dùng `0.MINOR.PATCH` (MINOR khi có tính
năng mới, PATCH khi chỉ sửa lỗi), bản hoàn chỉnh đầu tiên là `1.0.0` (quyết định D-016). Số build `+N` luôn tăng.
Bản cài: [GitHub Releases](https://github.com/NhanSamLe/money-manage-app/releases).

## [Unreleased] — hướng tới 1.0.0

Đang phát triển trên nhánh chính, chưa phát hành.

### Added
- **Ghép chuyển khoản nội bộ** (migration 010, D-018): tiền ra ở một tài khoản và tiền vào ở tài khoản khác của chủ sở hữu
  được ghép thành một giao dịch chuyển khoản. Khớp chắc chắn thì tự ghép, chưa chắc thì đề xuất Đúng/Không; "Tách ra"
  hoàn tác. Lượt đối soát định kỳ quét lại 48 giờ.
- **Tự ghi từ thông báo không cần chạm**: tự gắn app ngân hàng/ví với tài khoản cùng thương hiệu hoặc tạo tài khoản mới với
  số dư khớp thông báo; chênh lệch số dư được đưa ra để chủ sở hữu xử lý. Gợi ý các app ngân hàng/ví đã cài.
- **Chia sẻ vào MoMa**: chia sẻ ảnh chụp chuyển khoản hoặc đoạn chữ từ app khác để ghi giao dịch (đọc chữ trên máy).
- **Trợ lý bằng giọng nói**: nói thay vì gõ (nhận dạng giọng nói của điện thoại, không lưu âm thanh) và đọc to câu trả lời.
- **Sửa tài khoản** (migration 011): đổi tên ngân hàng/ví, 4 số cuối và đặt số dư hiện tại (ghi bút toán điều chỉnh, giữ lịch sử).
- **Hộp thông báo trong app** (migration 012): mọi thông báo đẩy đã gửi được lưu lại, có trạng thái đã đọc và mở đúng màn hình.
- Trang giới thiệu (`website/`, GitHub Pages), README mới với ảnh chụp màn hình dữ liệu mẫu, `docs/architecture.md`.

### Changed
- Tiện ích QR nhận tiền có nút sao chép số tài khoản; số tài khoản hiển thị dạng che (`•••• 1234`) cho tới khi bấm xem.

## [0.2.1] — 2026-11-27

Bản sửa lỗi (build 3).

### Added
- Nhận tiền: logo ngân hàng ở giữa mã QR; nút Sao chép số tài khoản, Lưu ảnh và Chia sẻ ảnh mã QR; chạm vào mã để mở nhanh
  các lựa chọn.

### Fixed
- Tiện ích màn hình chính: bấm Ghi chi, Ghi thu hoặc dấu + không còn làm đơ màn hình; khung ghi nhanh hiện ngay trên màn hình
  chính, nếu không hiện được thì tự đóng sau vài giây.
- Nhận tiền và Kết nối ngân hàng không còn báo "Không tải được dữ liệu" khi nhiều màn hình cùng hỏi SePay (máy chủ chờ và thử
  lại theo giới hạn của SePay, lưu tạm danh sách tài khoản 60 giây).

## [0.2.0] — 2026-11-27

Bản tính năng lớn đầu tiên (build 2).

### Added
- **Kết nối ngân hàng qua SePay**: liên kết tài khoản đã xác minh, webhook tự ghi mọi khoản tiền vào/ra, số dư ngân hàng.
- **Nhận tiền VietQR** cho tài khoản đã liên kết, kèm số tiền và nội dung.
- **Đọc thông báo ngân hàng/ví trên máy** (NotificationListener, phân tích trên điện thoại).
- **Trợ lý tài chính AI**: ghi nhiều giao dịch từ một câu, hỏi số dư/công nợ/ngân sách/mục tiêu, đọc ảnh hóa đơn (OCR trên
  máy), ghi nhớ và học dần thói quen; tự động ghi bước rủi ro thấp kèm Hoàn tác.
- **Báo cáo mới**: biểu đồ danh mục, chi tiêu theo ngày/tuần, so với tháng trước; **phân tích & đề xuất** ngày/tuần/tháng.
- **Nhắc nhở thông minh** (migration 008): bữa ăn chưa ghi, tiền mặt cuối ngày, tổng kết, cảnh báo ngân sách; thông báo đẩy
  OneSignal; cron Worker và dự phòng GitHub Actions `moma-tick`.
- **Kế hoạch**: công nợ (cho vay/đi vay, thu/trả có lãi, xóa nợ), mục tiêu tiết kiệm thiết kế mới (vòng tiến độ, còn bao nhiêu
  tháng, lọc trạng thái), ngân sách tháng có chuyển phần dư, khoản định kỳ.
- **Khóa ứng dụng**: PIN 6 số, vân tay/khuôn mặt, tự khóa sau thời gian ở nền (D-017).
- **Tiện ích màn hình chính**: thao tác nhanh, chi tiêu hôm nay, QR nhận tiền, hỏi nhanh Trợ lý; ghi chi ngay trên màn hình chính.
- **Tài khoản & Đồng bộ**: mỗi tài khoản cho thấy đang tự ghi bằng Đồng bộ ngân hàng hay Thông báo Android.
- Hồ sơ (ảnh đại diện, tên, đổi mật khẩu); xuất Excel/CSV; nhập sao kê CSV; tự kiểm tra và cài bản cập nhật trong app.
- Đăng ký bằng email chủ sở hữu và mã qua thư (D-012); quên mật khẩu bằng mã.
- Thiết kế mới: logo dải lụa "M", giao diện sáng/tối, màn khởi động và giới thiệu động, logo chính thức của ngân hàng và ví,
  nền hoa văn kiểu tiền giấy, số dư đếm lên.
- Sửa, đổi danh mục, hủy giao dịch giữ lịch sử; tìm kiếm không dấu, lọc, tải thêm; hàng đợi offline bền vững.
- Kiểm thử end-to-end API với Postgres + PostgREST; kiểm thử luồng giao diện.

### Fixed
- Giao diện tối và "Theo hệ thống" hoạt động đúng; rời app không chạy lại màn khởi động.
- Nhận tiền và kết nối ngân hàng không còn báo lỗi tải dữ liệu.
- Bảng tổng quan tính phí chuyển khoản và nợ xấu là chi tiêu (BR-15, BR-19).
- Tháng báo cáo không hợp lệ trả 400 thay vì 503; giao dịch gắn công nợ không thể bị hủy bằng `TX_REVERSE`.
- Lỗi bố cục: thẻ Thu/Chi tràn chữ, ô chọn tài khoản tràn khi tên dài.

## [0.1.0] — 2026-11-27

Phiên bản nền tảng đầu tiên (pre-release, chưa dùng cho dữ liệu thật).

### Added
- Monorepo: `apps/api` (Cloudflare Worker, Hono, TypeScript), `apps/android` (Flutter), `supabase/` (migration, mẫu thư),
  `spec/` (đặc tả v1.0).
- Cơ sở dữ liệu: sổ cái kép, RLS, bảo vệ bút toán bất biến; RPC lõi: thiết lập chủ sở hữu duy nhất, đăng ký thiết bị,
  `pf_execute_command` idempotent, các hàm đọc.
- Lệnh: `ACCOUNT_CREATE`, `TX_CREATE` (thu, chi, chuyển khoản có phí, tiền chưa phân loại), `TX_REVERSE`.
- API v1: xác thực JWT Supabase gắn với chủ sở hữu, `/commands`, `/accounts`, `/transactions`, `/categories`,
  `/reports/summary`, `/setup/*`.
- Ứng dụng Android: màn chào, đăng nhập, thiết lập lần đầu, tổng quan, giao dịch, nhập nhanh, tài khoản, cài đặt.
- CI: hợp đồng, API, cơ sở dữ liệu, Android, quét bí mật. Application ID `vn.moma.app`; ký phát hành bắt buộc khóa riêng.

[Unreleased]: https://github.com/NhanSamLe/money-manage-app/compare/v0.2.1+3...HEAD
[0.2.1]: https://github.com/NhanSamLe/money-manage-app/releases/tag/v0.2.1+3
[0.2.0]: https://github.com/NhanSamLe/money-manage-app/releases/tag/v0.2.0+2
[0.1.0]: https://github.com/NhanSamLe/money-manage-app/commit/76a751b
