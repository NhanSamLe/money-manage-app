import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import {
  actualMicro,
  buildRequestBody,
  estimateMicro,
  MODEL,
  MONTHLY_CAP_MICRO,
  parseModelJson,
  type ProviderCall,
} from "../modules/ai/assistant";
import type { FinanceGateway } from "../modules/ledger/ports";
import { classifyInput, loadContext } from "./routes-classify";
import { sendPush } from "../modules/push/onesignal";
import { SupabaseSplitGateway, type ApplyShare, type SplitGateway } from "../modules/split/gateway";
import {
  appliedPush,
  computeShares,
  fold,
  matchContact,
  matchRule,
  missedPush,
  proposedPush,
  ROUNDINGS,
  sharesForRule,
  type ContactRef,
  type SplitContext,
} from "../modules/split/split";
import { DomainError } from "../shared/errors";

// Recurring payments with bill splitting (migration 016, D-022): HTTP routes, the best-effort hook run after every new
// money-out (bank event, notification, manual entry), and the cron sweep (re-check recent payments + "chưa thấy"
// reminders). Shared entry points for the assistant: POST /v1/splits/propose and /v1/splits/apply (same math:
// modules/split/split.ts computeShares). Hooks never fail the operation that triggered them.

export interface SplitDeps {
  cfg: Config;
  gw: FinanceGateway;
  ai?: ProviderCall;
  pushFetch?: typeof fetch;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  sg?: SplitGateway;
}

export const sgOf = (d: SplitDeps): SplitGateway => d.sg ?? new SupabaseSplitGateway(d.cfg);

/** Hours of recent money-out the cron re-checks. */
export const SPLIT_SWEEP_HOURS = 72;
const SWEEP_MAX = 40;

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}
const ownerOf = (c: Context<any>): string => (c as any).get("owner");
const UUID = z.string().uuid();

function parseOr<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}

function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "split", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

/** Today's date in Vietnam (YYYY-MM-DD). */
export function vnToday(now: Date = new Date()): string {
  return new Date(now.getTime() + 7 * 3_600_000).toISOString().slice(0, 10);
}

async function push(d: SplitDeps, owner: string, title: string, body: string, route: string, type = "split") {
  await sendPush(d.cfg, d.pushFetch ?? fetch, { ownerId: owner, title, body, data: { type, route }, androidGroup: "moma_split" }).catch(() => false);
}

export type SplitOutcome = "NONE" | "APPLIED" | "PROPOSED";

/**
 * Checks one new money-out against the owner's recurring rules. Confident match on an auto rule: category + occurrence +
 * debts at once, push "Đã ghi tiền nhà 1.600.000đ · Nam nợ 535.000đ…" (undo from the transaction). Weaker match:
 * stored as a proposal, push "Có phải tiền nhà?". Never throws.
 */
export async function splitAfterTx(d: SplitDeps, owner: string, txId: string | undefined, step: string, opts: { notify?: boolean } = {}): Promise<SplitOutcome> {
  if (!txId) return "NONE";
  const notify = opts.notify ?? true;
  try {
    const sg = sgOf(d);
    let ctx = await sg.context(owner, txId);
    if (!ctx) return "NONE";
    if (!ctx.rules.some((r) => r.occurrences.length)) {
      // Occurrences are generated lazily: make sure this month's exist before deciding.
      await sg.syncOccurrences(owner, vnToday());
      ctx = (await sg.context(owner, txId)) ?? ctx;
    }
    const m = matchRule(ctx);
    if (!m) return "NONE";
    const total = Number(ctx.tx.amount);
    const split = sharesForRule(m.rule, total);
    const shares = split.shares.filter((s) => s.amount > 0);
    if (m.decision === "AUTO") {
      const res = await sg.apply(owner, {
        tx_id: txId,
        shares: shares.map((s) => ({ contact_id: s.contact_id, name: s.name, amount: String(s.amount) })),
        category_id: m.rule.category_id,
        merchant: m.rule.name,
        recurring_id: m.rule.id,
        occurrence_id: m.occurrence.id,
        source: "RECURRING",
        confidence: m.score,
        note: m.rule.name,
        hints: m.hints,
      });
      // A plain match (no one owes anything) is already announced by the bank / notification push itself.
      if (notify && res.shares.length) {
        const p = appliedPush(m.rule.name, total, res.shares.map((s) => ({ name: s.name, amount: s.amount })));
        await push(d, owner, p.title, p.body, `/tx/${txId}`);
      }
      return "APPLIED";
    }
    const r = await sg.propose(owner, {
      tx_id: txId,
      shares: shares.map((s) => ({ contact_id: s.contact_id, name: s.name, amount: String(s.amount) })),
      owner_amount: String(split.owner_amount),
      category_id: m.rule.category_id,
      recurring_id: m.rule.id,
      occurrence_id: m.occurrence.id,
      source: "RECURRING",
      confidence: m.score,
      note: m.rule.name,
      hints: m.hints,
    });
    if (r.status !== "PROPOSED") return "NONE";
    // Push only when other people's money is at stake; a plain "is this Netflix?" waits quietly in the bell.
    if (notify && shares.length) {
      const p = proposedPush(m.rule.name, total, shares);
      await push(d, owner, p.title, p.body, `/tx/${txId}`);
    }
    return "PROPOSED";
  } catch (e) {
    logFailure(step, e);
    return "NONE";
  }
}

/** /v1/commands hook: any newly created money-out (manual, notification, assistant). */
export function splitCandidate(command: { command_type: string; payload: unknown }, result: Record<string, unknown> | null | undefined): string | undefined {
  if (command.command_type !== "TX_CREATE" || result?.status !== "COMMITTED") return undefined;
  const p = command.payload as Record<string, unknown> | null;
  if (!p || !["EXPENSE", "UNKNOWN_DEBIT"].includes(String(p.kind))) return undefined;
  return typeof result.tx_id === "string" ? result.tx_id : undefined;
}

export async function splitAfterCommand(d: SplitDeps, owner: string, command: { command_type: string; payload: unknown }, result: Record<string, unknown>): Promise<void> {
  const txId = splitCandidate(command, result);
  if (txId) await splitAfterTx(d, owner, txId, "command");
}

/** Cron: generate occurrences, re-check recent money-out, remind rules whose window passed unpaid. Never throws. */
export async function runSplitSweep(d: SplitDeps, now: Date = new Date()): Promise<{ checked: number; applied: number; proposed: number; reminded: number } | null> {
  try {
    const owner = await d.gw.getOwnerId();
    if (!owner) return null;
    const sg = sgOf(d);
    const today = vnToday(now);
    await sg.syncOccurrences(owner, today);
    const out = { checked: 0, applied: 0, proposed: 0, reminded: 0 };
    for (const txId of (await sg.recentDebits(owner, SPLIT_SWEEP_HOURS)).slice(-SWEEP_MAX)) {
      out.checked++;
      const r = await splitAfterTx(d, owner, txId, "sweep");
      if (r === "APPLIED") out.applied++;
      if (r === "PROPOSED") out.proposed++;
    }
    for (const m of await sg.missed(owner, today)) {
      try {
        if (!(await sg.pushClaim(owner, `split-missed:${m.occurrence_id}`))) continue;
        const p = missedPush(m.name, m.due_date, m.window_start, m.window_end);
        await push(d, owner, p.title, p.body, "/planning?tab=3", "split_missed");
        out.reminded++;
      } catch (e) {
        logFailure("missed", e);
      }
    }
    return out;
  } catch (e) {
    logFailure("sweep", e);
    return null;
  }
}

// ---------------------------------------------------------------- bill photo (text read on the phone)

export interface BillReading {
  total: number | null;
  period: string | null;
  merchant: string | null;
  /** One of the owner's expense category names, or null. */
  category: string | null;
  people: { name: string; amount: number | null }[];
  /** Short item summary for the note, e.g. "Lẩu, 6 bia". */
  items: string | null;
  /** Looks shared by several people (many portions, a group table, names listed). */
  group: boolean;
  /** 0..1, how sure the reading of category/merchant is. */
  confidence: number;
}

/** Bill analysis decisions: apply in place / ask with one tap / nothing. */
export const BILL_APPLY = 0.75;
export const BILL_SUGGEST = 0.45;

const BILL_MAX_OUTPUT_TOKENS = 400;

/** Keyword fallback when AI is off or fails: total after "tổng / thanh toán", category from bill words. */
export function readBillByRules(text: string, categories: string[]): BillReading {
  const f = fold(text);
  let total: number | null = null;
  const re = /(tong cong|tong tien|tong thanh toan|thanh toan|so tien|total)[^0-9]{0,20}([0-9][0-9., ]{2,15})/g;
  for (const m of f.matchAll(re)) {
    const n = Number(m[2]!.replace(/[^0-9]/g, ""));
    if (n >= 1000 && (total === null || n > total)) total = n;
  }
  const pick = (...words: string[]) => categories.find((c) => words.some((w) => fold(c).includes(w))) ?? null;
  let category: string | null = null;
  if (/\b(evn|dien luc|tien dien|kwh)\b/.test(f)) category = pick("dien", "hoa don");
  else if (/\b(cap nuoc|tien nuoc|m3)\b/.test(f)) category = pick("nuoc", "hoa don");
  else if (/\b(internet|fpt|vnpt|viettel|cap quang)\b/.test(f)) category = pick("internet", "vien thong", "hoa don");
  else if (/\b(tien nha|tien phong|thue nha)\b/.test(f)) category = pick("nha", "thue");
  return { total, period: null, merchant: null, category, people: [], items: null, group: false, confidence: category ? 0.6 : 0 };
}

export function parseBillJson(raw: unknown): BillReading | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.round(v) : typeof v === "string" && /\d/.test(v) ? Number(v.replace(/[^0-9]/g, "")) || null : null);
  const str = (v: unknown, n: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, n) : null);
  const people = Array.isArray(o.people)
    ? o.people
        .map((p) => (p && typeof p === "object" ? { name: str((p as any).name, 80) ?? "", amount: num((p as any).amount) } : null))
        .filter((p): p is { name: string; amount: number | null } => !!p && p.name.length > 0)
        .slice(0, 20)
    : [];
  const conf = typeof o.confidence === "number" && Number.isFinite(o.confidence) ? Math.min(1, Math.max(0, o.confidence)) : 0.5;
  return {
    total: num(o.total),
    period: str(o.period, 40),
    merchant: str(o.merchant, 120),
    category: str(o.category, 80),
    people,
    items: str(o.items, 80),
    group: o.group === true || people.length > 0,
    confidence: conf,
  };
}

async function readBill(d: SplitDeps, owner: string, text: string, categories: string[], contacts: string[]): Promise<BillReading> {
  const fallback = readBillByRules(text, categories);
  if (!d.ai) return fallback;
  const clipped = text.slice(0, 4000);
  const messages = [
    {
      role: "system",
      content:
        "Bạn đọc hóa đơn / ảnh chụp chuyển khoản tiếng Việt từ chữ nhận dạng (OCR, có thể lỗi). Chỉ trả về JSON: " +
        '{"total": số tiền VND phải trả (số nguyên) hoặc null, "period": kỳ (vd "11/2026") hoặc null, "merchant": tên quán / bên thu tiền ngắn gọn hoặc null, ' +
        '"category": đúng MỘT tên trong danh sách danh mục hoặc null, "items": tóm tắt món/dịch vụ rất ngắn (vd "Lẩu, 6 bia", "Điện T11 245 kWh") hoặc null, ' +
        '"group": true nếu là hóa đơn ăn chung / nhiều phần cho nhiều người hoặc có ghi tên người chia, ngược lại false, ' +
        '"confidence": 0..1 mức chắc chắn về category và merchant, ' +
        '"people": [{"name": tên người được chia, "amount": số tiền của người đó hoặc null}]}. ' +
        "Chỉ đưa người vào people khi hóa đơn/ghi chú thật sự ghi tên người chia tiền; không bịa.",
    },
    { role: "user", content: `Danh mục chi: ${categories.join(", ")}\nNgười quen: ${contacts.slice(0, 50).join(", ")}\n\nVăn bản:\n${clipped}` },
  ];
  try {
    const bytes = JSON.stringify(messages).length;
    const { id: reservation } = await d.gw.aiReserve(owner, estimateMicro(bytes, BILL_MAX_OUTPUT_TOKENS), MONTHLY_CAP_MICRO, "deepseek", MODEL, "bill");
    let out;
    try {
      out = await d.ai({ ...buildRequestBody(messages, BILL_MAX_OUTPUT_TOKENS), temperature: 0.1 });
    } catch {
      await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined);
      return fallback;
    }
    await d.gw.aiSettle(owner, reservation, actualMicro(out.usage)).catch(() => undefined);
    const r = parseBillJson(parseModelJson(out.content));
    if (!r) return fallback;
    const known = r.category && categories.includes(r.category);
    return {
      ...r,
      total: r.total ?? fallback.total,
      category: known ? r.category : fallback.category,
      confidence: known ? r.confidence : Math.min(r.confidence, fallback.confidence),
    };
  } catch (e) {
    logFailure("bill.ai", e);
    return fallback;
  }
}

export interface BillAnalysis {
  reading: BillReading;
  /** Applied in place (confident). `previous` lets the app undo. */
  updated: { category_id: string | null; merchant: string | null; note: string | null; previous: { kind: string; category_id: string | null; merchant: string | null; note: string | null } } | null;
  /** Not sure enough: the app shows a one-tap confirm card. */
  suggestion: { category_id: string | null; merchant: string | null; note: string | null; confidence: number } | null;
  /** The bill's total differs from the recorded amount (the app offers a one-tap fix; money is never changed here). */
  amount_mismatch: { bill_total: string; tx_amount: string } | null;
  split: SplitOutcome;
  splits: Record<string, unknown>[];
}

/** Whether a note is the bank's raw content (fine to replace by the item summary) rather than the owner's own words. */
function noteReplaceable(tx: SplitContext["tx"]): boolean {
  return !tx.note?.trim() || tx.source === "BANK" || tx.source === "NOTIFICATION";
}

export async function analyzeBill(d: SplitDeps, owner: string, txId: string, text: string): Promise<BillAnalysis> {
  const sg = sgOf(d);
  const ctx = await sg.context(owner, txId);
  if (!ctx) throw new DomainError("NOT_FOUND");
  if (ctx.tx.status !== "POSTED") throw new DomainError("INVALID_STATE");
  const [cats, contacts] = await Promise.all([expenseCategories(d, owner), contactsOf(d, owner)]);
  const reading = await readBill(d, owner, text, cats.map((x) => x.name), contacts.map((x) => x.alias));
  const tx = ctx.tx;
  const moneyOut = ["EXPENSE", "UNKNOWN_DEBIT"].includes(tx.kind);
  let categoryId = moneyOut && reading.category ? cats.find((x) => x.name === reading.category)?.id ?? null : null;
  if (moneyOut && !categoryId) {
    // The bill named no known category: the shared classifier (learned rules, history, dictionary; no second AI
    // call) looks at the merchant / items.
    try {
      const input = { text: [reading.merchant, reading.items, text.slice(0, 300)].filter(Boolean).join(" "), direction: "out" as const, amount: Number(ctx.tx.amount), merchant: reading.merchant };
      const r = await classifyInput(d, owner, input, await loadContext(d, owner), false);
      if (r?.categoryId && r.confidence >= 0.6 && cats.some((x) => x.id === r.categoryId)) {
        categoryId = r.categoryId;
        reading.category = cats.find((x) => x.id === r.categoryId)!.name;
        reading.confidence = Math.max(reading.confidence, r.confidence);
      }
    } catch (e) {
      logFailure("bill.classify", e);
    }
  }
  const splitApplied = ctx.live?.state === "APPLIED";
  const change = {
    // A split bill keeps its category (its debts were taken out of it).
    category_id: !splitApplied && categoryId && (categoryId !== tx.category_id || tx.kind === "UNKNOWN_DEBIT") ? categoryId : null,
    merchant: reading.merchant && !tx.merchant?.trim() ? reading.merchant : null,
    note: reading.items && noteReplaceable(tx) && reading.items !== tx.note ? reading.items : null,
  };
  const out: BillAnalysis = { reading, updated: null, suggestion: null, amount_mismatch: null, split: "NONE", splits: [] };
  if (change.category_id || change.merchant || change.note) {
    if (reading.confidence >= BILL_APPLY) {
      try {
        const r = await sg.billAnnotate(owner, txId, change);
        out.updated = { ...change, previous: r.previous };
      } catch (e) {
        logFailure("bill.annotate", e);
        out.suggestion = { ...change, confidence: reading.confidence };
      }
    } else if (reading.confidence >= BILL_SUGGEST) {
      out.suggestion = { ...change, confidence: reading.confidence };
    }
  }
  const amount = Number(tx.amount);
  if (reading.total && Math.abs(reading.total - amount) > Math.max(1000, amount * 0.01)) {
    out.amount_mismatch = { bill_total: String(reading.total), tx_amount: String(amount) };
  }
  if (moneyOut && ctx.live?.state !== "APPLIED") {
    out.split = await splitAfterTx(d, owner, txId, "bill", { notify: false });
    if (out.split === "NONE" && reading.group) {
      // A group bill: propose the people named on it, or an empty proposal the app fills ("Nhóm hay đi", "Chọn người").
      let shares: { contact_id: string | null; name: string; amount: number }[] = [];
      const named = reading.people.filter((p) => p.name);
      if (named.length) {
        shares = named.every((p) => p.amount && p.amount > 0)
          ? named.map((p) => {
              const m = matchContact(p.name, contacts);
              return { contact_id: m?.id ?? null, name: m?.alias ?? p.name, amount: p.amount! };
            })
          : resolveShares(amount, named.map((p) => ({ name: p.name })), contacts, { ownerShare: true, rounding: 5000 }).shares;
        if (shares.reduce((a, s) => a + s.amount, 0) > amount) shares = [];
      }
      try {
        const r = await sg.propose(owner, {
          tx_id: txId,
          shares: shares.map((s) => ({ contact_id: s.contact_id, name: s.name, amount: String(s.amount) })),
          owner_amount: String(amount - shares.reduce((a, s) => a + s.amount, 0)),
          category_id: categoryId,
          source: "BILL",
          confidence: shares.length ? 0.6 : 0.4,
          note: reading.items ?? reading.merchant ?? null,
          hints: [reading.period ? `Kỳ ${reading.period}` : ""].filter(Boolean),
        });
        if (r.status === "PROPOSED") out.split = "PROPOSED";
      } catch (e) {
        logFailure("bill.propose", e);
      }
    }
  }
  out.splits = await sg.list(owner, txId, null).catch(() => []);
  return out;
}

// ---------------------------------------------------------------- routes

const participantSchema = z
  .object({
    contact_id: UUID.nullish(),
    name: z.string().trim().min(1).max(80).nullish(),
    mode: z.enum(["EQUAL", "FIXED", "PERCENT"]).optional(),
    value: z.number().min(0).max(1e13).nullish(),
  })
  .strict()
  .refine((p) => p.contact_id || p.name, "contact_id or name");

const shareSchema = z
  .object({ contact_id: UUID.nullish(), name: z.string().trim().min(1).max(80).nullish(), amount: z.union([z.string().regex(/^[0-9]{1,16}$/), z.number().int().positive()]) })
  .strict()
  .refine((p) => p.contact_id || p.name, "contact_id or name");

const roundingSchema = z.number().int().refine((v) => (ROUNDINGS as readonly number[]).includes(v), "rounding");

const proposeSchema = z
  .object({
    tx_id: UUID,
    participants: z.array(participantSchema).max(20).optional(),
    owner_share: z.boolean().optional(),
    rounding: roundingSchema.optional(),
    category_id: UUID.nullish(),
    source: z.enum(["BILL", "MANUAL", "AI"]).optional(),
    confidence: z.number().min(0).max(1).optional(),
    note: z.string().max(300).nullish(),
    hints: z.array(z.string().max(80)).max(10).optional(),
  })
  .strict();

const applySchema = z
  .object({
    tx_id: UUID,
    application_id: UUID.nullish(),
    shares: z.array(shareSchema).max(20).optional(),
    participants: z.array(participantSchema).max(20).optional(),
    owner_share: z.boolean().optional(),
    rounding: roundingSchema.optional(),
    category_id: UUID.nullish(),
    merchant: z.string().trim().max(120).nullish(),
    recurring_id: UUID.nullish(),
    occurrence_id: UUID.nullish(),
    source: z.enum(["RECURRING", "BILL", "MANUAL", "AI"]).optional(),
    note: z.string().max(300).nullish(),
  })
  .strict()
  .refine((p) => !(p.shares && p.participants), "shares or participants");

/** Participants -> resolved shares of `total` (names matched to contacts when unambiguous). */
export function resolveShares(
  total: number,
  participants: z.infer<typeof participantSchema>[],
  contacts: ContactRef[],
  opts: { ownerShare?: boolean; rounding?: number },
) {
  const resolved = participants.map((p) => {
    if (p.contact_id) return { ...p, name: p.name ?? contacts.find((c) => c.id === p.contact_id)?.alias ?? "" };
    const c = matchContact(p.name ?? "", contacts);
    return c ? { ...p, contact_id: c.id, name: c.alias } : { ...p, contact_id: null };
  });
  return computeShares(
    total,
    resolved.map((p) => ({ contact_id: p.contact_id ?? null, name: p.name ?? "", mode: p.mode ?? "EQUAL", value: p.value ?? null })),
    opts,
  );
}

async function contactsOf(d: SplitDeps, owner: string): Promise<ContactRef[]> {
  const raw = ((await d.gw.readContacts(owner)) as { id: string; alias: string; archived?: boolean }[]) ?? [];
  return raw.filter((c) => !c.archived).map((c) => ({ id: c.id, alias: c.alias }));
}

async function expenseCategories(d: SplitDeps, owner: string): Promise<{ id: string; name: string }[]> {
  const raw = ((await d.gw.readCategories(owner)) as { id: string; name: string; type: string; archived?: boolean }[]) ?? [];
  return raw.filter((c) => c.type === "EXPENSE" && !c.archived).map((c) => ({ id: c.id, name: c.name }));
}

async function txContext(d: SplitDeps, owner: string, txId: string): Promise<SplitContext> {
  const ctx = await sgOf(d).context(owner, txId);
  if (!ctx) throw new DomainError("NOT_FOUND");
  if (ctx.tx.status !== "POSTED" || !["EXPENSE", "UNKNOWN_DEBIT"].includes(ctx.tx.kind)) throw new DomainError("INVALID_STATE");
  return ctx;
}

export function registerSplitRoutes(app: Hono<any>, getDeps: (env: any) => SplitDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  // ?tx_id=… (splits of one bill) | ?state=PROPOSED (bell "Cần xử lý") | nothing (last 60 days).
  app.get("/v1/splits", auth, async (c) => {
    const q = parseOr(z.object({ tx_id: UUID.optional(), state: z.enum(["PROPOSED", "APPLIED", "UNDONE", "DISMISSED"]).optional() }).strict(), c.req.query());
    return ok(c, await sgOf(getDeps(c.env)).list(ownerOf(c), q.tx_id ?? null, q.state ?? null));
  });

  // Shared with the assistant: compute shares of one bill for some people and store them as a one-tap proposal.
  app.post("/v1/splits/propose", auth, async (c) => {
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const b = parseOr(proposeSchema, await c.req.json().catch(() => null));
    const ctx = await txContext(d, owner, b.tx_id);
    if (ctx.live?.state === "APPLIED") throw new DomainError("SPLIT_EXISTS");
    const total = Number(ctx.tx.amount);
    const split = resolveShares(total, b.participants ?? [], await contactsOf(d, owner), { ownerShare: b.owner_share ?? true, rounding: b.rounding ?? 5000 });
    const shares = split.shares.filter((s) => s.amount > 0);
    const r = await sgOf(d).propose(owner, {
      tx_id: b.tx_id,
      shares: shares.map((s) => ({ contact_id: s.contact_id, name: s.name, amount: String(s.amount) })),
      owner_amount: String(split.owner_amount),
      category_id: b.category_id ?? null,
      source: b.source ?? "MANUAL",
      confidence: b.confidence ?? 0.6,
      note: b.note ?? null,
      hints: b.hints ?? [],
    });
    return ok(c, { ...r, total: String(total), shares, owner_amount: String(split.owner_amount), unresolved: shares.filter((s) => !s.contact_id).map((s) => s.name) });
  });

  // Shared with the assistant: create the debts now (explicit amounts, or participants + rounding). Missing people are
  // created as contacts by name. Confirming a proposal: pass its application_id (and the possibly edited shares).
  app.post("/v1/splits/apply", auth, async (c) => {
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const b = parseOr(applySchema, await c.req.json().catch(() => null));
    const ctx = await txContext(d, owner, b.tx_id);
    let shares: ApplyShare[];
    if (b.shares) {
      shares = b.shares.map((s) => ({ contact_id: s.contact_id ?? null, name: s.name ?? null, amount: String(s.amount) }));
    } else if (b.participants) {
      const split = resolveShares(Number(ctx.tx.amount), b.participants, await contactsOf(d, owner), { ownerShare: b.owner_share ?? true, rounding: b.rounding ?? 5000 });
      shares = split.shares.filter((s) => s.amount > 0).map((s) => ({ contact_id: s.contact_id, name: s.name, amount: String(s.amount) }));
    } else if (b.application_id) {
      const list = await sgOf(d).list(owner, b.tx_id, "PROPOSED");
      const prop = list.find((a) => a.id === b.application_id) as { shares?: ApplyShare[]; category_id?: string; recurring_id?: string; occurrence_id?: string } | undefined;
      if (!prop) throw new DomainError("NOT_FOUND");
      shares = (prop.shares ?? []).map((s) => ({ contact_id: s.contact_id ?? null, name: s.name ?? null, amount: String(s.amount) }));
      b.category_id ??= prop.category_id ?? null;
      b.recurring_id ??= prop.recurring_id ?? null;
      b.occurrence_id ??= prop.occurrence_id ?? null;
    } else {
      throw new DomainError("VALIDATION_FAILED");
    }
    const res = await sgOf(d).apply(owner, {
      tx_id: b.tx_id,
      shares,
      category_id: b.category_id ?? null,
      merchant: b.merchant ?? null,
      recurring_id: b.recurring_id ?? null,
      occurrence_id: b.occurrence_id ?? null,
      application_id: b.application_id ?? null,
      source: b.source ?? "MANUAL",
      note: b.note ?? null,
    });
    return ok(c, res);
  });

  app.post("/v1/splits/:id/undo", auth, async (c) => ok(c, await sgOf(getDeps(c.env)).undo(ownerOf(c), parseOr(UUID, c.req.param("id")))));
  app.post("/v1/splits/:id/dismiss", auth, async (c) => ok(c, await sgOf(getDeps(c.env)).dismiss(ownerOf(c), parseOr(UUID, c.req.param("id")))));

  // Every picture added to a transaction ("Ảnh chứng từ"): the phone reads the text (ML Kit) and sends it here.
  // 1. category / merchant / short item note: applied in place when sure (undo with `previous`), else a one-tap suggestion;
  // 2. bill total different from the transaction amount: reported (never changes money by itself);
  // 3. a recurring rule for this bill applies at once (split debts included);
  // 4. otherwise a group bill becomes a split proposal (people named on the bill, or empty = "chọn người").
  app.post("/v1/bills/analyze", auth, async (c) => {
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const b = parseOr(z.object({ tx_id: UUID, text: z.string().min(1).max(12000) }).strict(), await c.req.json().catch(() => null));
    return ok(c, await analyzeBill(d, owner, b.tx_id, b.text));
  });
  // "Có vẻ bạn trả 1.600.000đ vào ngày 6 hằng tháng — tạo quy tắc?"
  app.get("/v1/splits/rule-suggestions", auth, async (c) => ok(c, await sgOf(getDeps(c.env)).ruleSuggestions(ownerOf(c))));
}
