import { z } from "zod";
import { IMPLEMENTED_TYPES, implementedCommand } from "../ledger/command-schemas";

// The assistant's tool catalogue: every implemented ledger command is a tool. Payload hints are generated from the
// zod schemas, so a new command is reachable by the agent as soon as it has a tier + description here (a unit test
// fails otherwise). Tiers: "low" runs by itself (with Hoàn tác), "high" needs one tap on a confirmation card.

export type Tier = "low" | "high";

export interface ToolSpec {
  tier: Tier;
  /** Short Vietnamese description used in the system prompt. */
  vi: string;
}

export const COMMAND_TOOLS: Record<string, ToolSpec> = {
  ACCOUNT_CREATE: { tier: "high", vi: "thêm tài khoản/ví (số dư hiện tại = opening_amount + baseline_at)" },
  ACCOUNT_UPDATE: { tier: "high", vi: "sửa tài khoản: tên, ngân hàng, 4 số cuối, ẩn/lưu trữ, đặt số dư hiện tại" },
  TX_CREATE: { tier: "low", vi: "ghi giao dịch thu/chi/chuyển khoản" },
  TX_ANNOTATE: { tier: "low", vi: "điền/sửa danh mục, ghi chú, nơi chi, người liên quan của một giao dịch (không đổi số tiền)" },
  TX_CORRECT: { tier: "high", vi: "sửa số tiền/ngày/tài khoản/loại của giao dịch (thay bằng bản mới, giữ lịch sử)" },
  TX_REVERSE: { tier: "high", vi: "hủy giao dịch (đảo bút toán, giữ lịch sử)" },
  CONTACT_CREATE: { tier: "low", vi: "thêm người quen" },
  CONTACT_UPDATE: { tier: "low", vi: "đổi tên/ghi chú/lưu trữ người quen" },
  DEBT_CREATE: { tier: "low", vi: "ghi cho vay (RECEIVABLE) hoặc đi vay (PAYABLE); historical=true nếu khoản cũ không phát sinh tiền" },
  DEBT_REPAY: { tier: "low", vi: "thu nợ hoặc trả nợ một phần/toàn bộ" },
  DEBT_WRITE_OFF: { tier: "high", vi: "xóa nợ khó đòi (ghi nhận mất)" },
  DEBT_UPDATE: { tier: "low", vi: "sửa khoản nợ: người, hạn trả, ghi chú, số gốc khi chưa trả lần nào" },
  DEBT_PAYMENT_REVERSE: { tier: "high", vi: "hoàn tác một lần thu/trả nợ" },
  DEBT_CANCEL: { tier: "high", vi: "xóa khoản nợ nhập nhầm (đảo toàn bộ bút toán)" },
  GOAL_CREATE: { tier: "low", vi: "tạo mục tiêu tiết kiệm" },
  GOAL_ALLOCATE: { tier: "low", vi: "dành tiền cho mục tiêu" },
  GOAL_RELEASE: { tier: "low", vi: "rút tiền đã dành khỏi mục tiêu" },
  BUDGET_UPSERT: { tier: "low", vi: "đặt/sửa ngân sách tháng (tổng hoặc theo danh mục)" },
  CATEGORY_UPSERT: { tier: "low", vi: "thêm/sửa/lưu trữ danh mục" },
  RECURRING_UPSERT: { tier: "low", vi: "thêm/sửa/tắt khoản định kỳ" },
  OCCURRENCE_MATCH: { tier: "low", vi: "xác nhận một kỳ định kỳ đã trả bằng giao dịch có sẵn" },
  PROFILE_UPDATE: { tier: "low", vi: "đổi tên hiển thị" },
  RECURRING_SPLIT_UPSERT: { tier: "low", vi: "tạo/sửa quy tắc khoản định kỳ tự ghi và tự chia tiền (tiền nhà, điện... chia cho người ở chung)" },
  SPLIT_APPLY: { tier: "low", vi: "chia một khoản chi đã ghi: phần của mỗi người thành khoản họ nợ bạn (contact_id hoặc name)" },
  SPLIT_UNDO: { tier: "high", vi: "hủy một lần chia tiền (xóa các khoản nợ của lần chia đó)" },
  SPLIT_DISMISS: { tier: "low", vi: "bỏ qua một đề xuất chia tiền" },
};

/** Above this amount (VND) any money-moving step needs one tap, whatever its tier. */
export const HIGH_AMOUNT = 20_000_000;
/** More executable steps than this in one plan = bulk change: every step needs confirmation. */
export const BULK_STEPS = 6;

type AnyZod = z.ZodTypeAny;

function unwrap(t: AnyZod): AnyZod {
  let cur: AnyZod = t;
  for (let i = 0; i < 10; i++) {
    const def = (cur as any)._def;
    if (def?.schema) cur = def.schema; // ZodEffects (refine / superRefine / transform)
    else if (def?.innerType) cur = def.innerType; // optional / nullable / default
    else break;
  }
  return cur;
}

function describe(t: AnyZod): string {
  const u = unwrap(t);
  const name = (u as any)._def?.typeName as string | undefined;
  switch (name) {
    case "ZodEnum":
      return (u as z.ZodEnum<[string, ...string[]]>).options.join("|");
    case "ZodBoolean":
      return "bool";
    case "ZodNumber":
      return "số";
    case "ZodObject":
      return `{${objectHint(u as z.ZodObject<any>)}}`;
    case "ZodString": {
      const checks = ((u as any)._def.checks ?? []) as { kind: string; regex?: RegExp }[];
      if (checks.some((c) => c.kind === "uuid")) return "id";
      if (checks.some((c) => c.kind === "datetime")) return "ISO";
      const re = checks.find((c) => c.kind === "regex")?.regex?.source ?? "";
      if (re.includes("[1-9][0-9]{0,15}")) return "VND";
      if (re.startsWith("^\\d{4}-(0[1-9]|1[0-2])-")) return "YYYY-MM-DD";
      if (re.startsWith("^\\d{4}-(0[1-9]|1[0-2])$")) return "YYYY-MM";
      return "chữ";
    }
    default:
      return "?";
  }
}

function objectHint(o: z.ZodObject<any>): string {
  return Object.entries(o.shape as Record<string, AnyZod>)
    .map(([k, v]) => `${k}${v.isOptional() ? "?" : ""}:${describe(v)}`)
    .join(",");
}

/** Compact payload hint of one command, e.g. `tx_id:id,reason:chữ,expected_version:số`. */
export function payloadHint(type: string): string {
  const opt = implementedCommand.options.find((o) => o.shape.command_type.value === type);
  if (!opt) return "";
  return objectHint(unwrap(opt.shape.payload) as z.ZodObject<any>);
}

/** One line per tool for the system prompt (generated, so it never drifts from the schemas). */
export function toolCatalogText(): string {
  return [...IMPLEMENTED_TYPES]
    .sort()
    .map((t) => `- ${t} [${COMMAND_TOOLS[t]?.tier === "low" ? "tự chạy" : "cần xác nhận"}] ${COMMAND_TOOLS[t]?.vi ?? ""}: {${payloadHint(t)}}`)
    .join("\n");
}

const MONEY_KEYS = ["amount", "principal", "limit", "target", "opening_amount", "balance"];

/** Risk of one concrete command: the tool tier, raised for destructive variants and large amounts. */
export function riskOf(type: string, payload: Record<string, unknown>): Tier {
  const spec = COMMAND_TOOLS[type];
  if (!spec) return "high";
  if (payload.archived === true || payload.hidden === true) return "high";
  if (type === "DEBT_UPDATE" && payload.principal !== undefined) return "high";
  const money = [...MONEY_KEYS.map((k) => payload[k]), (payload.replacement as Record<string, unknown> | undefined)?.amount];
  if (money.some((v) => typeof v === "string" && /^-?\d+$/.test(v) && Math.abs(Number(v)) > HIGH_AMOUNT)) return "high";
  return spec.tier;
}

// ---------------------------------------------------------------- undo
/**
 * How to take back an executed step. `$result.<field>` tokens are filled by the app from the command result.
 * The server resolves current versions at undo time (POST /v1/ai/undo), so a stale version never blocks Hoàn tác.
 */
export type UndoOp =
  | { op: "REVERSE_TX"; tx_id: string }
  | { op: "CANCEL_DEBT"; debt_id: string }
  | { op: "REVERSE_DEBT_PAYMENT"; debt_id: string; tx_id: string }
  | { op: "GOAL_MOVE"; command_type: "GOAL_ALLOCATE" | "GOAL_RELEASE"; goal_id: string; account_id: string; amount: string }
  | { op: "ARCHIVE_CONTACT"; contact_id: string }
  | { op: "ARCHIVE_CATEGORY"; category_id: string }
  | { op: "DISABLE_RECURRING"; recurring_id: string }
  | { op: "ARCHIVE_ACCOUNT"; account_id: string }
  | { op: "RESTORE_TX"; tx_id: string; fields: Record<string, string> }
  | { op: "CORRECT_TX"; tx_id: string; replacement: Record<string, string> }
  | { op: "SPLIT_UNDO"; application_id: string }
  | { op: "RESTORE_BUDGET"; month: string; category_id?: string | undefined; limit: string; carryover: boolean };

export interface UndoSpec {
  ops: UndoOp[];
  /** Memory key weakened when the owner undoes (habit learning). */
  habit?: { kind: "HABIT" | "PREFERENCE"; key: string } | undefined;
}

export interface UndoContext {
  /** Current values of a transaction before TX_ANNOTATE (to restore). */
  txBefore?: (id: string) => { category_id?: string | null; note?: string | null; merchant?: string | null; contact_id?: string | null } | undefined;
  /** Existing budget for month/category before BUDGET_UPSERT. */
  budgetBefore?: (month: string, categoryId?: string) => { limit: string; carryover: boolean } | undefined;
}

export function undoFor(type: string, p: Record<string, any>, ctx: UndoContext = {}): UndoOp[] | undefined {
  switch (type) {
    case "TX_CREATE":
      return [{ op: "REVERSE_TX", tx_id: "$result.tx_id" }];
    case "TX_CORRECT":
      // The replacement is reversed; the old row stays VOID (history), so Hoàn tác = "không ghi gì cả".
      return [{ op: "REVERSE_TX", tx_id: "$result.tx_id" }];
    case "DEBT_CREATE":
      return [{ op: "CANCEL_DEBT", debt_id: "$result.debt_id" }];
    case "DEBT_REPAY":
    case "DEBT_WRITE_OFF":
      return [{ op: "REVERSE_DEBT_PAYMENT", debt_id: String(p.debt_id), tx_id: "$result.tx_id" }];
    case "GOAL_ALLOCATE":
    case "GOAL_RELEASE":
      return [{ op: "GOAL_MOVE", command_type: type === "GOAL_ALLOCATE" ? "GOAL_RELEASE" : "GOAL_ALLOCATE", goal_id: String(p.goal_id), account_id: String(p.account_id), amount: String(p.amount) }];
    case "CONTACT_CREATE":
      return [{ op: "ARCHIVE_CONTACT", contact_id: "$result.contact_id" }];
    case "CATEGORY_UPSERT":
      return p.category_id ? undefined : [{ op: "ARCHIVE_CATEGORY", category_id: "$result.category_id" }];
    case "RECURRING_UPSERT":
    case "RECURRING_SPLIT_UPSERT":
      return p.recurring_id ? undefined : [{ op: "DISABLE_RECURRING", recurring_id: "$result.recurring_id" }];
    case "SPLIT_APPLY":
      return [{ op: "SPLIT_UNDO", application_id: "$result.application_id" }];
    case "ACCOUNT_CREATE":
      return [{ op: "ARCHIVE_ACCOUNT", account_id: "$result.account_id" }];
    case "TX_ANNOTATE": {
      const before = ctx.txBefore?.(String(p.tx_id));
      if (!before) return undefined;
      const fields: Record<string, string> = {};
      for (const k of ["category_id", "note", "merchant", "contact_id"] as const) {
        if (p[k] === undefined) continue;
        const v = before[k];
        if (typeof v === "string" && v) fields[k] = v;
      }
      return Object.keys(fields).length ? [{ op: "RESTORE_TX", tx_id: String(p.tx_id), fields }] : undefined;
    }
    case "BUDGET_UPSERT": {
      const before = ctx.budgetBefore?.(String(p.month), p.category_id);
      return before ? [{ op: "RESTORE_BUDGET", month: String(p.month), ...(p.category_id ? { category_id: String(p.category_id) } : {}), limit: before.limit, carryover: before.carryover }] : undefined;
    }
    default:
      return undefined;
  }
}

export const UndoRequest = z.object({
  /** Command id of the step being undone: the undo commands derive their ids from it, so a double tap replays. */
  step_command_id: z.string().uuid(),
  ops: z
    .array(
      z.discriminatedUnion("op", [
        z.object({ op: z.literal("REVERSE_TX"), tx_id: z.string().uuid() }),
        z.object({ op: z.literal("CANCEL_DEBT"), debt_id: z.string().uuid() }),
        z.object({ op: z.literal("REVERSE_DEBT_PAYMENT"), debt_id: z.string().uuid(), tx_id: z.string().uuid() }),
        z.object({ op: z.literal("GOAL_MOVE"), command_type: z.enum(["GOAL_ALLOCATE", "GOAL_RELEASE"]), goal_id: z.string().uuid(), account_id: z.string().uuid(), amount: z.string().regex(/^[1-9][0-9]{0,15}$/) }),
        z.object({ op: z.literal("ARCHIVE_CONTACT"), contact_id: z.string().uuid() }),
        z.object({ op: z.literal("ARCHIVE_CATEGORY"), category_id: z.string().uuid() }),
        z.object({ op: z.literal("DISABLE_RECURRING"), recurring_id: z.string().uuid() }),
        z.object({ op: z.literal("ARCHIVE_ACCOUNT"), account_id: z.string().uuid() }),
        z.object({ op: z.literal("RESTORE_TX"), tx_id: z.string().uuid(), fields: z.record(z.string().max(1000)) }),
        z.object({ op: z.literal("CORRECT_TX"), tx_id: z.string().uuid(), replacement: z.record(z.string().max(1000)) }),
        z.object({ op: z.literal("SPLIT_UNDO"), application_id: z.string().uuid() }),
        z.object({ op: z.literal("RESTORE_BUDGET"), month: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/), category_id: z.string().uuid().optional(), limit: z.string().regex(/^[1-9][0-9]{0,15}$/), carryover: z.boolean() }),
      ]),
    )
    .min(1)
    .max(10),
  habit: z.object({ kind: z.enum(["HABIT", "PREFERENCE"]), key: z.string().min(1).max(80) }).optional(),
});
