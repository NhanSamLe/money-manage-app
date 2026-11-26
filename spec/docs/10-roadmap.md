# 10 - Agentic implementation backlog / gates

Build vertical slices, not all modules simultaneously. Each gate must finish tests and document unresolved dependencies before dependent work. `AGENTS.md` and engineering standards mandatory. This package supplies spec, baseline schema and contracts; it does not contain a running product. Bootstrap repo only after reading all relevant files. Live external services require owner account setup; mock synthetic fixtures never masquerade as live.

| Task | Depends | Deliverable | Acceptance |
|---|---|---|---|
| G0-01 | - | Pin SDK/runtime/dependencies; record free quota, policy and ADR | COST-01, OPS-01 |
| G0-02 | - | Test Resend SMTP invite/recovery and app links staging | AUTH-01..05 |
| G0-03 | - | Real Android notification capture POC with consented redacted samples | INT-01, SEC-06/07 |
| G0-04 | - | Validate SePay capability, official auth and hard fee limit; record unsupported banks | INT-02, COST-02 |
| G0-05 | - | Build synthetic AI benchmark, check privacy/model prices | AI-01..04 |
| G1-01 | G0-01 | Monorepo, CI, code boundary lint, contract generation | ENG-01 |
| G1-02 | G1-01 | Apply SQL baseline; write atomic command/receipt/change/job RPCs and grants | FIN-01, SEC-04 |
| G1-03 | G1-02,G0-02 | Single-owner bootstrap invite/claim, auth/recovery/device revocation | AUTH-01..05 |
| G1-04 | G1-03 | Flutter wizard W00-W13, app links, encrypted cache, device config | UX-01, AUTH-04 |
| G1-05 | G1-02,G1-04 | Offline outboxes, cursor sync, conflict/retry | SYNC-01..03 |
| G2-01 | G1 | Account/category/contact creation, baseline, opening balance | FIN-02 |
| G2-02 | G2-01 | TX_CREATE/ANNOTATE/CORRECT/REVERSE and split/refund/transfer | FIN-01..06 |
| G2-03 | G2-02 | Manual quick entry, transaction screens, list/search | UX-02 |
| G2-04 | G2-02 | CSV normalized import preview/commit + source evidence | INT-06 |
| G2-05 | G2-02 | Report SQL read models, account/dashboard coverage, summary/series | FIN-07 |
| G3-01 | G1-05,G2-02 | Provider registry, source toggles/epochs, mapping | INT-01,02,04 |
| G3-02 | G3-01,G0-03 | Native notification allowlist/parsers, outbox, permission UX | INT-01, SEC-06/07 |
| G3-03 | G3-01,G0-04 | SePay adapter if verified, webhook/poll, job lease | INT-02,05, COST-02 |
| G3-04 | G3-02,G3-03 | Dedup, manual/API/notification matching, review, reconcile | INT-03..07 |
| G4-01 | G2-02 | Debt creation, repayments, historical, writeoff and correction | FIN-08..10 |
| G4-02 | G2-02 | Saving goals and allocations, budgets, recurring/reminders | FIN-11..13 |
| G4-03 | G4-01,G4-02 | Planning UX, reports, debt timelines | UX-03 |
| G5-01 | G2-03 | Rule engine, Vietnamese parser, rule learning | AI-01 |
| G5-02 | G5-01,G0-05 | Provider adapters, structured proposals, cap reservations | AI-02..04, COST-01 |
| G5-03 | G5-02 | AI chat, safe read queries, voice/OCR optional | AI-05 |
| G6-01 | G1..G5 | Cloud deploy staging, free caps, export/restore runbook | OPS-01..03 |
| G6-02 | G6-01 | Real-device end-to-end, security and finance regression, profiling | all applicable acceptance; PERF-01, AND-01 |
| G6-03 | G6-02 | Owner-approved production deployment, private signed APK, handover | all gates passed or optional feature disabled |

`G1`, etc. mean relevant prerequisite tasks in the gate. If G0-03/G0-04 fails, implement adapter OFF/UNAVAILABLE plus manual/import, not pretend success. Real API not required for core release, but cannot mark live integration verified without POC. Voice/OCR, FCM, additional bank adapters may be deferred explicitly; do not omit core features without recording. Maintain task status and trace from requirement/test to code. Limit parallel agents to independent slices after contract freeze. Each task has migration/contract update, tests, UX errors, docs and security review as appropriate.

## Start prompt for coding agent

Read AGENTS.md, README.md, docs/11-engineering-standards.md, then the relevant numbered docs. Inspect the existing repository; do not overwrite user files. Establish a short plan for G0/G1, generate implementation status and trace matrix. Implement only the first unblocked vertical slice and its tests; run the checks, report files and exact results. Do not deploy, spend money, ask for bank OTP/password, invent real provider endpoints, or claim untested functionality. When spec/contract conflicts, report it and propose versioned resolution before implementation. Use official docs to validate external providers; preserve zero-cost and no-self-host policy. Continue gates only when prior acceptance passed.
