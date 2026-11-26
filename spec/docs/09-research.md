# 09 - Evidence registry and unresolved external capabilities

Snapshot 2026-11-27 (Vietnam). Verify all third-party docs, prices and account eligibility again before enabling live integration. Documentation is not a live POC. Never treat a payment merchant endpoint as a personal account-data endpoint. No provider credentials or real bank data are included.

| Decision / source | Official source URL | Finding / caveat |
|---|---|---|
| Cloudflare Workers Free | https://developers.cloudflare.com/workers/platform/limits/ | 100k requests/day, 10 ms CPU, bounded subrequests; use thin HTTP orchestration, measure runtime. |
| Workers custom domains | https://developers.cloudflare.com/workers/configuration/routing/custom-domains/ | Existing domain can route to Worker, no server/Tunnel required. |
| Workers AI | https://developers.cloudflare.com/workers-ai/platform/pricing/ | Free allocation and model eligibility subject to change. Validate actual model and privacy before enabling. |
| Supabase | https://supabase.com/pricing | 500 MB DB, 50k MAU, 5GB egress, 1GB storage; pause after inactivity; no automatic free backups. |
| Supabase Auth SMTP | https://supabase.com/docs/guides/auth/auth-smtp | Custom SMTP; test invite and recovery delivery. |
| Supabase Auth | https://supabase.com/docs/guides/auth | SDK login/invite/recovery, session and JWT validation; disable public signup. |
| Resend | https://resend.com/pricing | Free daily limit 100; verify current monthly quota; domain/SMTP configuration required. |
| Resend + Supabase | https://resend.com/docs/send-with-supabase-smtp | Sender verification and custom SMTP. |
| SePay FREE | https://sepay.vn/bang-gia.html | 50 transactions/month, API/webhook; explicitly permits overage billing. Zero-cost hard gate, not guaranteed free. |
| SePay TPBank | https://docs.sepay.vn/ket-noi-tpbank.html | Official personal API connection; provider documents disabling sync stops counting/fees for that account. App local toggle alone cannot guarantee upstream pause. |
| SePay MB | https://docs.sepay.vn/ket-noi-mb-api.html | Personal account connection through provider, no bank password; provider requires identity and OTP in official flow. App must not collect OTP. |
| SePay docs | https://docs.sepay.vn/ | Verify account type, debit/credit, API auth, webhook signature, quota, replay/backfill and balances. Capture actual examples at Gate 0. |
| VCB personal | https://www.vietcombank.com.vn/ | No complete free personal AIS proven. Official business integration and alert products do not establish personal read API. |
| Finverse | https://www.finverse.com/bank-data-api | Candidate AIS; cost/production eligibility and VCB capability unverified for this app; excluded in zero-cost default. |
| Casso | https://casso.vn/ | Candidate aggregation/RPA; do not enable without verified free limit, approved access and no bank credential storage. |
| MoMo merchant | https://developers.momo.vn/ | Payment/IPN/query scoped to partner payment, not verified personal wallet history. |
| ZaloPay merchant | https://docs.zalopay.vn/ | Merchant APIs, personal data capability UNKNOWN. |
| VNPAY merchant | https://sandbox.vnpayment.vn/apis/ | Merchant payment APIs, personal data capability UNKNOWN. |
| Android listener | https://developer.android.com/reference/android/service/notification/NotificationListenerService | OS user permission required; notifications can be missing/redacted; real device proof. |
| Android WorkManager | https://developer.android.com/topic/libraries/architecture/workmanager | Durable background work, not precise continuous delivery. |
| DeepSeek | https://api-docs.deepseek.com/quick_start/pricing/ | deepseek-flash V4.1 Flash; uncached $0.15/$0.30 and output $0.60/$1.20 per million off-peak/peak; JSON and vision documented. |
| Gemini | https://ai.google.dev/gemini-api/docs/pricing | 2.5 Flash-Lite $0.10/$0.40; free content may be used for product improvement. Verify availability and terms. |
| SDD | https://github.com/github/spec-kit | Constitution/spec/plan/tasks/implementation pattern. |
| Agent conventions | https://agents.md/ | Repository instructions; no universal mandatory document list. |
| OpenAPI | https://spec.openapis.org/oas/v3.1.0 | Internal API contract; JSON syntax also valid YAML. |
| JSON Schema | https://json-schema.org/draft/2020-12/schema | Strict typed machine validation. |

## Live-integration evidence template (one record per institution/provider/account type)

`provider`, `institution`, `account_type`, `checked_at`, `doc_url`, `version`, `credit`, `debit`, `balance_basis`, `history_window`, `webhook_auth`, `pagination`, `backfill`, `source_pause`, `upstream_billing_hard_cap`, `expiry`, `test_case_ids`, `redacted_sample_hash`, `result`, `blockers`. Unknown capabilities remain UNKNOWN. Capture real notifications on owner device only after permission; do not retain OTP or raw unfiltered notification. No live requests from this package. No benchmark measured; prices are snapshot, not guarantee. Official data-use terms and data retention must be reviewed separately for AI.
