# MoMa — MoneyManage

Ứng dụng Android quản lý tài chính cá nhân cho **một chủ sở hữu duy nhất**: thu chi, tài khoản, công nợ, ngân sách, tiết kiệm và tài sản, với sổ cái kép và báo cáo xác định (deterministic). Không thuê máy chủ riêng, không tự lưu trữ; chạy trên gói miễn phí của Cloudflare và Supabase.

| | |
|---|---|
| Phiên bản | `0.1.0` (pre-release) — xem [`VERSION`](VERSION), [`CHANGELOG.md`](CHANGELOG.md) |
| Trạng thái | Nền tảng backend + ứng dụng cơ bản. **Chưa dùng cho dữ liệu thật.** Xem [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) |
| Giấy phép | Độc quyền, bảo lưu mọi quyền — [`LICENSE`](LICENSE) |
| Đặc tả | [`spec/`](spec/README.md) (v1.0, có tính ràng buộc) |

## Kiến trúc

```
Android (Flutter, Riverpod, go_router)
        │  HTTPS + JWT (Supabase Auth) + X-Device-Id
        ▼
Cloudflare Worker (Hono, TypeScript)   ← apps/api
        │  RPC (service role, chỉ ở Worker)
        ▼
Supabase PostgreSQL (RLS, RPC nguyên tử, sổ cái bất biến)   ← supabase/
```

Nguyên tắc cốt lõi (chi tiết trong [`AGENTS.md`](AGENTS.md)):

- Tiền là số nguyên VND (`bigint`), truyền dạng chuỗi số, không dùng số thực.
- Mọi bút toán cân bằng bằng 0; chỉ ghi qua RPC nguyên tử; sửa sai bằng đảo bút toán.
- Lệnh ghi idempotent theo `command_id` + hash; gửi lại cùng lệnh trả kết quả cũ.
- Một chủ sở hữu duy nhất, đăng ký công khai tắt; khóa bí mật chỉ nằm ở Worker.
- Báo cáo theo múi giờ `Asia/Ho_Chi_Minh`, khoảng nửa mở `[từ, đến)`.

## Cấu trúc thư mục

| Đường dẫn | Nội dung |
|---|---|
| `apps/api` | Cloudflare Worker (API v1) — xem [README](apps/api/README.md) |
| `apps/android` | Ứng dụng Flutter — xem [README](apps/android/README.md) |
| `supabase/migrations` | Migration SQL theo thứ tự thời gian (chỉ thêm, không sửa) |
| `supabase/tests` | Kiểm thử SQL cho bất biến sổ cái và RPC |
| `supabase/templates` | Mẫu thư Supabase Auth (mời, đặt lại mật khẩu) |
| `spec/` | Đặc tả, hợp đồng (OpenAPI, JSON Schema), kiểm thử chấp nhận |
| `design/` | Thiết kế UX/UI và bảng màu thương hiệu |
| `docs/` | Triển khai, phát hành, ADR, nhật ký quyết định |
| `scripts/` | Công cụ kiểm tra (đồng bộ phiên bản) |

## Bắt đầu nhanh (phát triển)

Yêu cầu: Node 22+, Flutter 3.50+ (Android SDK 36), JDK 21, Docker (để chạy kiểm thử SQL), Python 3.11+.

```bash
# API
cd apps/api && npm ci && npm run typecheck && npm test

# Ứng dụng Android
cd apps/android && flutter pub get && flutter analyze && flutter test
flutter build apk --debug

# Cơ sở dữ liệu cục bộ (kiểm thử migration)
docker run -d --name moma-pg -e POSTGRES_PASSWORD=local -p 54329:5432 postgres:17
```

Cấu hình bí mật và triển khai: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md). Quy trình phát hành: [`docs/RELEASING.md`](docs/RELEASING.md).

## Cấu hình và bí mật

| Giá trị | Nơi lưu | Công khai? |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `apps/api/wrangler.toml`, ứng dụng | Có |
| `SUPABASE_SERVICE_ROLE_KEY` (Secret key) | Cloudflare Worker secret | **Không** |
| `BOOTSTRAP_SECRET` (≥ 32 ký tự) | Cloudflare Worker secret | **Không** |
| `OWNER_EMAIL` | Cloudflare Worker secret | Không |
| Khóa ký APK | Máy phát hành, ngoài repo | **Không** |

Mẫu biến môi trường: [`.env.example`](.env.example). Không commit giá trị thật.

## Chất lượng và CI

Pull request phải qua các cổng trong [`.github/workflows/ci.yml`](.github/workflows/ci.yml): kiểm tra hợp đồng, API (tsc + test), cơ sở dữ liệu (áp migration + kiểm thử bất biến), Android (analyze + test + build), quét bí mật. Mục tiêu và cổng đầy đủ: `spec/docs/11-engineering-standards.md` mục 5.

## Tài liệu

- [`spec/README.md`](spec/README.md) — đọc đặc tả theo thứ tự
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — triển khai và vận hành
- [`docs/RELEASING.md`](docs/RELEASING.md) — phát hành, đánh phiên bản, ký APK
- [`docs/adr/`](docs/adr) — quyết định kiến trúc; [`docs/decision-log.md`](docs/decision-log.md)
- [`SECURITY.md`](SECURITY.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`CHANGELOG.md`](CHANGELOG.md)

© 2026 Lê Đào Nhân Sâm. Bảo lưu mọi quyền.
