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

## 2026-11-27 update: planning features (Gate 4 + parts of Gate 2/5), code + local tests only

| Item | Status | Evidence actually run |
|---|---|---|
| Migration 003 (debts, goals, budgets, categories, recurring, corrected dashboard) | PASS on Postgres 17 | `scripts/db-test.sh` -> both `001_core_smoke.sql` and `002_planning_smoke.sql` OK |
| Migration 003 on real Supabase | NOT APPLIED by owner yet | run `supabase/migrations/20261127000003_planning_rpc.sql` in SQL Editor |
| API (15 commands, planning reads) | PASS | `tsc --noEmit` clean; `vitest run` 26/26; deployed Worker version 0cdf52d8 |
| Android | PASS (static + unit) | `flutter analyze --fatal-infos` clean; `flutter test` 22/22 |
| G4-01..G4-03 debts/goals/budgets/recurring | IMPLEMENTED, NOT VERIFIED ON DEVICE | UI untested on a phone |
| G2-04 CSV import | IMPLEMENTED (client parse + idempotent per-row TX_CREATE) | No server-side preview/commit tables; no cross-source dedup (Gate 3) |
| G5-01 Vietnamese rule engine | IMPLEMENTED (quick text -> suggestion) | AI providers (G5-02/03) NOT started |
| G3 notification/API integrations | NOT STARTED, intentionally disabled | needs consented redacted samples |
| G1-05 offline outbox | NOT STARTED | |

## 2026-11-27 final handover of this session (see docs/TESTING.md for the exact commands)

| Item | Status |
|---|---|
| DB migrations 001-004, SQL tests (3 suites) | PASS on Postgres 17 |
| API: 19 commands, 29 unit tests, 12 end-to-end tests (Postgres + PostgREST) | PASS |
| Android: analyze --fatal-infos clean, 33 tests (unit + UI flows with fake API) | PASS |
| Deployed Worker `moma-api` (custom domain) | UP, health 200 |
| Migrations 003+004 on the owner's real Supabase | PENDING (owner runs `supabase/pending/apply-003-004.sql`) |
| Owner bootstrap with real email, real device run | NOT DONE (owner UAT: docs/UAT.md) |
| Android emulator (Pixel 6, API 35, WHPX) | APK installs and runs; welcome/login/setup screens and real-network error paths verified with screenshots (docs/screens). Post-login screens NOT driven on device (needs owner credentials) |
| Gate 3 (notification/API integrations, dedup, reconcile) | NOT STARTED, intentionally disabled |
| Gate 5 AI providers | NOT STARTED |
| Gate 6 release (private signing key, backup/restore drill, security audit) | NOT STARTED |

