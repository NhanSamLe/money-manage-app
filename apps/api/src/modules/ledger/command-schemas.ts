import { z } from "zod";

const uuid = z.string().uuid();
const posMoney = z.string().regex(/^[1-9][0-9]{0,15}$/);
const anyMoney = z.string().regex(/^(?:0|-?[1-9][0-9]{0,15})$/);
const nonNegMoney = z.string().regex(/^(?:0|[1-9][0-9]{0,15})$/);
const iso = z.string().datetime({ offset: true });
const localDate = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/);
const month = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/);
const version = z.number().int().min(1).max(2147483647);

function command<T extends string, P extends z.ZodTypeAny>(type: T, payload: P) {
  return z.object({ command_id: uuid, command_type: z.literal(type), schema_version: z.literal(1), payload }).strict();
}

const accountCreate = command(
  "ACCOUNT_CREATE",
  z
    .object({
      kind: z.enum(["BANK", "WALLET", "CASH", "SAVINGS", "CREDIT_CARD", "OTHER"]),
      institution: z.string().min(1).max(40),
      name: z.string().min(1).max(120),
      last4: z.string().regex(/^[0-9]{4}$/).optional(),
      opening_amount: anyMoney.optional(),
      baseline_at: iso.optional(),
    })
    .strict()
    .refine((p) => (p.opening_amount === undefined) === (p.baseline_at === undefined), "opening_amount and baseline_at go together"),
);

const txCreate = command(
  "TX_CREATE",
  z
    .object({
      kind: z.enum(["INCOME", "EXPENSE", "TRANSFER", "UNKNOWN_CREDIT", "UNKNOWN_DEBIT"]),
      account_id: uuid,
      amount: posMoney,
      effective_at: iso,
      category_id: uuid.optional(),
      to_account_id: uuid.optional(),
      contact_id: uuid.optional(),
      note: z.string().max(1000).optional(),
      merchant: z.string().min(1).max(120).optional(),
      fee: posMoney.optional(),
      /** Where the entry came from. BANK / RECURRING / SYSTEM are set by the server only (migration 009). */
      source: z.enum(["MANUAL", "AI", "NOTIFICATION", "IMPORT"]).optional(),
    })
    .strict()
    .superRefine((p, ctx) => {
      if ((p.kind === "INCOME" || p.kind === "EXPENSE") && !p.category_id) ctx.addIssue({ code: "custom", message: "category_id required" });
      if (p.kind === "TRANSFER" && !p.to_account_id) ctx.addIssue({ code: "custom", message: "to_account_id required" });
    }),
);

const txReverse = command("TX_REVERSE", z.object({ tx_id: uuid, reason: z.string().min(1).max(1000), expected_version: version }).strict());

const contactCreate = command("CONTACT_CREATE", z.object({ alias: z.string().min(1).max(80), note: z.string().max(500).optional() }).strict());
const contactUpdate = command(
  "CONTACT_UPDATE",
  z.object({ contact_id: uuid, expected_version: version, alias: z.string().min(1).max(80).optional(), note: z.string().max(500).optional(), archived: z.boolean().optional() }).strict(),
);

const debtCreate = command(
  "DEBT_CREATE",
  z
    .object({
      direction: z.enum(["RECEIVABLE", "PAYABLE"]),
      contact_id: uuid,
      principal: posMoney,
      originated_at: iso,
      account_id: uuid.optional(),
      due_date: localDate.optional(),
      note: z.string().max(500).optional(),
      historical: z.boolean().optional(),
    })
    .strict()
    .refine((p) => p.historical === true || p.account_id !== undefined, "account_id required unless historical"),
);
const debtRepay = command(
  "DEBT_REPAY",
  z.object({ debt_id: uuid, account_id: uuid, principal: posMoney, effective_at: iso, expected_version: version, interest: nonNegMoney.optional() }).strict(),
);
const debtWriteOff = command(
  "DEBT_WRITE_OFF",
  z.object({ debt_id: uuid, amount: posMoney, reason: z.string().min(1).max(1000), effective_at: iso, expected_version: version }).strict(),
);

/** Person, due date (null clears it), note; principal only while nothing was repaid / written off (migration 014). */
const debtUpdate = command(
  "DEBT_UPDATE",
  z
    .object({
      debt_id: uuid,
      expected_version: version,
      contact_id: uuid.optional(),
      due_date: localDate.nullable().optional(),
      note: z.string().max(500).optional(),
      principal: posMoney.optional(),
    })
    .strict(),
);
/** Undo one repayment or write-off: its transaction is reversed and the remaining principal restored (migration 014). */
const debtPaymentReverse = command(
  "DEBT_PAYMENT_REVERSE",
  z.object({ debt_id: uuid, payment_id: uuid, expected_version: version }).strict(),
);
/** "Xóa khoản nợ": reverses every payment and the origin transaction; the debt becomes CANCELLED (migration 014). */
const debtCancel = command("DEBT_CANCEL", z.object({ debt_id: uuid, expected_version: version, reason: z.string().max(200).optional() }).strict());

const goalCreate = command("GOAL_CREATE", z.object({ name: z.string().min(1).max(120), target: posMoney, due_date: localDate.optional() }).strict());
const goalMove = z.object({ goal_id: uuid, account_id: uuid, amount: posMoney, expected_version: version }).strict();
const goalAllocate = command("GOAL_ALLOCATE", goalMove);
const goalRelease = command("GOAL_RELEASE", goalMove);

const budgetUpsert = command(
  "BUDGET_UPSERT",
  z.object({ month, limit: posMoney, carryover: z.boolean(), category_id: uuid.optional(), expected_version: version.optional() }).strict(),
);

const categoryUpsert = command(
  "CATEGORY_UPSERT",
  z
    .object({
      name: z.string().min(1).max(80),
      type: z.enum(["INCOME", "EXPENSE"]),
      category_id: uuid.optional(),
      parent_id: uuid.optional(),
      archived: z.boolean().optional(),
      expected_version: version.optional(),
      icon: z.string().max(40).optional(),
    })
    .strict()
    .refine((p) => p.category_id === undefined || p.expected_version !== undefined, "expected_version required when updating"),
);

const recurringUpsert = command(
  "RECURRING_UPSERT",
  z
    .object({
      name: z.string().min(1).max(120),
      kind: z.enum(["INCOME", "EXPENSE", "TRANSFER"]),
      account_id: uuid,
      amount: posMoney,
      interval: z.enum(["WEEKLY", "MONTHLY", "YEARLY"]),
      next_date: localDate,
      enabled: z.boolean(),
      recurring_id: uuid.optional(),
      expected_version: version.optional(),
      category_id: uuid.optional(),
      to_account_id: uuid.optional(),
    })
    .strict()
    .refine((p) => p.recurring_id === undefined || p.expected_version !== undefined, "expected_version required when updating"),
);

const occurrenceMatch = command("OCCURRENCE_MATCH", z.object({ occurrence_id: uuid, tx_id: uuid, expected_version: version }).strict());

// ---- Recurring rules with bill splitting (migration 016, D-022)

const splitParticipant = z
  .object({
    contact_id: uuid,
    /** EQUAL: same share as the others in the equal group (the owner included when owner_share); FIXED: VND; PERCENT: 0-100. */
    mode: z.enum(["EQUAL", "FIXED", "PERCENT"]),
    value: z.number().min(0).max(1e13).optional(),
  })
  .strict();

/** Create/update a monthly expense rule ("tiền nhà 1.600.000đ, ngày 5-10, chia 3 với Nam và Lan") that MoMa matches and splits automatically. */
const recurringSplitUpsert = command(
  "RECURRING_SPLIT_UPSERT",
  z
    .object({
      name: z.string().min(1).max(120),
      account_id: uuid,
      amount: posMoney,
      category_id: uuid,
      /** First expected payment date (YYYY-MM-DD); normally day window_start of the next month. */
      next_date: localDate,
      enabled: z.boolean(),
      interval: z.enum(["WEEKLY", "MONTHLY", "YEARLY"]).optional(),
      recurring_id: uuid.optional(),
      expected_version: version.optional(),
      /** Days of the month the payment usually happens (5-10). */
      window_start: z.number().int().min(1).max(31),
      window_end: z.number().int().min(1).max(31),
      /** Accepted amount difference in % (default 10). */
      tolerance_pct: z.number().int().min(0).max(50).optional(),
      /** Words seen in the bank content for this payment (landlord's name, "TIEN NHA"...). */
      payee_keywords: z.array(z.string().min(1).max(40)).max(10).optional(),
      /** Others' shares rounded up to this step (default 5000). */
      rounding: z.union([z.literal(0), z.literal(1000), z.literal(5000), z.literal(10000)]).optional(),
      /** The owner is one of the equal shares (default true). */
      owner_share: z.boolean().optional(),
      /** Confident matches are applied without asking (default true); otherwise always a proposal. */
      auto_apply: z.boolean().optional(),
      participants: z.array(splitParticipant).max(20).optional(),
    })
    .strict()
    .refine((p) => p.window_end >= p.window_start, "window_end >= window_start")
    .refine((p) => p.recurring_id === undefined || p.expected_version !== undefined, "expected_version required when updating"),
);

/** Split one expense: each share becomes a debt the person owes the owner (category/occurrence optional). Confirms a proposal when application_id is given. */
const splitApply = command(
  "SPLIT_APPLY",
  z
    .object({
      tx_id: uuid,
      shares: z
        .array(
          z
            .object({ contact_id: uuid.optional(), name: z.string().min(1).max(80).optional(), amount: posMoney })
            .strict()
            .refine((s) => s.contact_id !== undefined || s.name !== undefined, "contact_id or name"),
        )
        .max(20),
      category_id: uuid.optional(),
      merchant: z.string().min(1).max(120).optional(),
      recurring_id: uuid.optional(),
      occurrence_id: uuid.optional(),
      application_id: uuid.optional(),
      source: z.enum(["RECURRING", "BILL", "MANUAL", "AI"]).optional(),
      note: z.string().max(300).optional(),
    })
    .strict(),
);

/** Undo an applied split: its debts are cancelled (reversal journals) and the recurring occurrence is expected again. */
const splitUndo = command("SPLIT_UNDO", z.object({ application_id: uuid }).strict());

/** "Không chia": drop a split proposal; the same rule is not proposed again for that bill. */
const splitDismiss = command("SPLIT_DISMISS", z.object({ application_id: uuid }).strict());

const accountUpdate = command(
  "ACCOUNT_UPDATE",
  z
    .object({
      account_id: uuid,
      expected_version: version,
      name: z.string().min(1).max(120).optional(),
      archived: z.boolean().optional(),
      hidden: z.boolean().optional(),
      /** Bank / wallet name (migration 011). */
      institution: z.string().min(1).max(40).optional(),
      /** Last 4 digits of the account number; "" clears it (migration 011). */
      last4: z.string().regex(/^(?:[0-9]{4})?$/).optional(),
      /** Current balance as reported by the owner or the bank: sets the opening balance or posts an ADJUSTMENT (migration 011). */
      balance: anyMoney.optional(),
      balance_at: iso.optional(),
    })
    .strict()
    .refine((p) => p.balance_at === undefined || p.balance !== undefined, "balance_at needs balance"),
);

const txAnnotate = command(
  "TX_ANNOTATE",
  z
    .object({
      tx_id: uuid,
      expected_version: version,
      note: z.string().max(1000).optional(),
      merchant: z.string().min(1).max(120).optional(),
      contact_id: uuid.optional(),
      category_id: uuid.optional(),
    })
    .strict(),
);

const txCorrect = command(
  "TX_CORRECT",
  z
    .object({
      tx_id: uuid,
      reason: z.string().min(1).max(1000),
      expected_version: version,
      replacement: z
        .object({
          kind: z.enum(["INCOME", "EXPENSE", "TRANSFER", "UNKNOWN_CREDIT", "UNKNOWN_DEBIT"]),
          account_id: uuid,
          amount: posMoney,
          effective_at: iso,
          category_id: uuid.optional(),
          to_account_id: uuid.optional(),
          contact_id: uuid.optional(),
          note: z.string().max(1000).optional(),
          merchant: z.string().min(1).max(120).optional(),
          fee: posMoney.optional(),
        })
        .strict(),
    })
    .strict(),
);

const profileUpdate = command(
  "PROFILE_UPDATE",
  z.object({ expected_version: version, display_name: z.string().min(1).max(80).optional(), wizard_step: z.string().max(8).optional() }).strict(),
);

// Only commands whose RPC exists. Everything else in contracts/commands.schema.json answers NOT_IMPLEMENTED (explicit, never faked).
export const implementedCommand = z.discriminatedUnion("command_type", [
  accountCreate,
  txCreate,
  txReverse,
  contactCreate,
  contactUpdate,
  debtCreate,
  debtRepay,
  debtWriteOff,
  debtUpdate,
  debtPaymentReverse,
  debtCancel,
  goalCreate,
  goalAllocate,
  goalRelease,
  budgetUpsert,
  categoryUpsert,
  recurringUpsert,
  occurrenceMatch,
  recurringSplitUpsert,
  splitApply,
  splitUndo,
  splitDismiss,
  accountUpdate,
  txAnnotate,
  txCorrect,
  profileUpdate,
]);
export type ImplementedCommand = z.infer<typeof implementedCommand>;

export const IMPLEMENTED_TYPES: ReadonlySet<string> = new Set(implementedCommand.options.map((o) => o.shape.command_type.value));

// Full catalogue from spec/contracts/commands.schema.json: known-but-unbuilt types answer 422 NOT_IMPLEMENTED, unknown types 400.
export const KNOWN_TYPES: ReadonlySet<string> = new Set([
  "ACCOUNT_CREATE", "ACCOUNT_UPDATE", "BASELINE_SET", "SOURCE_SET", "SETTINGS_UPDATE", "CONNECTION_CREATE", "CONNECTION_PAUSE", "CONNECTION_VERIFY",
  "TX_CREATE", "TX_ANNOTATE", "TX_CORRECT", "TX_REVERSE", "REVIEW_RESOLVE", "IMPORT_COMMIT", "CONTACT_CREATE", "CONTACT_UPDATE", "DEBT_CREATE",
  "DEBT_REPAY", "DEBT_UPDATE", "DEBT_WRITE_OFF", "DEBT_PAYMENT_REVERSE", "DEBT_CANCEL", "GOAL_CREATE", "GOAL_ALLOCATE", "GOAL_RELEASE", "GOAL_UPDATE", "BUDGET_UPSERT", "CATEGORY_UPSERT",
  "RULE_UPSERT", "RECURRING_UPSERT", "OCCURRENCE_MATCH", "DEVICE_REVOKE", "DEVICE_SOURCE_SET", "AI_ACCEPT", "AI_DISMISS", "REMINDER_UPSERT",
  "PROFILE_UPDATE", "TAG_UPSERT", "TX_TAG_SET", "ADJUSTMENT_CREATE", "SPLIT_BILL_CREATE",
  "RECURRING_SPLIT_UPSERT", "SPLIT_APPLY", "SPLIT_UNDO", "SPLIT_DISMISS",
]);
