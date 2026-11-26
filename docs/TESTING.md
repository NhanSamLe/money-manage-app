# Kiểm thử MoMa — những gì đã chạy thật và những gì chưa

Cập nhật: 2026-11-27. Chỉ ghi kết quả của lệnh **đã thực sự chạy**. Mục "Chưa kiểm" là việc còn lại, không phải "đã qua".

## Đã chạy và qua (máy phát triển Windows 11)

| Tầng | Lệnh | Kết quả | Kiểm tra cái gì |
|---|---|---|---|
| Đặc tả | `python spec/tests/verify_specs.py` | PASS | Schema, OpenAPI, 39 lệnh, ví dụ sổ cái |
| Cơ sở dữ liệu | `bash scripts/db-test.sh` (Postgres 17) | 3 bộ OK | Migration 001–004; chủ duy nhất; idempotency; chuyển khoản + phí; đảo/sửa/đổi danh mục; công nợ; tiết kiệm; ngân sách; định kỳ; phân quyền (anon bị chặn); bút toán bất biến; tổng sổ cái = 0 |
| API đơn vị | `cd apps/api && npm test` | 29/29 | Tiền bigint, hash chuẩn hóa, múi giờ VN, schema lệnh, JWT (kể cả HS256), mã lỗi, che nhật ký |
| API toàn trình | `cd apps/api && npm run test:e2e` (Docker) | 12/12 | Mã API thật + JWT thật + **PostgREST thật** + Postgres thật: thiết lập chủ, khóa thiết lập, từ chối người lạ (403), tạo tài khoản, phát lại lệnh, xung đột 409, chuyển khoản, đảo, sửa, công nợ, tiết kiệm, ngân sách, định kỳ |
| Kiểu API | `npx tsc --noEmit` | sạch | TypeScript strict |
| Ứng dụng | `flutter analyze --fatal-infos` | sạch | Phân tích tĩnh nghiêm ngặt |
| Ứng dụng | `flutter test` | 33/33 | Định dạng tiền, đọc số tiền tiếng Việt, đọc CSV, luồng giao diện (Tổng quan, Giao dịch, Nhập nhanh, Kế hoạch, hàng đợi offline) với API giả |
| Build | `flutter build apk --debug` | OK | `apps/android/build/app/outputs/flutter-apk/app-debug.apk` |
| Máy ảo Android | Pixel 6, Android 15 (x86_64, WHPX) | OK | APK cài và chạy; màn chào, đăng nhập (sai mật khẩu → Supabase thật trả lỗi → app hiện "Email hoặc mật khẩu không đúng"), thiết lập (sai mã bí mật → Worker thật trả 401 → app hiện "Mã bí mật triển khai không đúng"). Ảnh: `docs/screens/` |
| Triển khai | `GET /v1/health`, `GET /v1/auth/config` | 200 | Worker `moma-api` hoạt động, nối được Supabase thật (`setup_state` đọc từ DB thật) |

Các test giao diện đã phát hiện và sửa 2 lỗi bố cục thật (thẻ Thu/Chi tràn chữ; ô chọn tài khoản tràn khi tên dài). Test E2E đã phát hiện 1 lỗi thật (tháng không hợp lệ trả 503 thay vì 400).

## Chưa kiểm — cần môi trường thật hoặc người dùng

| Việc | Vì sao chưa | Ai làm |
|---|---|---|
| Chạy migration 003 + 004 trên Supabase thật | Cần quyền SQL Editor của chủ dự án | Chủ sở hữu (`supabase/pending/apply-003-004.sql`) |
| Luồng thiết lập chủ sở hữu thật (thư mời, mã, đặt mật khẩu) | Cần `BOOTSTRAP_SECRET` và hộp thư thật | Chủ sở hữu (xem `docs/UAT.md`) |
| Gửi thư thật của Supabase (giới hạn vài thư/giờ) | Phụ thuộc cấu hình Supabase | Chủ sở hữu |
| Các màn sau đăng nhập trên máy ảo/điện thoại (cần tài khoản chủ thật) | Cần mật khẩu của chủ; đã kiểm bằng test giao diện với API giả | Chủ sở hữu (`docs/UAT.md`) |
| Đọc thông báo ngân hàng (Gate 3) | Chưa viết: cần thông báo thật đã che | Chủ sở hữu cung cấp mẫu |
| Chống trùng giữa nhiều nguồn, đối soát | Phụ thuộc Gate 3 | — |
| Trợ lý AI (G5-02/03) | Chưa làm; cần quyết định bật AI trả phí | Chủ sở hữu |
| Sao lưu/khôi phục, kiểm thử tải, kiểm toán bảo mật độc lập | Chưa làm | Trước khi dùng dữ liệu thật quan trọng |
| CI trên GitHub | Repository chưa được đẩy lên GitHub | Khi đẩy repo |

## Chạy lại toàn bộ

```bash
node scripts/check-versions.mjs
bash scripts/db-test.sh                       # cần psql + Postgres trống (hoặc chạy trong container, xem README)
cd apps/api && npm ci && npm run typecheck && npm test && npm run test:e2e
cd ../android && flutter pub get && flutter analyze --fatal-infos && flutter test
```
