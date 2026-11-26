# Agent handover and implementation status

Baseline specification v1.0. No application code has been built. Start with G0/G1. Static QA only, see tests/STATIC-VALIDATION.txt.

| Task ID | Status | Requirement / test | Commit / files | Tests actually run | Blocker / next step |
|---|---|---|---|---|---|
| G0-01 | NOT_STARTED | COST-01,OPS-01 | - | - | Verify free plan and pin runtime |
| G0-02 | NOT_STARTED | AUTH-01..05 | - | - | Owner Supabase + Resend domain setup |
| G0-03 | NOT_STARTED | INT-01,SEC-06/07 | - | - | Actual Android and sanitized sample notifications |
| G0-04 | NOT_STARTED | INT-02,COST-02 | - | - | API production eligibility + hard fee cap |
| G0-05 | NOT_STARTED | AI-01..04 | - | - | Model/privacy/benchmark validation |
| G1-G6 | NOT_STARTED | docs/10-roadmap.md | - | - | Expand tasks per roadmap; do not mark gate verified prematurely |

Use NOT_STARTED / IN_PROGRESS / BLOCKED / VERIFIED. Record exact failed and passed commands, environment and test count, unresolved spec changes and ADRs. Never mark NOT_RUN as passing. Keep a short current task context for next agent.

## 2026-11-27 progress (v0.1.0, pre-release)

Commands actually executed this session and their real results:

| Item | Status | Evidence (what was run) |
|---|---|---|
| Spec static check | PASS | `python spec/tests/verify_specs.py` |
| DB migrations 001+002 | PASS on Postgres 17 (stubbed Supabase roles) | `scripts/db-test.sh`: migrations applied, `supabase/tests/001_core_smoke.sql` OK (setup, idempotency, transfer+fee, reversal, grants, immutability) |
| DB migrations on real Supabase | APPLIED by owner via SQL Editor; not independently verified beyond API health | `GET /v1/auth/config` returned `setup_state: UNINITIALIZED` via Worker |
| API | PASS | `npx tsc --noEmit` clean; `vitest run`: 19/19 |
| API deployed | UP | `https://moma-api.superaicore.indevs.in/v1/health` 200 (Cloudflare Worker `moma-api`) |
| Android | PASS (static + unit) | `flutter analyze --fatal-infos`: no issues; `flutter test`: 5/5 |
| Android APK | see CHANGELOG / build log | not yet installed or run on a device |

| Task | Status | Notes |
|---|---|---|
| G1-01 monorepo, CI definition | IN_PROGRESS | CI file written, NOT run on GitHub (repo not pushed) |
| G1-02 core RPCs | IN_PROGRESS | Only ACCOUNT_CREATE, TX_CREATE (no split/refund), TX_REVERSE; remaining commands NOT_IMPLEMENTED |
| G1-03 owner bootstrap/auth | IN_PROGRESS | RPC + API + app screens written; end-to-end on real Supabase/email NOT verified |
| G1-04 Flutter wizard | IN_PROGRESS | Simplified setup/login only; W00-W13 not built |
| G1-05 offline outbox | NOT_STARTED | |
| G2-01..G2-03 | IN_PROGRESS | Accounts, quick entry, list exist (untested on device) |
| G2-04 CSV import, G2-05 reports | NOT_STARTED / partial | Dashboard summary only |
| G3 integrations, G4 debts/goals/budgets, G5 AI, G6 release | NOT_STARTED | Blocked on real-device notification samples and provider verification |
