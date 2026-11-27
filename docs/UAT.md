# Phiếu nghiệm thu (UAT) cho chủ sở hữu

Làm theo thứ tự. Mỗi bước ghi **kết quả mong đợi**; nếu khác, chụp màn hình hoặc chép nguyên thông báo gửi lại.

## 0. Chuẩn bị (một lần)

1. Supabase → SQL Editor: dán toàn bộ `supabase/pending/apply-003-004.sql` rồi `supabase/pending/apply-005-006.sql` (từng file một) → **Run and enable RLS** → thành công, không lỗi đỏ.
2. Supabase → Authentication → Email Templates: dán `supabase/templates/invite.html` (Invite user) và `recovery.html` (Reset password). Phải có `{{ .Token }}`.
3. Supabase → Authentication → tắt "Allow new users to sign up" (nếu chưa).
4. Kiểm tra Worker: mở `https://moma-api.superaicore.indevs.in/v1/auth/config` → thấy `"setup_state":"UNINITIALIZED"`.
5. Nếu sau này đăng nhập báo 401 dù đúng mật khẩu: dự án Supabase của bạn có thể dùng khóa ký cũ (HS256). Khi đó chạy
   `npx wrangler secret put SUPABASE_JWT_SECRET --name moma-api` và dán "JWT Secret" (Supabase → Settings → JWT).

## 1. Cài ứng dụng

Chép `apps/android/build/app/outputs/flutter-apk/app-debug.apk` sang điện thoại Android, cài (cho phép nguồn không xác định).

## 2. Thiết lập chủ sở hữu

| Bước | Thao tác | Mong đợi |
|---|---|---|
| 2.1 | Mở MoMa → **Tạo tài khoản mới** → nhập `ledaonhansam@gmail.com`, tên, mật khẩu ≥ 8 ký tự (2 lần) → **Tiếp tục** | Chuyển sang màn nhập mã |
| 2.2 | Mở thư tới `ledaonhansam@gmail.com` | Có thư "MoMa" kèm **mã số** |
| 2.3 | Nhập mã → **Xác nhận và tạo tài khoản** | Vào màn Thiết lập ban đầu, thêm tài khoản đầu tiên |
| 2.4 | Thử tạo tài khoản lần nữa / dùng email khác | Bị từ chối (đã có chủ / email không được phép) |

Nếu không nhận thư (kiểm tra cả mục Spam): thư mặc định của Supabase giới hạn vài thư/giờ và chỉ gửi tới email thuộc tổ chức Supabase.

## 3. Việc hằng ngày

| Bước | Thao tác | Mong đợi |
|---|---|---|
| 3.1 | Tài khoản → **Thêm tài khoản** (Ngân hàng, số dư 10.000.000) | Hiện trong danh sách, số dư đúng |
| 3.2 | Nút **+** → gõ `ăn trưa 65k` → Enter → chọn tài khoản → Lưu | Giao dịch hiện ở tab Giao dịch; số dư giảm 65.000 |
| 3.3 | Gõ `nhận lương 15tr` → Lưu | Thu nhập 15.000.000, danh mục Lương |
| 3.4 | Chuyển khoản giữa 2 tài khoản có phí | Cả hai số dư đúng; phí tính là chi tiêu |
| 3.5 | Tổng quan | Tài sản ròng, thu, chi, chi theo danh mục khớp; đổi tháng bằng mũi tên |
| 3.6 | Giao dịch → bấm một dòng → **Sửa** (đổi danh mục) | Số dư không đổi; danh mục đổi |
| 3.7 | Sửa số tiền (cần nhập lý do) | Dòng cũ gạch ngang "Đã hủy", dòng mới "Đã sửa" |
| 3.8 | Giao dịch → **Hủy giao dịch** | Số dư trở lại như trước |
| 3.9 | Tìm kiếm `com trua` (không dấu) | Tìm thấy "Cơm trưa" |

## 4. Kế hoạch

| Bước | Thao tác | Mong đợi |
|---|---|---|
| 4.1 | Kế hoạch → Công nợ → cho vay 500.000 | Tiền tài khoản giảm 500.000; Phải thu 500.000 |
| 4.2 | Thu nợ 200.000 (+ lãi 10.000) | Còn 300.000; lãi tính vào thu nhập |
| 4.3 | Thử thu nợ nhiều hơn số còn lại | Báo "Số tiền vượt quá số còn lại" |
| 4.4 | Tiết kiệm → tạo mục tiêu → dành 300.000 | Tiến độ tăng; số dư tài khoản **không** đổi |
| 4.5 | Ngân sách → đặt hạn mức cho Ăn uống | Thanh tiến độ; vượt hạn mức hiện màu đỏ |
| 4.6 | Định kỳ → thêm Netflix → đến hạn bấm Xác nhận | Tạo giao dịch và đánh dấu đã xử lý |

## 5. Mạng, an toàn và các trường hợp xấu

| Bước | Thao tác | Mong đợi |
|---|---|---|
| 5.1 | Tắt mạng → thêm giao dịch | Thông báo "đã lưu, sẽ tự đồng bộ"; biểu ngữ vàng "1 giao dịch chờ đồng bộ" |
| 5.2 | Bật mạng → bấm **Đồng bộ ngay** | Giao dịch xuất hiện đúng **một lần** |
| 5.3 | Cài đặt → Nhập sao kê CSV → dán CSV có cột Ngày, Diễn giải, Ghi nợ, Ghi có | Xem trước các dòng; ghi xong báo số dòng; nhập lại cùng file → "đã nhập trước đó" |
| 5.4 | Đăng xuất → Quên mật khẩu → nhập mã → đặt mật khẩu mới | Đăng nhập được |
| 5.5 | Cài đặt → Danh mục → thêm "Cà phê" thuộc "Ăn uống" | Dùng được khi thêm giao dịch |

## Việc chưa có trong bản này

Đọc thông báo ngân hàng tự động, chống trùng giữa nhiều nguồn, trợ lý AI, thông báo nhắc hạn, khóa ứng dụng bằng vân tay, sao lưu tự động. Xem `docs/TESTING.md`.
