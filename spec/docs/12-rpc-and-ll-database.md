# 12 - Database LLD and atomic RPC implementation plan

`db/001-baseline.sql` is the schema baseline, not the final command implementation. Create additive migrations 002+ implementing the RPCs below, test in disposable Supabase environment first. Do not expose private primitives as public API. Every public RPC is callable by server role only, validates singleton owner or tightly scoped provisioning; worker validates JWT + device before using service role. SQL money domains restrict individual amounts to +/-9e15; sum via numeric; cast result text at API boundary. Foreign keys and uniqueness plus transaction-time class/ownership checks are mandatory. No cascaded ledger deletion. No direct app read/writes. Supabase Auth owns credentials. Provider keys are Worker secrets, not database rows.

## 1. Physical schema conventions

See full DDL. UUIDs for aggregates, bigint identity for audit/change, `timestamptz` UTC, `date` for local due date. Every money row in canonical finance tables references the singleton owner directly or via parent. For children without owner_id check through FK and parent owner before any operation. `pf_device_source` stores consent/mapping; `pf_event_revision` immutable normalized revisions for same provider ID with changed content; `pf_rate_limit` hashed bounded rate buckets. No raw bank passwords, PIN, OTP, raw notification payload. Data dictionary docs/08 and physical DDL authoritative; `pf_ledger_account.class=CLEARING` for suspense, `ASSET` for proven owned funds in transit. Ledger code reserved `SYS_OPENING_EQUITY`, `SYS_SUSPENSE_CREDIT`, `SYS_SUSPENSE_DEBIT`, `SYS_TRANSFER_IN_TRANSIT`, `SYS_ADJUSTMENT_IN`, `SYS_ADJUSTMENT_OUT`, `SYS_BAD_DEBT`; define class mapping and seed per owner atomically. System categories and accounts cannot archive/change class. Use generated stable codes for categories and debt ledger accounts. Store balance after as evidence only; no update ledger from a snapshot without explicit command.

Indexes: owner/time/id on transactions; journal/ledger account index for balance; unique source identity within connection/device; candidate search account/direction/amount/time; job due/state, debt due/state, allocations by account, change owner/seq. Add measured indexes for review owner/state/created_at, category hierarchy, import state/expiry, source links tx_id, ledger account owner/class, category and contact lists; validate query plan under representative 10k-50k synthetic transactions. Do not add indiscriminate index on every field. Stable cursor sorted `effective_at DESC,id DESC`; encode cursor with validated range/filter signature, opaque; no offset for changes. Avoid unbounded scan from Worker; perform SQL aggregates and return <=100 records.

## 2. Required RPC catalog (names are internal planned, not existing provider APIs)

| RPC | Inputs | Atomic outputs / checks |
|---|---|---|
| pf_setup_reserve | fixed expected email verified Worker-side; lease UUID + expiry | lock singleton pf_setup; state UNINITIALIZED/INVITE_PENDING; one lease; never bind without verified invite |
| pf_setup_record_invite | lease_id, auth invite user UUID | lease match, record invite, retry/recover same auth identity |
| pf_setup_claim | verified auth user UUID, display_name | lock singleton; confirm invite id and verified email from auth, insert owner/settings/system ledgers/default categories, mark BOUND, return profile; replay same owner; other user denied |
| pf_device_register | owner, verified JWT session ID, device UUID, label | active owner, bind device to session; if device UUID reused require same owner and recent auth; increment version; no arbitrary session ID from body |
| pf_execute_command | owner, session/device context, command UUID, canonical hash, typed command/payload | one transaction receipt + locks + validate + dispatch to private function; journal + metadata + audit + change + response all commit or rollback |
| pf_receive_events | owner/system source context, bounded validated event array, source epoch | source enable/mapping checks; unique IDs; revisions on changed content; create job and evidence before ACK; per-event status |
| pf_claim_jobs | bounded limit, now, lease deadline | SKIP LOCKED, eligible due/expired lease, issue unique lease token; no duplicate active lease |
| pf_complete_job | job_id, lease_token, outcome, safe error, next_due | token and expiry match, mark complete/retry/dead; no stale writer |
| pf_process_event | owner, event_id, expected_version, job lease | lock affected aggregates and event, rerun identity match, stable event command key; atomically link/create/review; audit change |
| pf_commit_provider_page | owner, connection, expected cursor/epoch, validated events, next cursor | persist every event/job and checkpoint in one transaction; if any failure cursor unchanged; expired lease cannot commit |
| pf_reconcile | owner, account, verified snapshot ID | compare comparable basis/as_of; persist calculated/difference and review; never generate balancing entry automatically |
| pf_reserve_ai_cost | owner, reservation UUID, period, maximum microUSD, provider/model | lock settings row, check policy, sum spent + outstanding reserved, compare cap, insert RESERVED once |
| pf_settle_ai_cost | owner, reservation UUID, actual usage, outcome | lock reservation, one settlement; timeout UNKNOWN_CHARGE retain full reservation; release only proven no charge |
| pf_read_* | owner, validated filters/cursor | owner-scoped typed read model, paginated, no secret/raw provider fields |
| pf_export_start/page | owner, recent verified session, snapshot token, entity, cursor | consistent export snapshot, versioned manifest, no credentials; expiry; no mutable-as-of illusion |
| pf_rate_consume | hashed bucket, window, limit, expiry | atomic upsert increment, return allowed; prune expired, no PII |

Do not implement command dispatch via dynamic SQL. Use explicit case with typed input validation. Fail with stable domain errors (e.g. INVALID_AMOUNT, OWNER_NOT_BOUND, VERSION_CONFLICT, INSUFFICIENT_PRINCIPAL, ACCOUNT_ARCHIVED, BASELINE_UNKNOWN, SOURCE_DISABLED, BILLING_BLOCKED, AMBIGUOUS_MATCH, IDENTITY_CONFLICT, DUPLICATE_KEY_MISMATCH, AI_CAP_REACHED). The handler maps errors to OpenAPI envelope and correct HTTP status; unknown internal errors generic 503/500, safe correlation ID.

## 3. Atomic command pseudo-algorithm

```
BEGIN (one Postgres transaction)
verify owner/session/device as applicable
INSERT pf_command(owner_id,command_id,request_hash) ON CONFLICT DO NOTHING
SELECT receipt FOR UPDATE
if hash differs: raise conflict
if result exists: return prior result (wire status REPLAYED may be derived without mutating original)
validate command schema and actor policy
lock impacted aggregates in global order; validate expected versions and current source epochs
resolve canonical domain action; derive balanced lines internally
if posting:
    create pf_tx DRAFT or lock existing transaction
    call private post_journal (draft -> entries -> guarded posted)
    update transaction current_journal_id/status/version
if correction: reverse original current journal, then replacement if applicable; keep original evidence
update debt/payment, allocation, transfer/review, category/other aggregates as required
append redacted audit; append change per affected projection; compute result/change_seq
update receipt.result
COMMIT
return committed result
```

If anything fails, entire receipt and mutation roll back. For duplicate after lost response, existing committed receipt returned. Never return success until commit; never make HTTP/AI calls while locks held. For job-generated commands derive deterministic UUID from internal namespace and event/action ID, not request arrival. Import commits per-row/chunk explicitly PARTIAL with row outcomes; preserve same row ID and command receipt on retries; never create an entire journal twice. Commands with external verification (`CONNECTION_VERIFY`) schedule job or return pending; no network inside RPC. Connection secrets not passed in command payload.

## 4. Entity invariants and command implementations

- ACCOUNT_CREATE: create ledger account ASSET or LIABILITY, opening equity journal only if baseline pair supplied; opening zero sets known baseline with no zero entries. Credit card opening amount represents outstanding positive liability; map sign explicitly. Archive keeps history, no new manual booking. BASELINE_SET: preview historical overlap, compute adjustment from booked movements at as_of, explicit reason, no duplicate opening; if history pre-baseline included require atomic rebase/reversal, never silently include all historical data. Unknown baseline shows balance null.
- TX_CREATE: use BR matrix; verify kind/amount/account class and related IDs; category class matches P&L, split totals exact. Transfer supports asset to asset or asset to liability repayment, fee separate line; both own accounts distinct. Unknown direction posts to suspense; require account and reliable amount/time. Refund links original, sum net refunds cannot exceed original net unless reviewed; original and refund locks. Fee positive, for transfer principal + fee debits source. For P1 split bill one journal debit expense+receivable accounts, credit actual source; create debt rows with origin tx, sum invariant. Do not infer merchant reimbursement as income.
- TX_CORRECT/TX_REVERSE: prohibit direct mutation of posted journal or deletion. Validate linked debt and downstream payments, reverse exact signed entries with same effective timestamp for correction, post replacement using domain matrix. Reversal reason mandatory; preserve original source events and relation. A real refund is a separate transaction dated actual movement. For pending two-leg transfer, if legs have same reporting effective time, replace clearing journal atomically; if dates differ, maintain additional completion journal and signed clearing across periods, use all effective posted journals rather than only pointer. Define correction of all affected active journals and test before enabling cross-period transfer automation. If uncertain, review/manual confirmation.
- DEBT_CREATE: historical uses equity offset, no cash event; otherwise use actual account or existing eligible tx with reclassification, not both new cash and linked tx. Lock tx/related debts; one obligation per new debt ledger. Remaining from debit balance for receivable/credit balance for payable. DEBT_REPAY: principal >0, remaining >=principal, interest nonnegative, correct class and cash direction; existing cash event reclassified atomically; state updated from remaining. DEBT_WRITE_OFF: receivable bad-debt expense or payable forgiveness income, explicit reason; no cash. For reverse linked repayment restore principal and state, prevent negative/over-origin. Do not delete debt row with journals.
- GOAL_ALLOCATE/RELEASE: reservation sum on funding account locked, amount positive; allocation requires known sufficient unreserved eligible liquid asset, release <= goal/account allocated; ledger unaffected. New real debit may overallocate: flag, do not reject actual movement. Archive only zero reservation or explicit release. BUDGET_UPSERT: local YYYY-MM unique category (NULL overall), positive limit; actual net expenses roll up once, carryover policy deterministic.
- REVIEW_RESOLVE: verify review state/version, exact candidate links; LINK with proven same movement, KEEP_SEPARATE with explicit reason, IGNORE nonmovement only, POST valid canonical command, TRANSFER_MATCH opposite owned legs, RECLASSIFY typed domain action. For ambiguous duplicate with two postings, reversal of redundant canonical tx, MERGED status and evidence links redirected in same transaction, no deleting ledger. Store resolution and audit.
- DEVICE_SOURCE_SET/SOURCE_SET/SETTINGS_UPDATE: permission switches independent; global changes bump affected account epochs atomically, device map increments config_version, only owner+active session, no backdated bypass. API live gate capability and billing SAFE. Disabled source stops new ingest; preserve previously accepted data. No auto bank reconnection. Category hierarchy cycles checked recursively within transaction, prevent class change after used. Rule matcher declarative; versioned and bounded. Recurring templates never auto-post, match occurrence once. Reminder state expected, no financial mutation.

## 5. Read model formula and snapshot consistency

SQL aggregate posted journal entries joined to ledger accounts; sums numeric and output decimal text. For period use UTC boundaries converted from Asia/Ho_Chi_Minh. Income negative credit-net, expense positive debit-net, adjustment accounts excluded and separately shown; refund reversal offsets related category. Balance by real account as-of = sign by class times all signed entries to as-of; unknown baseline yields null. Debt balance, reserved amount computed from ledger/allocation, not mutable cached total. Net worth excludes virtual goals/suspense and reports unknown portion; proven transfer clearing included. `pf_change` is ordered mutation notification, not complete historical snapshot; for client incremental sync return current typed projection and sequence with cursor, use reset snapshot when gap; for export materialize consistent repeatable-read snapshot in bounded server-side data with recent auth/TTL, or operator pg_dump with restore verification. Do not claim consistent export from filtering current mutable rows by seq. Explain partial data and unknown snapshots in API and UI.

## 6. Test obligations before production

Fresh install and upgrade, database role grants and RLS, direct table writes denied for app, RPC denial for other owner, setup race, replay same/different hash, rollback after journal but before receipt, source duplicate race, concurrent repayment and allocation, double-entry sum, historical rebase, correction and refund, snapshot mismatch, job lease expiry, quota reservation race. Use real Postgres transactions with two connections for race tests; no mocking transaction semantics. Migration baseline is not a passed database test until these run. Record SQL version and output in implementation status.
