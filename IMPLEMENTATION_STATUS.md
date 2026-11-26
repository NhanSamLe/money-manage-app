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

## 2026-11-27 progress (code written, NOTHING RUN)

| Item | Status | Files | Tests actually run |
|---|---|---|---|
| G1-01 monorepo skeleton | IN_PROGRESS | AGENTS.md, CLAUDE.md, apps/, supabase/, spec/, docs/decision-log.md | spec static check only (python verify_specs.py: PASS) |
| G1-02 core RPCs (setup, device, execute_command, reads) | IN_PROGRESS, NOT_RUN | supabase/migrations/20261127000002_core_rpc.sql | none |
| API (Hono): auth, commands, reads | IN_PROGRESS, NOT_RUN | apps/api/src/** | none (npm install/tsc not run) |
| G1-04 Flutter wizard/app | NOT_STARTED | apps/android | Flutter SDK not installed on this machine |
