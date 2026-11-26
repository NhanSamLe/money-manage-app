import { z } from "zod";

const uuid = z.string().uuid();
const posMoney = z.string().regex(/^[1-9][0-9]{0,15}$/);
const anyMoney = z.string().regex(/^(?:0|-?[1-9][0-9]{0,15})$/);
const iso = z.string().datetime({ offset: true });
const base = { command_id: uuid, schema_version: z.literal(1) };

const accountCreate = z
  .object({
    ...base,
    command_type: z.literal("ACCOUNT_CREATE"),
    payload: z
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
  })
  .strict();

const txCreate = z
  .object({
    ...base,
    command_type: z.literal("TX_CREATE"),
    payload: z
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
      .strict()
      .superRefine((p, ctx) => {
        if ((p.kind === "INCOME" || p.kind === "EXPENSE") && !p.category_id) ctx.addIssue({ code: "custom", message: "category_id required" });
        if (p.kind === "TRANSFER" && !p.to_account_id) ctx.addIssue({ code: "custom", message: "to_account_id required" });
      }),
  })
  .strict();

const txReverse = z
  .object({
    ...base,
    command_type: z.literal("TX_REVERSE"),
    payload: z
      .object({ tx_id: uuid, reason: z.string().min(1).max(1000), expected_version: z.number().int().min(1).max(2147483647) })
      .strict(),
  })
  .strict();

// Only commands whose RPC exists. Everything else in contracts/commands.schema.json answers NOT_IMPLEMENTED (explicit, never faked).
export const implementedCommand = z.discriminatedUnion("command_type", [accountCreate, txCreate, txReverse]);
export type ImplementedCommand = z.infer<typeof implementedCommand>;
