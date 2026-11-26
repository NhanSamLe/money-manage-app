# 03 — Domain model & Financial Business Rules

## 1. Core concepts
A financial account represents a real store of value (bank, wallet, cash, actual savings, credit card), linked to a ledger account. A virtual saving goal is a reservation, not a second asset. Source event is evidence; it is not a transaction. Canonical transaction is a domain object with type, effective_at, memo, status and journal(s). Journal stores signed entries (debit +, credit −). Ledger accounts have class ASSET, LIABILITY, EQUITY, INCOME, EXPENSE, CLEARING (including suspense accounts). All entries integer VND; nonzero; sum zero per journal. Asset balances = sum signed entries, liability balances = negative signed entries. Negative bank balance allowed only when actual overdraft or pending reconcile; display warning. No mutable cached balance as source of truth.

Opening balance: debit real asset, credit opening equity; negative asset reverse signs. Opening credit card liability: credit liability, debit opening equity. Never report opening as income. Unknown opening = no journal and `baseline_known=false`; show movement total but balance unknown until reconciliation. Set baseline timestamp, ignore earlier source events for booking by default; historical import before cutoff requires replacing baseline atomically so no double count. Balance snapshot is observed evidence, not ledger adjustment.

## 2. Booking matrix (D = debit, C = credit)

| Rule | Event | D | C | Reporting |
|---|---|---|---|---|
| BR-01 | Salary/earned income | bank/cash | income | income + |
| BR-02 | Purchase | expense category | bank/cash | expense + |
| BR-03 | Internal transfer | destination asset | source asset | no income/expense |
| BR-04 | ATM withdrawal | cash | bank | no income/expense; fee separate |
| BR-05 | Deposit into actual savings | savings asset | bank | no expense |
| BR-06 | Interest earned | bank | interest income | income + |
| BR-07 | Lend principal | receivable | bank | neither; receivable increases |
| BR-08 | Borrow principal | bank | payable | neither; payable increases |
| BR-09 | Collect principal | bank | receivable | neither; debt reduces |
| BR-10 | Repay principal | payable | bank | neither; debt reduces |
| BR-11 | Interest paid | interest expense | bank | expense + |
| BR-12 | Credit card purchase | expense | card liability | expense + on purchase |
| BR-13 | Pay card balance | card liability | bank | no expense |
| BR-14 | Refund purchase | bank | original expense | expense decreases on refund date; link original |
| BR-15 | Transfer fee | fee expense | bank | expense + |
| BR-16 | Incoming unknown | bank | suspense | no classified income; unresolved credit |
| BR-17 | Outgoing unknown | suspense | bank | no classified expense; unresolved debit |
| BR-18 | Opening balance | asset/equity | equity/liability | excluded |
| BR-19 | Write off receivable | bad debt expense | receivable | expense +, no cash movement |
| BR-20 | Payable forgiven | payable | other income | income +, no cash movement; user confirms |
| BR-21 | Split bill paid upfront | expense own share + receivable others | bank | own share only expense |
| BR-22 | Cash discrepancy explicitly confirmed | asset or adjustment expense | asset or adjustment income | choose explicit reason; adjustment shown separately, not regular income/expense |

Use one journal with ≥2 entries; fee may be a third entry. E.g. bank debit movement −505000, wallet +500000, fee expense +5000. Canonical transaction status DRAFT, POSTED, VOID, MERGED. Pending evidence and needs review are derived flags from pf_source_event/pf_review; reversal is a journal purpose and a VOID transaction. An unresolved item may be posted to suspense and flagged review; do not count as known expense/income. Reclassify by reversal + replacement in a single command, preserving source links and transaction ID/revision. For a pending external source event without reliable amount/account/time do not book any journal. Never hard-delete a posted journal. Corrections use effective date chosen explicitly (default original effective date, audit recorded_at now); historical reports recalculate and show correction timestamp. Reversal of old record can have same effective date if correcting a mistake; real-world refund is separate event dated actual refund.

## 3. Source mapping and balance truth
- A bank API transaction is verified against provider authentication and account mapping but can still be incomplete. Prefer actual bank event ID and effective time, not delivery time. Notification alone is `PROVISIONAL` evidence; only book if validated settled movement and mapped account, tag coverage; when API available, use wait window e.g. 10min or show provisional transaction without duplicate. Manual transaction booked once, linked later to actual evidence.
- One source event can map to one canonical transaction; one canonical transaction can have multiple events (API/notification/statement/manual, both legs). Transfer matching is different from duplicate matching: transfer has two different account movements, duplicate same movement across sources. Store evidence relation role `PRIMARY`, `CORROBORATION`, `TRANSFER_LEG`, `MANUAL_MATCH`; store the event direction to distinguish transfer legs.
- API may report available balance rather than ledger balance. Compare like-for-like and same timestamp; mismatches cause review. Never infer exact amounts from balance difference if more than one transaction possible.
- Unknown notification title, pending payment, failed payment, OTP, promotional message, balance-only message → no booking; balance snapshot may be accepted separately when parser supports. Failed events retained minimal metadata only.

## 4. Transfers and cross-source matching
For VCB→MoMo top-up, source bank debit and wallet credit are linked, not two expenses. When first leg arrives, if explicit own-account transfer and target known, book source asset against `transfer clearing` (asset) and mark pending. On matching opposite leg, reverse the first-leg journal at its original effective time and post a replacement balanced journal containing both real account legs, preserving the same transaction ID. If settlement times straddle a report boundary, keep the first-leg and completion journals with distinct effective dates and document the in-transit balance; Gate 1 must implement/test this before enabling cross-period auto-match. If only debit and destination not certain, suspense instead. Clear on confirmation, not guessed. Include transfer clearing in net worth only when evidence proves ownership; ambiguous suspense excluded and flagged. Never match transfer merely equal amount. Bank-linked MoMo direct merchant payment: bank debit is expense; MoMo notification is same payment evidence if confirmed, wallet balance does not change. A genuine top-up followed by purchase is transfer + expense, not duplicate.

## 5. Debt lifecycle
`debt` per obligation with contact, direction RECEIVABLE/PAYABLE, principal opening amount, originated_at, due_at nullable, note, related original transaction. Ledger account per debt so balance deterministic. OPEN/PARTIAL/SETTLED/WRITTEN_OFF derive remaining principal; overdue = remaining>0 && due date < local today. Repayment must not exceed remaining unless explicit split into principal+interest/overpayment handling; do not infer interest. Partial repayment updates debt balance in same DB transaction. If API event already booked to suspense, reclassify existing movement; no second movement. Cashless historical debt opening creates receivable/payable vs equity at baseline, not current-period income. Group bill: user pays 600k for 3 people, own share 200k + two 200k receivables. Rounding remainder VND explicitly assigned. Write-off reason and confirmation mandatory. Changes to due date do not change money.

## 6. Savings, budgets, recurring
Savings allocation is virtual: reservation rows per goal/account, sum active reservation ≤ known positive available balance (unless user explicitly accepts overallocated after a new real withdrawal; warn, never block actual bank event). Goal target>0, allocation amount>0; releases/withdrawals via immutable movement record, progress=sum active allocation; actual bank savings deposits are transfers. Available spending = known liquid assets − reserved − optionally planned obligations (label scenario, not true balance). Budget by calendar month/category, cap positive, consumption = posted expense minus refunds in same report period; category hierarchy roll-up no double counting. Carryover optional; budget remaining can be negative. Unknown/suspense amounts displayed separately. Recurring schedule generates expected occurrence + reminder, not ledger; actual transaction matches one occurrence by time/amount/merchant and owner confirmation when uncertain. Rules pause/skip; monthly day 29/30/31 clamp to month end; next run local time, UTC stored.

## 7. Reporting definitions
- Period: [start,end) in Asia/Ho_Chi_Minh; UTC conversion; effective_at for finance, recorded_at for audit. Signed journal amounts from currently valid journals including reversal effects.
- Income = −sum(INCOME entries), net expense=sum(EXPENSE entries); optional adjustment income/expense excluded from regular income/expense and separately disclosed. Net savings flow = income − net expense; not the same as new deposits to savings goals. Savings rate = flow/income ×100 if income>0; else null. Cash movement in/out = sum of actual liquid asset entries by external leg; exclude internal transfers in consolidated view, include in per-account view. Distinguish noncash write-off from cash expenses.
- Net worth = known real assets + receivables + proven in-transit assets − liabilities − payables; virtual reservations excluded. Unknown baselines/valuation and suspense uncertainty → partial label; list affected account(s). Net worth history from ledger as-of plus as-of manual valuation, not from current balances retroactively. Unknown data ≠ zero.
- MoM %=(current−prior)/abs(prior)×100 if prior !=0; when no comparable period or prior zero, return null and absolute delta. For current partial month default compare same elapsed days of prior month, user can choose full prior month labeled. Use same filters and as-of policy. Income by source category; expense by category/merchant/contact; total not sum overlapping tags. Refunds may make net expense negative.
- Dashboard: account balances with freshness, current classified totals, unknown pending amounts, debt due, goal progress, budget. No "all up-to-date" if disabled or unverified sources. Export raw source provenance optional redacted, ledger and reports consistent.

## 8. Invariants / concurrency
BR-30: all financial mutation atomic in SQL function/transaction, row lock affected accounts/debts/transaction sorted ID order; journal balance enforced by posting guard; unique idempotency key + request hash, same key different input 409; no partially committed debt/ledger. BR-31: account ownership and class validate; archived account cannot new manual booking (incoming evidence review). BR-32: amount integer >0, upper bound 9,000,000,000,000,000 VND per movement; JSON strings, BigInt arithmetic; SQL totals numeric to prevent overflow. BR-33: correction optimistic version, stale command conflict. BR-34: negative principal impossible; never silently cap. BR-35: transaction evidence mapping unique by source event; manual merge audit. BR-36: data retention never deletes ledger, audit of monetary changes or unresolved evidence. BR-37: duplicate source IDs within provider connection rejected/merged; preserve repeated identical amounts with distinct bank IDs.

## 9. Worked examples
A: Opening VCB 10,000,000, MoMo 0. Salary +15,000,000, top up MoMo 500,000, MoMo spend 100,000, lend Nam 300,000, Nam repays 100,000, refund MoMo purchase 20,000. VCB 24,300,000; MoMo 420,000; receivable 200,000; net worth 24,920,000; income 15,000,000; expense 80,000; net savings flow 14,920,000. Transfer and principal not income/expense.
B: Borrow 1m, buy 250k on credit card, repay card 100k, repay loan 400k. Income 0, expense 250k, loan 600k, card 150k, savings rate N/A; initial zero cash → cash 500k; net worth −250k. 
C: Notification −80k, API same reference −80k, then distinct API transaction −80k same minute → exactly 2 movements; second remains distinct even equal amount. If no reference and ambiguous candidates, review rather than collapsing.
