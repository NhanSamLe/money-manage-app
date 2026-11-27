# Triển khai và vận hành

Chỉ dùng gói miễn phí: Cloudflare Workers, Supabase, tên miền đã có trong Cloudflare. Không tự lưu trữ máy chủ.

## 1. Cơ sở dữ liệu (Supabase)

1. Authentication → Sign In / Providers → **tắt** "Allow new users to sign up".
2. SQL Editor: chạy các file trong `supabase/migrations/` theo thứ tự tên file. Khi được hỏi, chọn **Run and enable RLS**.
3. Authentication → Email Templates: dán `supabase/templates/invite.html` (Invite user) và `recovery.html` (Reset password). Mẫu phải chứa `{{ .Token }}`.
4. Thư: dùng SMTP mặc định của Supabase (chỉ gửi tới email thuộc tổ chức Supabase, giới hạn tần suất). Email chủ sở hữu phải là email đăng nhập Supabase.

Migration đã áp dụng lên môi trường thật **không được sửa**; thay đổi mới là file migration mới. Sao lưu trước khi áp dụng migration lên dữ liệu thật.

## 2. API (Cloudflare Worker)

```bash
cd apps/api
npm ci
npx wrangler login
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY   # Secret key của Supabase (sb_secret_...)
npx wrangler secret put BOOTSTRAP_SECRET            # chuỗi ngẫu nhiên >= 32 ký tự
npx wrangler secret put OWNER_EMAIL                 # email chủ sở hữu
npx wrangler deploy
```

Tên miền API được cấu hình trong `apps/api/wrangler.toml` (`routes`). Hostname không được có sẵn bản ghi DNS khác.

Kiểm tra sau triển khai:

```bash
curl https://<host>/v1/health          # 200, {"status":"OK"}
curl https://<host>/v1/auth/config     # 200, setup_state
```

Xem nhật ký thời gian thực: `npx wrangler tail`. Nhật ký chỉ chứa `request_id`, đường dẫn, mã lỗi — không có nội dung yêu cầu.

## 3. Kích hoạt chủ sở hữu (một lần)

Trong ứng dụng → "Tạo tài khoản mới": nhập đúng `OWNER_EMAIL`, tên, mật khẩu → hệ thống gửi mã tới email đó → nhập mã để hoàn tất (quyết định D-012: không còn khóa triển khai). Sau khi `setup_state` là `BOUND`, quy trình này bị khóa.

Trợ lý AI (tùy chọn): `npx wrangler secret put DEEPSEEK_API_KEY --name moma-api`. Không đặt khóa thì AI tắt. Trần chi phí mặc định 1 USD/tháng (bảng `pf_ai_usage`, cần migration 006).

## 4. Xử lý sự cố thường gặp

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| `/auth/config` trả 503 | Thiếu hoặc sai secret | `npx wrangler tail`, xem `detail: CONFIG_MISSING:<tên>`, đặt lại secret đó |
| Worker không gắn được hostname | Hostname đã có bản ghi DNS | Dùng hostname khác hoặc xóa bản ghi cũ trong Cloudflare |
| `OWNER_NOT_BOUND` | Chưa hoàn tất thiết lập | Làm mục 3 |
| `DEVICE_REVOKED` | Phiên/thiết bị bị thu hồi | Đăng nhập lại để đăng ký thiết bị |

## 5. Xoay vòng bí mật

Khi một secret bị lộ (kể cả dán nhầm vào chat): tạo khóa mới tại nhà cung cấp, `wrangler secret put` giá trị mới, thu hồi khóa cũ, ghi vào `docs/decision-log.md`.

## 6. Sao lưu và khôi phục

Chưa triển khai tự động (xem `spec/docs/07-deployment-operations.md`). Cho tới khi có runbook sao lưu/khôi phục đã diễn tập, **không lưu dữ liệu quan trọng duy nhất trong MoMa**.
