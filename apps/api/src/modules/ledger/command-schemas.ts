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

const accountUpdate = command(
  "ACCOUNT_UPDATE",
  z.object({ account_id: uuid, expected_version: version, name: z.string().min(1).max(120).optional(), archived: z.boolean().optional(), hidden: z.boolean().optional() }).strict(),
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
  goalCreate,
  goalAllocate,
  goalRelease,
  budgetUpsert,
  categoryUpsert,
  recurringUpsert,
  occurrenceMatch,
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
  "DEBT_REPAY", "DEBT_UPDATE", "DEBT_WRITE_OFF", "GOAL_CREATE", "GOAL_ALLOCATE", "GOAL_RELEASE", "GOAL_UPDATE", "BUDGET_UPSERT", "CATEGORY_UPSERT",
  "RULE_UPSERT", "RECURRING_UPSERT", "OCCURRENCE_MATCH", "DEVICE_REVOKE", "DEVICE_SOURCE_SET", "AI_ACCEPT", "AI_DISMISS", "REMINDER_UPSERT",
  "PROFILE_UPDATE", "TAG_UPSERT", "TX_TAG_SET", "ADJUSTMENT_CREATE", "SPLIT_BILL_CREATE",
]);
