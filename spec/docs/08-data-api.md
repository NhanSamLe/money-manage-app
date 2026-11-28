# 08 — Logical data dictionary and internal API contract

## 1. Entity map
Schema baseline `db/001-baseline.sql` uses PostgreSQL `public.pf_*`; all user data belongs to singleton owner. Implement required business RPCs in subsequent migrations. Baseline includes constraints, core posting guard and RLS deny-direct-client; not a complete deployed backend. For all mutable entities `version` starts 1; update only with expected version. UUID IDs generated server or client for idempotent create. `timestamptz` UTC, `date` local calendar dates, money `bigint` VND. JSON wire money string. PII fields minimized. Account/transaction relationships enforce singleton ownership via service checks and FK. IDs stable across backup; external IDs not globally unique.

| Entity | Key fields / constraints | Notes |
|---|---|---|
| pf_setup | singleton=1, state, invite user, lease, expiry | one setup, no stored plaintext secret; owner binding atomic |
| pf_owner | singleton=1, user_id unique auth.users FK, name, locale, zone, setup step, session_epoch | exactly one after setup |
| pf_device | id, owner, label, session identifier, active, config_version, last_seen | token/device binding and revoke |
| pf_settings | owner PK, api_global, notification_global, AI mode, cap, preferences | default OFF; audit config |
| pf_ledger_account | class, code unique, category/debt linkage via related entities, archived | debit-positive |
| pf_account | institution, kind, name, last4, ledger_account_id unique, baseline_known/at, toggles, epoch | one per real account, not goal |
| pf_balance_snapshot | account, as_of, amount, basis, source | observation not journal |
| pf_category | parent, type, name, ledger_account_id unique, archive | category-specific income/expense account; no cycles |
| pf_contact | alias, note optional, archive | contact not auth user |
| pf_tx | kind, status, effective_at, note, merchant, contact, version | canonical user-facing transaction |
| pf_journal | tx_id, effective_at, purpose, reversal_of unique | immutable posted journal |
| pf_entry | journal, ledger account, signed amount | >=2, sum zero posting guard |
| pf_connection | institution/provider/external mapping, enabled, epoch, capability/health/billing, cursor | no raw provider secrets |
| pf_source_event | connection/device, account, delivery/external ID, amount/direction/time/ref, settlement, payload sanitized, state | unique stable keys; evidence |
| pf_event_link | event_id unique, tx_id, role | many sources to one transaction |
| pf_review | event/tx, type, reason, candidates, resolution | unresolved inbox |
| pf_reconciliation | account, snapshot, calculated amount, difference, status | comparable basis |
| pf_debt | contact, ledger account, direction, principal, due, origin tx, state | remaining from ledger, no mutable independent truth |
| pf_debt_payment | debt, tx, principal, interest, kind | unique link; atomic posting |
| pf_goal | target, due, state | virtual only |
| pf_allocation | goal, account, signed amount, reason, reversal_of | virtual reserve movement |
| pf_budget | month, category nullable overall, limit, carryover | unique per month/category |
| pf_recurring | template, amount, interval, next due, enabled | expected not actual |
| pf_occurrence | recurring, due date unique, matched tx | no duplicate reminder |
| pf_rule | priority, matcher, result, enabled, version | owner-approved classification |
| pf_ai_proposal | validated payload, state, expiry, expected version | not ledger |
| pf_ai_usage | period, provider, model, reserved/spent microUSD, state | atomic budget reserve |
| pf_job | type, key, state, due, lease, attempts, payload | durable retry |
| pf_command | owner/idempotency unique, request hash, result | replay same outcome |
| pf_change | monotonic sequence, entity, ID, version, op | device incremental sync |
| pf_audit | actor, action, target, redacted before/after, timestamp | no OTP/secret |
| pf_attachment | tx, private object key, mime, size, hash | optional local-only |
| pf_reminder | due, kind, target, status | own reminders only |

Tags: `pf_tag`, `pf_tx_tag`; merchant normalized alias in transaction + rule, no separate merchant table MVP. `pf_entry` category association via ledger_account, optional classification category in read model; split derived from expense/income lines. Refund relation via `pf_tx.related_tx_id`. Account balance and debt remaining computed via SQL aggregate (or derived materialized cache invalidated atomically, not source truth). Row ordering use `effective_at,id` or change sequence. Index on entries ledger account, tx effective time/status, source account/amount/time, jobs due, debts due. Historical source payload retention should retain event ID, reference hash and links.

## 2. API principles
Base `https://api.<domain>/v1`. JSON only; bearer owner JWT except health/setup and authenticated provider webhook. Device endpoints require active device binding. All mutation commands via POST `/commands` with header `Idempotency-Key` UUID + body `command_id` same UUID; server canonical JSON hash. Same key/same hash returns prior response; same key/different hash 409. Read endpoints cursor paging max 100, default 50. All read filters validated, no arbitrary SQL, exact owner. Date format ISO 8601; local date `YYYY-MM-DD`; report months `YYYY-MM`. HTTP 400 invalid syntax, 401 invalid/expired, 403 wrong owner/revoked/disabled, 404 not found (no cross-owner disclosure), 409 version/conflict/idempotency mismatch, 422 domain rule, 429 quota/rate, 503 temporary provider/cloud. Error envelope `{error:{code,message,field?,retryable,request_id,details?}}`; details safe. Success `{data:...,meta:{request_id,as_of?,next_cursor?,coverage?}}`. Never echo secrets. Use `Retry-After` where applicable. Contracts in `contracts/openapi.yaml` for internal routes; external provider APIs must follow official docs, not internal contract.

## 3. Command catalog (normative payloads)
`payload` object validated by discriminated command type; optional fields only as listed. Amount fields positive integer strings unless signed/zero allowed stated. IDs UUID. `expected_version` required for edits, not create. Generic command result `entity_id,version,change_seq,status,review_id?`. If uncertain source matching return review, no silent posting.

| command_type | payload fields | Semantics |
|---|---|---|
| ACCOUNT_CREATE | kind,institution,name,last4?,opening_amount?,baseline_at? | baseline pair; signed opening allowed, unknown omitted |
| ACCOUNT_UPDATE | account_id,name?,archived?,hidden?,expected_version | cannot change ledger class/baseline after booking except correction |
| BASELINE_SET | account_id,amount,as_of,expected_version,reason | explicit preview/rebase, no double history |
| SOURCE_SET | account_id,api_enabled,notification_enabled,expected_version | independent toggles, epoch increment for changed source |
| SETTINGS_UPDATE | api_global?,notification_global?,ai_mode?,ai_cap_micro_usd?,preferences?,expected_version | enable only capability and fee safe |
| CONNECTION_CREATE | account_id,provider,external_account_alias | provider configured server-side; pending verify |
| CONNECTION_PAUSE | connection_id,expected_version | local pause, upstream state separate |
| CONNECTION_VERIFY | connection_id,expected_version | documented API verify + quota |
| TX_CREATE | kind,account_id,amount,effective_at,category_id?,to_account_id?,contact_id?,note?,merchant?,splits?,related_tx_id?,fee? | kind allowed INCOME/EXPENSE/TRANSFER/REFUND_EXPENSE/REFUND_INCOME/UNKNOWN_CREDIT/UNKNOWN_DEBIT; debt via separate commands |
| TX_ANNOTATE | tx_id,note?,merchant?,contact_id?,category_id?,splits?,expected_version,learn_rule? | metadata or reclassification reversal/repost |
| TX_CORRECT | tx_id,replacement,reason,expected_version | atomic reversal + replacement; actual refund separate |
| TX_REVERSE | tx_id,reason,expected_version | compensating entries, debt links handled atomically |
| REVIEW_RESOLVE | review_id,decision,tx_id?,account_id?,category_id?,reason?,expected_version | LINK/KEEP_SEPARATE/IGNORE/POST/TRANSFER_MATCH/RECLASSIFY; validate required fields per decision |
| IMPORT_COMMIT | import_id,accepted_row_ids | preview must be server-stored and immutable; idempotent per row |
| CONTACT_CREATE | alias,note? | no login user |
| DEBT_CREATE | direction,contact_id,account_id?,principal,originated_at,due_date?,note?,existing_tx_id?,historical? | opening/actual/linked movement paths; no double booking |
| DEBT_REPAY | debt_id,account_id,principal,interest?,effective_at,existing_tx_id?,expected_version | principal <= remaining, payment and ledger atomic |
| DEBT_UPDATE | debt_id,contact_id?,due_date?,note?,principal?,expected_version | principal only while no repayment/write-off is in effect (DEBT_HAS_PAYMENTS); reversal + replacement journal (D-019) |
| DEBT_PAYMENT_REVERSE | debt_id,payment_id,expected_version | undo one repayment/write-off: reverse its tx (VOID), restore remaining + state |
| DEBT_CANCEL | debt_id,expected_version,reason? | confirm; reverse every active payment + origin tx; state CANCELLED, hidden from lists; row kept |
| DEBT_WRITE_OFF | debt_id,amount,reason,effective_at,expected_version | confirm, <= remaining |
| GOAL_CREATE | name,target,due_date? | virtual goal |
| GOAL_ALLOCATE | goal_id,account_id,amount,expected_version | add reservation, check available |
| GOAL_RELEASE | goal_id,account_id,amount,expected_version | release ≤ allocation |
| GOAL_UPDATE | goal_id,name?,target?,due_date?,state?,expected_version | archive if allocation released |
| BUDGET_UPSERT | month,category_id?,limit,carryover,expected_version? | unique month/category |
| CATEGORY_UPSERT | category_id?,name,type,parent_id?,archived?,expected_version?,icon?? | no cycle/class change after use |
| RULE_UPSERT | rule_id?,matcher,result,priority,enabled,expected_version? | safe declarative exact match, no executable regex from remote |
| RECURRING_UPSERT | recurring_id?,name,kind,account_id,amount,interval,next_date,enabled,expected_version?,category_id?,to_account_id? | expected only |
| OCCURRENCE_MATCH | occurrence_id,tx_id,expected_version | one actual tx/occurrence unless explicit split |
| DEVICE_REVOKE | device_id,expected_version | reject new requests, stop local collection on next sync |
| AI_ACCEPT | proposal_id,edits?,expected_version? | validated typed command, no arbitrary action |
| AI_DISMISS | proposal_id | no mutation finance |
| REMINDER_UPSERT | reminder_id?,kind,target_id,due_at,enabled,expected_version? | reminder only |

Required validation TX_CREATE: amount>0; account exists; INCOME category type INCOME or suspense, EXPENSE type EXPENSE or suspense; TRANSFER to_account_id distinct owned; refund original tx linked and amount not beyond net original unless explicit review; split each positive, sum equals amount, no mixing incompatible classes. `splits` array `{category_id,amount}`. Use BR matrix, do not expose arbitrary journal entry mutation. Transaction correction linked debt must require domain-specific correction and principal constraint. All command handlers use one SQL transaction and return existing receipt on retries. Lock idempotency record before business mutation, not after. Auth/setup is separate from command catalog. Import preview sends normalized CSV rows (batch max 100) and source evidence; parsing local, server validates and dedup; commit may process chunks, report per-row success/review/error, never claim entire batch posted on partial failure.

## 4. Read APIs and examples
- `GET /accounts` balances and coverage, `/transactions` filter period/account/category/status/search, `/transactions/{id}` detail evidence/audit summary; `/review` pending; `/debts`, `/goals`, `/budgets?month=...`, `/recurring`, `/categories`, `/rules`, `/contacts`, `/reminders`, `/devices`, `/settings`, `/integrations`, `/reports/summary?from=...&to=...`, `/reports/series`, `/sync/changes?cursor=...`, `/ops/usage`. Return money strings and ISO dates; `null` unknown. Use keyset not offset for sync. Report summary fields `income,expense,net_savings,net_worth?,savings_rate?,unclassified_credit,unclassified_debit,coverage,accounts,as_of`; ratio number or null, rounding display only. `GET /export` page/manifest with stable snapshot sequence; require recent auth for sensitive export. Backup restore operator gated, not anonymous API.
- `/events/notifications` batch device events with epoch and delivery IDs; per-event ACK statuses accepted/duplicate/review/disabled/rejected; persist accepted before ACK. `/webhooks/{provider}/{connection_id}` external auth and provider-specific response. `/integrations/{id}/sync` schedules job only, respects capability/quota. `/imports/preview`, `/ai/proposals`, `/ai/query` (read-only), `/devices/register`, `/setup/start`, `/setup/claim`, `/health`, `/auth/config`. Auth login/password/reset via Supabase SDK, not proxy storing password. `/setup/start` one-time code fixed email, generic result; `/setup/claim` requires verified invite user JWT and binds owner. Unknown endpoint returns 404. OpenAPI describes common wire fields; command-specific payloads are specified in commands.schema.json. Cross-field rules remain enforced by domain/RPC.

## 5. Additional command extensions and exact wire conventions

Normative structured payloads and required fields are in `contracts/commands.schema.json`; OpenAPI is bundled from the same schemas. All commands include `schema_version=1`, `command_id`, `command_type`, `payload`. `expected_version` is the affected aggregate revision, not a global counter. Unknown fields rejected. `CONTACT_UPDATE` changes alias/note/archive; `DEVICE_SOURCE_SET` updates device/account/package consent and mapping (expected_version is pf_device.version; increment version and config version; refuse ambiguous maps); `PROFILE_UPDATE` updates owner wizard state/name; `TAG_UPSERT` and `TX_TAG_SET` label transactions; `ADJUSTMENT_CREATE` explicit confirmed nonzero correction distinct from income/expense; `SPLIT_BILL_CREATE` P1 splits actual payment into own expense and one debt per contact; total shares + own_share = amount. Tags, category icon and recurring category/destination reflected in SQL.

Read models return exactly the OpenAPI resource fields; no raw SQL rows. Coverage state COMPLETE_VERIFIED only for fully reconciled account/period evidence, otherwise PARTIAL/UNKNOWN/STALE. Source event identifiers, hashes and source links available via transaction detail projection extension only when safe. `amount` on transaction is primary movement absolute amount, null when unresolved, never sum signed entries (zero); for transfer distinguish fee from principal using legs/categories. UI reports computed from journal, not transaction amount. Device notification requests supply account_id (nullable), package_name, epoch and config_version; derive device_id from bound session, source/evidence_quality from server, never trust client VERIFIED. API webhook shape/auth is intentionally provider-specific. Sync changes carry validated resource snapshots; implement a consistent snapshot token/short-lived materialized export or repeatable-read operator dump, not a naive mutable `seq` filter. Export/import restore formats must be versioned; see deployment and RPC spec.

User logout uses Supabase SDK plus server-side device revoke/session invalidation. For reset/change-password advance session epoch and invalidate active device binding server-side; verify current token session/auth_time against revocation policy on every protected call. Setup secret checked in Worker (fixed email in secret), not in database. `SOURCE_SET` updates account epochs only for affected toggles; global changes bump all affected account epochs, device mapping changes bump device config version. Old accepted inbox events retain original epoch; reject or quarantine events arriving later under revoked config.
