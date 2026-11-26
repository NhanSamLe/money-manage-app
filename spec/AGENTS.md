# Instructions for implementation agents

## Authority and workflow
Read README then numbered docs. User requirements override assumptions; financial rules and security constraints override convenience. Keep a decision log and trace requirements to tests. Do not invent external endpoints, real Android package IDs, transaction patterns or provider signatures. Official provider docs and captured, consented, redacted samples are required. Label unknown capability UNKNOWN, never true. Mock adapters only in development, show a visible demo banner. No credentials committed, no payment initiation, no paid plan activation, no self-host prerequisite.

## Build order
1. Gate 0: verify provider limits, costs, auth email invite/recovery, Android notification POC, test model price/quality with synthetic data. Record official versions. If a source fails, keep it disabled and implement manual/import.
2. Gate 1: migration, ledger invariants, idempotent command RPC, auth singleton, wizard, offline queue. Run database tests before UI.
3. Gate 2: accounts, manual quick entry, statement import, reports and transfers. Demo with synthetic data.
4. Gate 3: notification capture and parser; webhook/poll API adapters independently; dedup/reconciliation. Run fault injection and simultaneous-source tests.
5. Gate 4: debts, saving goals, budgets, recurrence/reminders. Gate 5: AI classification/quick entry/query, safeguards, quota. Gate 6: deploy free stack, security audit, end-to-end on actual Android.

## Hard requirements
- Use integer VND, bigint in SQL, decimal string on wire. Never binary float for money. UTC timestamps; reports in Asia/Ho_Chi_Minh. Distinguish effective time, event arrival time, recorded time.
- All posted journal entries sum to zero (debit positive/credit negative). Only atomic database RPC may post, reverse, link debt, settle, or update balance. Financial history immutable; reverse/repost corrections. Never write ledger from LLM directly. User edits use revision/expected version.
- Do not trust Android notification as verified bank transaction. Filter on-device; redact OTP, auth prompts, non-financial notifications; do not request SMS permission or Accessibility. No logging raw contents or keys. Stop collection on logout/revocation. No history scraping or OTP automation.
- Single owner UUID authorized on every backend operation. Supabase signup disabled. Setup requires one-time deployment secret + fixed owner email + verified invite, no public signup. No service-role key in app. App uses HTTPS and Android Keystore; verify JWT issuer/audience/expiry + owner binding. No arbitrary remote URL for provider fetches.
- Independent source toggles, source epochs, per-account mappings, durable event inbox, unique source IDs, conservative dedup. No matching solely by amount. API and notification never generate duplicate booked expense; uncertain cases require review and transparently show incomplete coverage.
- Do not silently count incoming as income/outgoing as expense. Unknown classification posts to suspense, excluded from classified metrics. Do not auto-settle debts or infer recipient purpose with low certainty.
- Keep Cloudflare/Supabase/Resend on free plan. Do not claim actual zero cost if external billing cannot be blocked. Paid AI explicit opt-in, conservative budget reservation before requests, no auto-top-up. Fail closed on missing billing/price metadata; core app works without AI.
- Work in small commits; write tests, migrations, README, .env.example and CI, run lint/typecheck/unit/integration; report exact tests actually run. Do not claim production readiness from generated specs alone.

## Mandatory engineering standards
`docs/11-engineering-standards.md` is normative. Enforce dependency direction, modular boundaries, strict TypeScript/Dart/Kotlin, atomic SQL RPC, explicit ports, contract generation and CI quality gates. Never put business logic in controllers/widgets, call vendor SDK from domain, or write ledger from AI. Do not invent hidden TODO implementations or fake success. Implement vertical slices in roadmap order and record exact tests in IMPLEMENTATION_STATUS.md. Treat contracts and migrations as versioned sources of truth; report contradictions before modifying them. No release or paid plan changes without owner approval.
