# @moma/api — API v1 (Cloudflare Worker)

Cổng HTTP của MoMa. Chỉ xác thực, kiểm tra đầu vào, gọi RPC cơ sở dữ liệu và ánh xạ lỗi. **Không chứa logic sổ cái**: mọi thay đổi tài chính là RPC nguyên tử trong `supabase/migrations`.

- Phiên bản: xem `package.json` và `src/shared/version.ts` (đồng bộ với `/VERSION`).
- Runtime: Cloudflare Workers (Web Fetch/Crypto, không dùng API Node), Hono, `jose`, `zod`.
- Hợp đồng: `spec/contracts/openapi.yaml`, `spec/contracts/commands.schema.json`.

## Cấu trúc

```
src/entrypoints/http.ts          # route, composition root
src/bootstrap/config.ts          # đọc cấu hình, thất bại an toàn khi thiếu secret
src/modules/auth/                # xác minh JWT Supabase (JWKS, issuer, audience, hạn)
src/modules/ledger/              # port FinanceGateway, adapter RPC Supabase, schema lệnh
src/shared/                      # money (bigint), errors, canonical hash, version, report-period
test/unit/                       # Vitest
```

## Lệnh

```bash
npm ci
npm run typecheck    # tsc --noEmit (strict)
npm test             # vitest run
npx wrangler dev     # chạy cục bộ (cần .dev.vars, không commit)
npx wrangler deploy  # triển khai (xem docs/DEPLOYMENT.md)
```

## Điểm cần biết

- Mọi route chủ sở hữu yêu cầu: `Authorization: Bearer <JWT Supabase>` có `sub` trùng chủ sở hữu duy nhất, và `X-Device-Id` (UUID).
- `POST /v1/commands` yêu cầu header `Idempotency-Key` bằng `command_id`. Hash chuẩn hóa (khóa sắp xếp, SHA-256) cùng chủ sở hữu quyết định phát lại hay xung đột (409).
- Lệnh chưa có RPC trả `422 NOT_IMPLEMENTED`; không bao giờ trả thành công giả.
- Phản hồi lỗi: `{ error: { code, message, retryable, request_id } }`. Lỗi nội bộ trả mã chung, không lộ chi tiết.
- Nhật ký có cấu trúc, đã che: `request_id`, đường dẫn, mã lỗi. Không ghi thân yêu cầu/phản hồi.

## Biến cấu hình

| Tên | Loại | Ghi chú |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | `[vars]` | công khai |
| `SUPABASE_SERVICE_ROLE_KEY` | secret | Secret key (`sb_secret_...`) hoặc service_role cũ |
| `BOOTSTRAP_SECRET` | secret | ≥ 32 ký tự; chỉ dùng cho thiết lập lần đầu |
| `OWNER_EMAIL` | secret | email nhận thư mời |
