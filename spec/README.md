# Personal Finance AI — đặc tả bàn giao AI Coding Agent

**Version:** 1.0 • **Ngày:** 27/11/2026 • **Trạng thái:** baseline thiết kế, chưa triển khai hoặc kiểm thử Production.

Ứng dụng Android cho một chủ sở hữu, quản lý toàn bộ tiền, thu chi, công nợ, ngân sách, tiết kiệm và tài sản bằng nhập liệu tối thiểu. Không thuê server, không self-host; chỉ AI trả phí khi chủ sở hữu chủ động bật. Nguồn API và Android Notification độc lập, có thể bật cả hai; không yêu cầu chuyển ngân hàng. VCB, MoMo, TPBank, MB, ZaloPay, VNPAY và các nhà cung cấp khác mở rộng bằng adapter.

## Đọc theo thứ tự

| File | Nội dung |
|---|---|
| `AGENTS.md` | Chỉ dẫn bắt buộc cho coding agent, thứ tự triển khai |
| `docs/01-product.md` | BRD, scope, actors, functional requirements, NFR |
| `docs/02-ux-setup.md` | Navigation, màn hình, wizard lần đầu, auth, UX state |
| `docs/03-financial-rules.md` | Sổ cái, giao dịch, công nợ, ngân sách, báo cáo, ví dụ tính đúng |
| `docs/04-integrations.md` | API/notification, capability matrix, sync/dedup/reconcile, connector contract |
| `docs/05-ai.md` | AI pipeline, action schema, prompt, quota, privacy, benchmark |
| `docs/06-architecture-security.md` | HLD, luồng dữ liệu, auth, offline, threat model, job engine |
| `docs/07-deployment-operations.md` | Triển khai Cloudflare/Supabase/Resend, chi phí, backup, runbook |
| `docs/08-data-api.md` | Data dictionary, command contract, errors, versioning |
| `docs/09-research.md` | Nguồn chính thức, giới hạn, quyết định chưa xác minh |
| `docs/10-roadmap.md` | WBS, gates, definition of done |
| `docs/11-engineering-standards.md` | Normative Clean Architecture, Clean Code, flows, CI |
| `docs/12-rpc-and-ll-database.md` | Atomic RPC, table ownership, locking and read models |
| `CLAUDE.md` | Claude Code entry point |
| `contracts/commands.schema.json` | Strict command payload schemas |
| `contracts/normalized-event.schema.json` | Ingestion event contract |
| `tests/verify_specs.py` | Static contract and fixture verification |
| `tests/traceability.json` | Requirement-to-acceptance machine index, initially NOT_RUN |
| `IMPLEMENTATION_STATUS.md` | Agent task handover template |
| `db/001-baseline.sql` | PostgreSQL schema baseline, ràng buộc, RLS, giao dịch sổ cái |
| `contracts/openapi.yaml` | OpenAPI cho API nội bộ v1 (không phải API ngân hàng) |
| `contracts/ai-action.schema.json` | JSON Schema đầu ra đề xuất AI |
| `config/providers.json` | Capability registry mặc định, trạng thái chưa xác minh |
| `config/settings.example.json` | Default config không chứa secrets |
| `config/wrangler.example.toml` | Ví dụ Worker free, cron; không dùng self-host |
| `tests/acceptance.md` | Bộ kiểm thử end-to-end |
| `tests/fixtures.json` | Các giao dịch giả lập/edge cases để viết automated tests |
| `tests/STATIC-VALIDATION.txt` | Kết quả kiểm tra tĩnh thực tế (không phải test app) |

## Chốt kỹ thuật

Flutter + Kotlin NotificationListenerService + WorkManager + SQLite mã hóa; Cloudflare Workers TypeScript/Hono (không NestJS server chạy liên tục); Supabase PostgreSQL/Auth/Storage free; Resend SMTP; AI Rule Engine → AI free đã kiểm tra điều khoản → DeepSeek Flash (opt-in) → review. Mọi tiền ở VND nguyên, lưu bằng bigint, truyền qua JSON dưới dạng chuỗi số nguyên. Sổ cái kép và báo cáo deterministic.

## Cách sử dụng bộ tài liệu

Giải nén vào repository, đưa `AGENTS.md` và `README.md` cho coding agent. Yêu cầu triển khai theo Gate 0–6; không yêu cầu viết toàn bộ app trong một lần. Tài liệu và schema là baseline để agent viết, chạy migration, kiểm thử, sửa lỗi; không phải source code ứng dụng hoàn chỉnh. Các adapter live chỉ bật khi kiểm chứng chính thức khả năng + miễn phí + dữ liệu thật. Không cung cấp credentials, không tự mở tài khoản ngân hàng, không tự mua dịch vụ.

## Các blocker được giữ lại có chủ đích

- Chưa có API cá nhân miễn phí được xác minh cho toàn bộ VCB/MoMo/ZaloPay/VNPAY. API merchant không dùng thay thế. Notification cần POC trên điện thoại thật.
- SePay Free có thể tính phí vượt hạn mức tại SePay; chặn ingest trong app không ngăn phí phát sinh phía SePay. Mặc định tắt API live tới khi kiểm chứng chặn phí/upstream opt-in.
- Cloud miễn phí có quota, downtime/pausing, không SLA. Không đảm bảo realtime 100%; đối soát sao kê và hàng đợi offline là bắt buộc.
- Cần chủ sở hữu có domain, email, tài khoản Cloudflare/Supabase/Resend; không có thông tin domain/email thật trong package.
- Chưa benchmark AI tiếng Việt, chưa kiểm tra thiết bị, chưa chạy migration/Production. Không coi tài liệu này là chứng nhận bảo mật.

## Static QA and open implementation work

Static validation checks JSON Schema, OpenAPI local references/operation IDs, command schema parity, synthetic journal arithmetic and cost examples; see `tests/STATIC-VALIDATION.txt`. Full OpenAPI validator, live SQL migration/RPC tests and actual provider/email/Android tests have not run. All task acceptance tests begin NOT_RUN. The baseline migration includes posting guards but not every RPC; `docs/12-rpc-and-ll-database.md` specifies the subsequent implementation. Optional P1 investment valuation, cross-period automatic transfer, voice/OCR and unverified providers remain disabled until their specific implementation and tests are complete. This is an agent-ready specification baseline, not a claim that the production application is ready.
