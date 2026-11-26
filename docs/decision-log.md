# Decision log

| ID | Date | Decision | Why |
|---|---|---|---|
| D-001 | 2026-11-27 | Brand MoMa (MoneyManage). Repo `moma/` with spec copied to `spec/` unchanged. | Owner request; spec requires repo layout in docs/11 section 2. |
| D-002 | 2026-11-27 | Owner decision: write code first, run tests later (single-user app). Nothing is reported as tested until actually run. | Owner instruction overrides the test-first workflow in docs/11 section 6. Release gates in docs/11 section 5 still apply before any production use. |
| D-003 | 2026-11-27 | Additive columns on `pf_tx` (amount, account_id, to_account_id, category_id, fee) as RPC-written projections; journal stays the financial truth. | Needed for transaction list without re-deriving from journal lines. |
| D-004 | 2026-11-27 | Extra system ledger account `SYS_FEE_EXPENSE` for transfer fees (BR-15). | Not in the reserved list of docs/12; spec change to report/confirm. |
| D-005 | 2026-11-27 | API validates only implemented commands (ACCOUNT_CREATE, TX_CREATE w/o splits/refunds, TX_REVERSE); others return NOT_IMPLEMENTED. | No fake success (AGENTS.md). |
