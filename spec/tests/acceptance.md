# Acceptance contract and test matrix

Every case below must become automated tests where feasible; real-device/provider/email evidence is a separate live gate. All values synthetic. No financial data or secrets. A static specification verification pass is not a product test pass. Fixture IDs link to tests/fixtures.json. Expected ledger and reports computed deterministically, not LLM. Mark NOT_RUN until actual test evidence.

| Test ID | Requirement IDs | Given / When / Then |
|---|---|---|
| AUTH-01 | AUTH-01,SET-01,NFR-04 | Fresh deployment, two parallel setup requests; only fixed email + valid one-time secret can reserve; verified invite binds exactly one owner, second owner denied; resume after crash without duplicate. |
| AUTH-02 | AUTH-02,NFR-04 | Invalid JWT issuer/audience/expired token/other user => 401/403; valid owner login via SDK then device registration. Never public signup. |
| AUTH-03 | AUTH-03 | Forgot password returns same visible response for existing/unknown email; real Resend email link opens verified domain, expired/replayed token fails, new password works; prior sessions revoked as policy. |
| AUTH-04 | AUTH-04,OFF-01 | Revoke device while offline; subsequent upload rejected even if access token unexpired; logout stops listener and preserves encrypted pending queue for same owner or explicit discard. |
| AUTH-05 | AUTH-02,AUTH-04 | Rate limit brute force/recovery/invite; recent auth for password change/export/delete; no account enumeration. |
| UX-01 | SET-01,ACC-01,NFR-05 | Welcome two choices, wizard W00-W13, permission denial and skip, rotation/restart resume, existing owner on new device login path. |
| UX-02 | TX-01,TX-02,TX-05,NFR-05 | Quick text 45k, review, confirm, undo, category/tag edit, list filter and details; no required unnecessary fields, screen states and TalkBack. |
| UX-03 | DEBT-01,SAV-01,BUD-01,REC-01,REP-01 | Dashboard drills into correct reports; debt partial/goal/budget/recurrence screens use actual vs planned labels, empty/stale/offline states. |
| FIN-01 | TX-01,NFR-04,NFR-06 | All posted journal sum zero, >=2 nonzero entries; direct app SQL denied; simulate failure after ledger before receipt -> no changes; replay after lost ACK no extra journal; different hash same ID 409. |
| FIN-02 | ACC-01,ACC-02 | Opening known positive/zero/negative/credit card liability; unknown baseline null; import pre-cutoff requires explicit rebase; archive retains history. |
| FIN-03 | TX-01,TX-05 | Fixture F01: salary/topup/spend/loan/repay/refund; VCB 24.3m, wallet 420k, receivable 200k, net worth 24.92m, expense 80k. |
| FIN-04 | TX-01 | Fixture F02: borrow/card spend/card repayment/loan repayment; income 0, expense 250k, net worth -250k, savings rate null. |
| FIN-05 | TX-02,TX-05,CAT-01 | Split sum mismatch rejected; reclassify via reversal+replacement; old posted immutable; same-version parallel edits one conflicts; refund limit and link enforced. |
| FIN-06 | TX-01,INT-05 | Unknown inflow/outflow posted suspense, not classified income/expense; insufficient info not posted; explicit adjustment separated; transfer fee only expense. |
| FIN-07 | REP-01,REP-02,REP-03 | Local month boundary 00:00 ICT, UTC timestamp, half-open interval; MoM 0 denominator null, historical correction, provisional/unknown coverage visible; budget roll-up no double count. |
| FIN-08 | DEBT-01,DEBT-02 | Two obligations same contact, partial repayment links correct debt and date; overdue derived; concurrent 2x repayment exceeding principal one fails; no negative principal. |
| FIN-09 | DEBT-02 | Match existing debit to loan without duplicate cash movement; historical debt equity, writeoff/forgiveness and payment interest treated by matrix; linked correction guarded. |
| FIN-10 | DEBT-03 | 600k split bill own 200k and 2x200k receivables; only own share expense; rounding explicit; reimbursements reduce debt. |
| FIN-11 | SAV-01,SAV-02 | Virtual allocation 2m does not change net worth/income/expense, concurrent reservations bounded, real bank withdrawal may overallocate warns. |
| FIN-12 | BUD-01 | Category/overall cap, refund lowers net expense, 80/100 warning, carryover configured, overspend doesn't block real event. |
| FIN-13 | REC-01 | Month-end clamping, leap day, pause/skip, one occurrence per date, no actual ledger until confirmed actual. |
| INT-01 | INT-01,INT-04 | Four modes 00/10/01/11 with global/account/device gating; off stops new collection; no historical deletion; verify old epoch rejection; manual always works. |
| INT-02 | INT-02,INT-06 | VCB/MoMo/ZaloPay/VNPAY no fabricated AIS; TPBank/MB adapter POC with provider docs; capability and billing guard; unsupported API switch disabled. |
| INT-03 | INT-03,TX-03 | F03 same movement notification/API exact ref in either order + lost ACK + concurrent; one canonical movement; distinct bank IDs equal amount not merged. |
| INT-04 | INT-03,INT-05 | F04 ambiguous same amount/time without evidence -> review; transfer opposite legs only with ownership proof; direct MoMo funding not topup; never assume merchant label. |
| INT-05 | INT-03 | Provider auth invalid/replay, 429/5xx, cursor page failure, job lease expires, crash after persistence, polling overlap; durable ACK and checkpoint only after all events saved. |
| INT-06 | TX-04,INT-05 | CSV preview with duplicate/invalid/unknown accounts; explicit accept, row-level result, retry same import id; historical cutoff check. |
| INT-07 | INT-05,REP-01 | Compare booked snapshot at same timestamp; difference shown, incomparable available balance not forced; gap import reconciles, no fake adjustment. |
| SYNC-01 | OFF-01,NFR-06 | Offline command/event queued before send; kill app/reboot/retry same ID, retain until durable ACK; no booked UI total for pending. |
| SYNC-02 | OFF-01 | Two devices change same version; one conflict, no silent overwrite; cursor pages atomic local apply; stale cursor triggers full reset. |
| SYNC-03 | INT-01,OFF-01 | Device permission/config revoked while offline; queue rejected/quarantined on reconnect; source epoch comparison, no bypass. |
| AI-01 | AI-01,AI-02,CAT-02 | Slang, local relative date, 50k/2tr, exact known rule, ambiguous 1.2 -> ASK; confirm rule learning, no unnecessary calls. |
| AI-02 | AI-01,AI-02 | F05 malformed JSON, unknown properties, invented IDs, ambiguous past transaction, prompt injection; reject or review, no financial write. |
| AI-03 | AI-03,REP-01 | Chat asks monthly expense; SQL typed query returns exact totals, as_of and coverage; AI cannot execute SQL/write; OFF still usable. |
| AI-04 | AI-04,NFR-08 | Free provider limit, paid disabled, price unknown, concurrent reservations at cap, timeout uncertain charge; no fallback to paid. |
| AI-05 | AI-05,TX-06 | Voice/OCR permissions denied -> text fallback; receipt subtotal/total conflict -> review; digest and forecast labeled approximate. |
| SEC-01 | AUTH-01,NFR-04 | Setup takeover, wrong email, expired lease, race and stale invite fail closed. |
| SEC-02 | NFR-04 | Wrong owner/JWT issuer/device binding denied, no cross-instance cache access. |
| SEC-03 | AUTH-04 | Revoke/password reset invalidates device according to session policy; token replay denied. |
| SEC-04 | NFR-04 | anon/authenticated cannot read/write pf_* or execute privileged RPC; service-role only Worker; secrets absent APK/repo/log. |
| SEC-05 | INT-03 | Verify provider documented auth before parsing and durable receive; tampered body and replay handled; unknown provider denied. |
| SEC-06 | INT-04 | Unapproved package/spoofed label/summary/unsupported notification ignored; actual VCB/MoMo permission grant/deny, OEM restriction, lock screen. |
| SEC-07 | INT-04,AI-04,NFR-08 | OTP, PIN, auth prompt, phone/account numbers excluded before persistent storage/network/AI; inspect local DB and logs. |
| SEC-08 | AI-01,NFR-04 | Prompt text and merchant content contain hostile instructions; strict schemas, safe query whitelist, no arbitrary actions. |
| SEC-09 | NFR-04 | Provider URL/redirect SSRF denied; HTTPS only; no trust-all cert; input limits. |
| SEC-10 | OPS-01,OPS-02 | Private attachments/export, recent auth, encrypted archive, invalid checksum rejected, restore owner mapping, no secrets. |
| COST-01 | AI-04,NFR-01,NFR-07 | Atomic reserve maximum cost, concurrent attempts cannot exceed cap, 80% warning, no auto-topup/upgrade, unknown charge kept. |
| COST-02 | INT-06,NFR-01 | SePay permits overage; app ingest pause alone cannot stop upstream charges; API disabled until hard fee safety verified; disconnect status truthful. |
| OPS-01 | OPS-01,NFR-01,NFR-07 | Cloudflare/Supabase/Resend actual free plans, paused DB/429/503 offline and recovery; no server needed, measured CPU/quota. |
| OPS-02 | OPS-01,NFR-10 | Export consistent snapshot and restore staging; counts, journal sums, account/debt balances identical; no secrets; weekly reminder if configured. |
| OPS-03 | OPS-02,NFR-08 | Recent auth typed confirmation before destructive instance wipe, backup and explicit operator procedure; immutable audit and no bank-side account deletion. |
| PERF-01 | NFR-02,NFR-07 | Measure P95 read/mutation latency on representative synthetic dataset and Worker CPU; report actual measurements and tune or document gap; no SLA claim. |
| AND-01 | NFR-03,INT-04 | Verify min SDK 26 and target current release policy; Android 13+ own-notification permission distinct from listener access, actual permission/revoke/reboot tests. |
| ASSET-01 | ACC-03 | P1 deferred unless manual asset valuation flow and as-of history implemented, no fake valuation; P0 may record OTHER accounts only; track scope and do not claim investment support. |
| ENG-01 | NFR-09 | Contract validation, dependency boundaries, generated types diff, lint/typecheck, DB fresh/upgrade and test evidence in CI; fail if skipped critical. |

## Mandatory live POC matrix

On owner Android, capture consented sanitized fixtures for each supported source: ordinary credit/debit, QR, card, wallet topup/direct funding, refund/fee, identical amounts, lock screen, process killed/reboot, offline, permission disabled, format change. Check actual bank statement and balances. For API: document official auth, inbound/outbound and account scope, data delay, backfill, webhooks and retry, upstream pause, hard no-fee option; do not test live paid feature without explicit consent. Record result and sample hash, not raw PII. Real email invite/reset and Android app links must be checked. Keep unsupported source disabled. No real money transfer required merely to run tests.
