# Decision log

| ID | Date | Decision | Why |
|---|---|---|---|
| D-001 | 2026-11-27 | Brand MoMa (MoneyManage). Repo `moma/` with spec copied to `spec/` unchanged. | Owner request; spec requires repo layout in docs/11 section 2. |
| D-002 | 2026-11-27 | Owner decision: write code first, run tests later (single-user app). Nothing is reported as tested until actually run. | Owner instruction overrides the test-first workflow in docs/11 section 6. Release gates in docs/11 section 5 still apply before any production use. |
| D-003 | 2026-11-27 | Additive columns on `pf_tx` (amount, account_id, to_account_id, category_id, fee) as RPC-written projections; journal stays the financial truth. | Needed for transaction list without re-deriving from journal lines. |
| D-004 | 2026-11-27 | Extra system ledger account `SYS_FEE_EXPENSE` for transfer fees (BR-15). | Not in the reserved list of docs/12; spec change to report/confirm. |
| D-005 | 2026-11-27 | API validates only implemented commands (ACCOUNT_CREATE, TX_CREATE w/o splits/refunds, TX_REVERSE); others return NOT_IMPLEMENTED. | No fake success (AGENTS.md). |
| D-006 | 2026-11-27 | TX_CORRECT voids the old transaction and creates a NEW linked one (`related_tx_id`) instead of keeping the same id. | Spec wants the same id only to preserve source-event links; none exist before Gate 3. Revisit then. |
| D-007 | 2026-11-27 | Offline outbox stores whole commands with a fixed `command_id` in Keystore-backed secure storage; rejected commands stay visible until the owner discards them. | F04 "no silent data loss"; idempotency makes retries safe. |
| D-008 | 2026-11-27 | JWT verification supports legacy HS256 only when `SUPABASE_JWT_SECRET` is set; default is JWKS (asymmetric). | New Supabase projects use JWKS; older ones may not. |
| D-009 | 2026-11-27 | CSV import = client-side parse + one idempotent TX_CREATE per row with a deterministic command id (account + file fingerprint + row). | Gives re-import safety without new server tables; cross-source dedup stays in Gate 3. |
| D-010 | 2026-11-27 | Dashboard counts transfer fees, bad debt and interest as classified income/expense; only SYS_ADJUSTMENT_* is excluded. | docs/03 BR-15, BR-19, section 7. |

