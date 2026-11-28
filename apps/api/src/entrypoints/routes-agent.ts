import type { Context, Hono } from "hono";
import type { Config } from "../bootstrap/config";
import type { CommandContext, FinanceGateway } from "../modules/ledger/ports";
import { actualMicro, buildRequestBody, estimateMicro, parseModelJson, type ProviderCall } from "../modules/ai/assistant";
import {
  AGENT_MAX_OUTPUT_TOKENS,
  AgentRequest,
  MAX_LOOKUP_ROUNDS,
  buildAgentMessages,
  buildKnownIds,
  lookupFilters,
  resolveAgentOutput,
  txBrief,
  type AgentAction,
  type AgentContext,
  type AgentResult,
  type AgentTx,
  type LookupFilters,
} from "../modules/ai/agent";
import { NO_SPLIT_KEY, ROUNDING_KEY, analyzeBill, groupKey, type BillPurpose } from "../modules/ai/bill";
import { PHOTO_PREFIX, normalizeKey, describeMemory, type MemoryEntry, type MemoryWrite } from "../modules/ai/memory";
import { UndoRequest, type UndoOp } from "../modules/ai/tools";
import { SLOT_QUESTION, missedDaily, optionText, routineOptions, slotOf, slotRecorded, type RoutineTx, type Slot } from "../modules/ai/routine";
import { z } from "zod";

const RoutineRecord = z.object({
  slot: z.enum(["breakfast", "lunch", "dinner", "missed"]),
  /** Option keys (spaces may come as dashes from push button ids); "all" = every option of the slot/day. */
  keys: z.array(z.string().min(1).max(60)).min(1).max(6),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
});
import { canonicalJson, sha256Hex } from "../shared/canonical";
import { DomainError } from "../shared/errors";
import { currentVnDate, monthRangeUtc } from "../shared/report-period";
import { afterAgentTurn, agentMemory, background, mgOf, type MemoryDeps } from "./routes-memory";
import { classifyInput, loadContext as loadClassifyContext } from "./routes-classify";
import { enrichPlanActions } from "./routes-plans";

// The finance assistant's agent endpoint (moved out of http.ts): one sentence (or a bill photo's OCR text) becomes
// validated commands the app executes, with LOOKUP rounds (search first, then act), bill-split questions, learned
// habits, and server-resolved undo (POST /v1/ai/undo). The model only plans; the ledger rules stay in the database.

export interface AgentDeps extends MemoryDeps {
  cfg: Config;
  gw: FinanceGateway;
  ai?: ProviderCall;
}

export interface AgentHelpers {
  reserveAi(d: any, owner: string, est: number, feature?: string): Promise<string | null>;
  needDevice(c: Context<any>): string;
}

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}

const PURPOSE_LABEL: Record<BillPurpose, string> = {
  PERSONAL: "mua sắm cá nhân",
  EATOUT: "ăn uống bên ngoài",
  ENTERTAINMENT: "vui chơi giải trí",
  HOUSEHOLD: "hóa đơn sinh hoạt",
  OTHER: "khác",
};

// ---------------------------------------------------------------- habits used by the agent
export interface SplitHabits {
  groups: { names: string[]; weight: number }[];
  noSplit: Set<BillPurpose>;
  rounding?: number | undefined;
}

/** Split habits from memory rows (HABIT "chia bill …", HABIT "khong chia …", PREFERENCE rounding). */
export function splitHabitsFrom(rows: MemoryEntry[]): SplitHabits {
  const groups: SplitHabits["groups"] = [];
  const noSplit = new Set<BillPurpose>();
  let rounding: number | undefined;
  for (const m of rows) {
    const w = Number(m.weight);
    if (!(w >= 0.2)) continue;
    const v = (m.value ?? {}) as Record<string, unknown>;
    if (m.kind === "HABIT" && m.key.startsWith("chia bill ") && Array.isArray(v.names)) {
      groups.push({ names: (v.names as unknown[]).map(String).slice(0, 10), weight: w });
    } else if (m.kind === "HABIT" && m.key.startsWith("khong chia ") && w >= 0.5 && typeof v.purpose === "string") {
      noSplit.add(v.purpose as BillPurpose);
    } else if (m.kind === "PREFERENCE" && m.key === ROUNDING_KEY && typeof v.rounding === "number") {
      rounding = v.rounding;
    }
  }
  groups.sort((a, b) => b.weight - a.weight);
  return { groups, noSplit, rounding };
}

/** What the owner taught in this turn about splitting (confirmed groups, rounding, "không chia" for a bill type). */
export function splitLearnings(text: string, plan: Record<string, unknown>[], previous: { steps: { do: string; data?: Record<string, unknown> | undefined }[] } | undefined): MemoryWrite[] {
  const out: MemoryWrite[] = [];
  for (const s of plan) {
    if (s.do !== "SPLIT" || !Array.isArray(s.people)) continue;
    const names = (s.people as unknown[]).map((p) => String(p).trim()).filter((p) => p && !/^(tôi|toi|mình|minh)$/i.test(p)).slice(0, 10);
    if (!names.length) continue;
    out.push({ kind: "HABIT", key: groupKey(names), value: { text: `Hay chia hóa đơn với ${names.join(", ")}`, names }, source: "pattern" });
    const r = s.rounding === null || s.rounding === undefined ? NaN : Number(s.rounding);
    if ([0, 1000, 5000, 10000].includes(r) && /(lam tron|làm tròn|chan|chẵn|le|lẻ|chinh xac|chính xác)/i.test(text)) {
      out.push({ kind: "PREFERENCE", key: ROUNDING_KEY, value: { text: r ? `Chia hóa đơn làm tròn lên ${r.toLocaleString("vi-VN")}đ` : "Chia hóa đơn chính xác từng đồng", rounding: r }, source: "user" });
    }
  }
  const pending = previous?.steps.find((s) => s.do === "SPLIT_PENDING");
  const purpose = pending?.data?.purpose;
  if (pending && typeof purpose === "string" && /kh[oô]ng chia/i.test(text) && !plan.some((s) => s.do === "SPLIT")) {
    out.push({ kind: "HABIT", key: NO_SPLIT_KEY(purpose as BillPurpose), value: { text: `Thường không chia hóa đơn ${PURPOSE_LABEL[purpose as BillPurpose] ?? ""}`.trim(), purpose }, source: "pattern" });
  }
  return out;
}

// ---------------------------------------------------------------- lookups
const vnDay = (iso: string) => new Date(Date.parse(iso) + 7 * 3_600_000).toISOString().slice(0, 10);

/** Applies LOOKUP / ANSWER filters to a list of transactions (newest first), max `limit` hits. */
export function filterTxs(txs: AgentTx[], f: LookupFilters, limit = 20): AgentTx[] {
  const q = f.q ? normalizeKey(f.q) : "";
  return txs
    .filter((t) => {
      if (t.status === "VOID") return false;
      const day = vnDay(t.effective_at);
      if (f.since && day < f.since) return false;
      if (f.until && day > f.until) return false;
      if (f.month && !day.startsWith(f.month)) return false;
      if (f.category && t.category_id !== f.category) return false;
      if (f.account && t.account_id !== f.account && t.to_account_id !== f.account) return false;
      const amt = Number(t.amount);
      if (f.min !== undefined && amt < f.min) return false;
      if (f.max !== undefined && amt > f.max) return false;
      if (q && !normalizeKey(`${t.note ?? ""} ${t.merchant ?? ""}`).includes(q)) return false;
      return true;
    })
    .slice(0, limit);
}

/** Up to `pages` x 100 transactions, newest first (enough for "tuần trước", "tháng này"). */
async function loadTxs(gw: FinanceGateway, owner: string, first: AgentTx[], until: string | undefined, pages = 3): Promise<AgentTx[]> {
  const all = [...first];
  let more = first.length >= 100;
  for (let p = 1; p < pages && more; p++) {
    const last = all[all.length - 1];
    if (!last || (until && vnDay(last.effective_at) < until)) break;
    const next = (await gw.readTransactions(owner, 100, { at: last.effective_at, id: last.id })) as AgentTx[];
    all.push(...next);
    more = next.length >= 100;
  }
  return all;
}

async function runLookups(d: AgentDeps, owner: string, ctx: AgentContext, steps: Record<string, unknown>[]): Promise<unknown[]> {
  const out: unknown[] = [];
  for (const s of steps.filter((x) => x.do === "LOOKUP").slice(0, 4)) {
    const f = lookupFilters(s as Parameters<typeof lookupFilters>[0]);
    switch (f.what) {
      case "TRANSACTIONS": {
        const floor = f.since ?? (f.month ? `${f.month}-01` : undefined);
        ctx.txs = await loadTxs(d.gw, owner, ctx.txs ?? [], floor);
        out.push({ what: f.what, filters: f, results: filterTxs(ctx.txs, f).map(txBrief) });
        break;
      }
      case "DEBTS":
        out.push({ what: f.what, results: ctx.debts.map((x) => ({ id: x.id, type: x.direction, who: x.contact_alias, remaining: x.remaining, state: x.state, version: x.version, payments: (x.payments ?? []).filter((p) => !p.reversed) })) });
        break;
      case "RECURRING":
        out.push({ what: f.what, results: (ctx.recurring ?? []).map((r) => ({ id: r.id, name: r.name, version: r.version, occurrences: r.occurrences })) });
        break;
      case "BUDGETS":
        out.push({ what: f.what, results: ctx.budgets ?? [] });
        break;
      case "CONTACTS":
        out.push({ what: f.what, results: ctx.contacts.map((c) => ({ id: c.id, name: c.alias, version: c.version })) });
        break;
      case "GOALS":
        out.push({ what: f.what, results: ctx.goals });
        break;
    }
  }
  ctx.knownIds = buildKnownIds(ctx);
  return out;
}

// ---------------------------------------------------------------- the agent turn
/** Extra context that must never break a turn (missing in older gateways / test fakes, or a transient failure). */
async function optional<T>(f: () => Promise<T>): Promise<T | unknown[]> {
  try {
    return await f();
  } catch {
    return [];
  }
}
async function loadContext(d: AgentDeps, owner: string, now: Date): Promise<AgentContext> {
  const today = currentVnDate(now);
  const month = today.slice(0, 7);
  const [accs, cats, contacts, debts, goalsRaw, recent, budgets, recurring] = (await Promise.all([
    d.gw.readAccounts(owner),
    d.gw.readCategories(owner),
    d.gw.readContacts(owner),
    d.gw.readDebts(owner, today),
    d.gw.readGoals(owner),
    d.gw.readTransactions(owner, 100, null),
    optional(() => d.gw.readBudgets(owner, `${month}-01`)),
    optional(() => d.gw.readRecurring(owner, today)),
  ])) as [any[], any[], any[], any[], { goals: any[] }, AgentTx[], any[], any[]];
  const accounts = accs.filter((a) => !a.archived);
  const live = recent.filter((t) => t.status !== "VOID");
  const defaultAccountId = accounts.find((a) => a.id === live[0]?.account_id)?.id ?? accounts.find((a) => a.kind === "CASH")?.id ?? accounts[0]?.id;
  const ctx: AgentContext = {
    today,
    nowIso: now.toISOString(),
    accounts,
    categories: cats,
    contacts,
    debts,
    goals: goalsRaw.goals,
    txs: recent,
    budgets: (budgets ?? []).map((b: any) => ({ id: b.id, month, category_id: b.category_id ?? null, limit: String(b.limit_amount ?? b.limit ?? ""), carryover: Boolean(b.carryover), version: b.version })),
    recurring: (recurring ?? []).map((r: any) => ({ id: r.id, name: r.name, version: r.version, occurrences: (r.expected ?? []).map((o: any) => ({ id: o.id, version: o.version, due_date: o.due_date })) })),
    ...(defaultAccountId ? { defaultAccountId } : {}),
    ...(live[0] ? { lastTx: { id: live[0].id, version: live[0].version } } : {}),
  };
  ctx.knownIds = buildKnownIds(ctx);
  return ctx;
}

async function callModel(d: AgentDeps, h: AgentHelpers, owner: string, messages: { role: string; content: string }[], bytes: number): Promise<unknown> {
  const est = estimateMicro(bytes, AGENT_MAX_OUTPUT_TOKENS);
  const reservation = await h.reserveAi(d, owner, est, "agent");
  let out;
  try {
    out = await d.ai!(buildRequestBody(messages, AGENT_MAX_OUTPUT_TOKENS));
  } catch (e) {
    if (reservation) await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined);
    throw e instanceof DomainError ? e : new DomainError("AI_UNAVAILABLE");
  }
  if (reservation) await d.gw.aiSettle(owner, reservation, actualMicro(out.usage)).catch(() => undefined);
  return parseModelJson(out.content);
}

/** "Quên cái đó đi": FORGET calls become deletes of the matching memory entries (or a question). */
async function resolveForget(d: AgentDeps, owner: string, result: AgentResult): Promise<void> {
  const forgets = result.actions.filter((a) => a.type === "CALL" && a.call.method === "DELETE" && a.call.path.startsWith("/ai/memory?match="));
  if (!forgets.length) return;
  const rows = await mgOf(d).list(owner, null, 300).catch(() => [] as MemoryEntry[]);
  for (const f of forgets) {
    if (f.type !== "CALL") continue;
    const want = normalizeKey(decodeURIComponent(f.call.path.slice("/ai/memory?match=".length)));
    const words = want.split(" ").filter((w) => w.length >= 2);
    const hits = rows.filter((m) => {
      const hay = normalizeKey(`${m.key} ${describeMemory(m)}`);
      return words.length > 0 && words.filter((w) => hay.includes(w)).length >= Math.max(1, Math.ceil(words.length * 0.6));
    });
    const idx = result.actions.indexOf(f);
    if (!hits.length) {
      result.actions[idx] = { id: f.id, type: "ASK", question: "Mình không thấy điều nào như vậy trong ghi nhớ. Bạn mở Ghi nhớ của Trợ lý để xem nhé." };
      continue;
    }
    const replacement: AgentAction[] = hits.slice(0, 5).map((m, k) => ({
      id: k ? `${f.id}${String.fromCharCode(97 + k)}` : f.id,
      type: "CALL",
      risk: "low",
      title: "Quên điều này",
      lines: [describeMemory(m)],
      call: { method: "DELETE", path: `/ai/memory/${m.id}` },
    }));
    result.actions.splice(idx, 1, ...replacement);
  }
}

async function answerData(d: AgentDeps, owner: string, ctx: AgentContext, result: AgentResult): Promise<void> {
  const live = (ctx.txs ?? []).filter((t) => t.status !== "VOID");
  for (const a of result.actions) {
    if (a.type !== "ANSWER") continue;
    const month = a.month ?? ctx.today.slice(0, 7);
    switch (a.what) {
      case "BALANCES":
        a.data = ctx.accounts.map((x) => ({ id: x.id, name: x.name, kind: x.kind, balance: x.balance ?? null }));
        break;
      case "RECENT":
        a.data = live.slice(0, 8);
        break;
      case "TRANSACTIONS": {
        const f = a.filters ?? { what: "TRANSACTIONS" };
        ctx.txs = await loadTxs(d.gw, owner, ctx.txs ?? [], f.since ?? (f.month ? `${f.month}-01` : undefined));
        a.data = filterTxs(ctx.txs, f, 30);
        break;
      }
      case "DEBTS":
        a.data = ctx.debts.filter((x) => x.state === "OPEN" || x.state === "PARTIAL");
        break;
      case "GOALS":
        a.data = ctx.goals;
        break;
      case "BUDGETS":
        a.data = await d.gw.readBudgets(owner, `${month}-01`);
        break;
      case "RECURRING":
        a.data = await d.gw.readRecurring(owner, ctx.today);
        break;
      case "CONTACTS":
        a.data = ctx.contacts;
        break;
      case "PLANS":
        break; // filled by enrichPlanActions (routes-plans.ts)
      default: {
        const { from, to } = monthRangeUtc(month);
        a.data = await d.gw.readDashboard(owner, from, to);
      }
    }
  }
}

/**
 * Never ask what the data answers: a money step whose category is missing or wrong gets one from the bill's hints
 * (owner's category names) or the shared classifier (learned rules, history, dictionary; no extra model call).
 */
export async function fillCategories(d: AgentDeps, owner: string, raw: unknown, ctx: AgentContext): Promise<void> {
  const steps = (raw as { steps?: Record<string, unknown>[] } | null)?.steps;
  if (!Array.isArray(steps)) return;
  let cctx: Awaited<ReturnType<typeof loadClassifyContext>> | null | undefined;
  for (const s of steps) {
    if (!s || typeof s !== "object" || !["EXPENSE", "INCOME", "SPLIT"].includes(String(s.do))) continue;
    const want = s.do === "INCOME" ? "INCOME" : "EXPENSE";
    if (ctx.categories.some((c) => c.id === s.category && c.type === want)) continue;
    if (want === "EXPENSE" && ctx.bill) {
      const hit = ctx.bill.categoryHints.map((h) => ctx.categories.find((c) => c.type === "EXPENSE" && normalizeKey(c.name) === normalizeKey(h))).find(Boolean);
      if (hit) {
        s.category = hit.id;
        continue;
      }
    }
    const text = [s.note, s.merchant, ctx.bill?.merchant].filter((x) => typeof x === "string" && x).join(" ");
    if (text.trim().length < 2) continue;
    try {
      cctx ??= await loadClassifyContext(d as never, owner);
      const r = await classifyInput(d as never, owner, { text, direction: want === "INCOME" ? "in" : "out", ...(Number(s.amount) > 0 ? { amount: Number(s.amount) } : {}) }, cctx, false);
      if (r?.categoryId && r.confidence >= 0.6 && ctx.categories.some((c) => c.id === r.categoryId && c.type === want)) s.category = r.categoryId;
    } catch {
      cctx = null; // classifier unavailable: the step will ask, as before
      break;
    }
  }
}

export async function runAgentTurn(c: Context<any>, d: AgentDeps, h: AgentHelpers, owner: string, body: ReturnType<typeof AgentRequest.parse>, now = new Date()): Promise<AgentResult> {
  const ctx = await loadContext(d, owner, now);
  // Habits that shape the turn: who the owner usually splits with, rounding, bill types never split.
  const habitRows = await mgOf(d)
    .list(owner, null, 300)
    .catch(() => [] as MemoryEntry[]);
  const habits = splitHabitsFrom(habitRows);
  ctx.splitGroups = habits.groups;
  if (habits.rounding !== undefined) ctx.rounding = habits.rounding;
  if (body.text.trimStart().startsWith(PHOTO_PREFIX)) ctx.bill = analyzeBill(body.text.trimStart().slice(PHOTO_PREFIX.length), { noSplit: habits.noSplit });

  const memory = await agentMemory(d, owner, body.text);
  let lookups: unknown[] = [];
  let raw: unknown = null;
  for (let round = 0; round <= MAX_LOOKUP_ROUNDS; round++) {
    const { messages, bytes } = buildAgentMessages(body.text, body.history ?? [], ctx, { auto: body.auto === true, previous: body.previous, memory, lookups });
    raw = await callModel(d, h, owner, messages, bytes);
    const steps = Array.isArray((raw as { steps?: unknown })?.steps) ? ((raw as { steps: Record<string, unknown>[] }).steps) : [];
    if (round === MAX_LOOKUP_ROUNDS || !steps.some((s) => s?.do === "LOOKUP")) break;
    lookups = [...lookups, ...(await runLookups(d, owner, ctx, steps))].slice(-6);
  }
  await fillCategories(d, owner, raw, ctx);
  const result = resolveAgentOutput(raw, ctx);
  // Remember the bill type on the pending split so a "không chia" answer can teach it.
  if (ctx.bill) for (const p of result.plan) if (p.do === "SPLIT_PENDING") p.purpose = ctx.bill.purpose;
  await afterAgentTurn(c, d, owner, body.text, raw, result.plan);
  const learned = splitLearnings(body.text, result.plan, body.previous);
  if (learned.length) await background(c, mgOf(d).upsertMany(owner, learned));
  await resolveForget(d, owner, result);
  await answerData(d, owner, ctx, result);
  await enrichPlanActions(d, owner, result, now); // event estimates / life projections on the plan cards (routes-plans.ts)
  return result;
}

// ---------------------------------------------------------------- undo
/** Deterministic command id per (step, undo op): tapping Hoàn tác twice replays instead of undoing twice. */
async function undoCommandId(stepCommandId: string, k: number): Promise<string> {
  const h = await sha256Hex(`moma-undo|${stepCommandId}|${k}`);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${((parseInt(h[16]!, 16) & 0x3) | 0x8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function findTx(gw: FinanceGateway, owner: string, id: string): Promise<AgentTx | undefined> {
  let page = (await gw.readTransactions(owner, 100, null)) as AgentTx[];
  for (let p = 0; p < 5; p++) {
    const hit = page.find((t) => t.id === id);
    if (hit) return hit;
    const last = page[page.length - 1];
    if (page.length < 100 || !last) return undefined;
    page = (await gw.readTransactions(owner, 100, { at: last.effective_at, id: last.id })) as AgentTx[];
  }
  return undefined;
}

/** Turns one undo op into the concrete command, reading current versions. null = already undone / nothing to do. */
export async function undoCommand(gw: FinanceGateway, owner: string, op: UndoOp, today: string): Promise<{ command_type: string; payload: Record<string, unknown> } | null> {
  const reason = "Hoàn tác từ Trợ lý tài chính";
  switch (op.op) {
    case "REVERSE_TX": {
      const t = await findTx(gw, owner, op.tx_id);
      if (!t || t.status === "VOID") return null;
      return { command_type: "TX_REVERSE", payload: { tx_id: t.id, reason, expected_version: t.version } };
    }
    case "CORRECT_TX": {
      const t = await findTx(gw, owner, op.tx_id);
      if (!t || t.status === "VOID") return null;
      return { command_type: "TX_CORRECT", payload: { tx_id: t.id, reason, expected_version: t.version, replacement: op.replacement } };
    }
    case "RESTORE_TX": {
      const t = await findTx(gw, owner, op.tx_id);
      if (!t || t.status === "VOID") return null;
      return { command_type: "TX_ANNOTATE", payload: { tx_id: t.id, expected_version: t.version, ...op.fields } };
    }
    case "CANCEL_DEBT": {
      const debt = ((await gw.readDebts(owner, today)) as any[]).find((x) => x.id === op.debt_id);
      if (!debt || debt.state === "CANCELLED") return null;
      return { command_type: "DEBT_CANCEL", payload: { debt_id: debt.id, expected_version: debt.version, reason } };
    }
    case "REVERSE_DEBT_PAYMENT": {
      const debt = ((await gw.readDebts(owner, today)) as any[]).find((x) => x.id === op.debt_id);
      const pay = (debt?.payments ?? []).find((p: any) => p.tx_id === op.tx_id && !p.reversed);
      if (!debt || !pay) return null;
      return { command_type: "DEBT_PAYMENT_REVERSE", payload: { debt_id: debt.id, payment_id: pay.id, expected_version: debt.version } };
    }
    case "GOAL_MOVE": {
      const goal = ((await gw.readGoals(owner)) as { goals: any[] }).goals.find((g) => g.id === op.goal_id);
      if (!goal) return null;
      return { command_type: op.command_type, payload: { goal_id: goal.id, account_id: op.account_id, amount: op.amount, expected_version: goal.version } };
    }
    case "ARCHIVE_CONTACT": {
      const ct = ((await gw.readContacts(owner)) as any[]).find((x) => x.id === op.contact_id);
      if (!ct || ct.archived) return null;
      return { command_type: "CONTACT_UPDATE", payload: { contact_id: ct.id, expected_version: ct.version, archived: true } };
    }
    case "ARCHIVE_CATEGORY": {
      const cat = ((await gw.readCategories(owner)) as any[]).find((x) => x.id === op.category_id);
      if (!cat || cat.archived) return null;
      return { command_type: "CATEGORY_UPSERT", payload: { category_id: cat.id, name: cat.name, type: cat.type, archived: true, expected_version: cat.version } };
    }
    case "DISABLE_RECURRING": {
      const r = ((await gw.readRecurring(owner, today)) as any[]).find((x) => x.id === op.recurring_id);
      if (!r || r.enabled === false) return null;
      const tpl = (r.template ?? {}) as Record<string, unknown>;
      return {
        command_type: "RECURRING_UPSERT",
        payload: {
          recurring_id: r.id, expected_version: r.version, name: r.name, kind: r.kind, account_id: r.account_id, amount: String(r.amount), interval: r.interval,
          next_date: String(r.next_date).slice(0, 10), enabled: false,
          ...(typeof tpl.category_id === "string" ? { category_id: tpl.category_id } : {}),
          ...(typeof tpl.to_account_id === "string" ? { to_account_id: tpl.to_account_id } : {}),
        },
      };
    }
    case "ARCHIVE_ACCOUNT": {
      const a = ((await gw.readAccounts(owner)) as any[]).find((x) => x.id === op.account_id);
      if (!a || a.archived) return null;
      return { command_type: "ACCOUNT_UPDATE", payload: { account_id: a.id, expected_version: a.version, archived: true } };
    }
    case "SPLIT_UNDO":
      return { command_type: "SPLIT_UNDO", payload: { application_id: op.application_id } };
    case "RESTORE_BUDGET": {
      const b = ((await gw.readBudgets(owner, `${op.month}-01`)) as any[]).find((x) => (x.category_id ?? undefined) === op.category_id);
      return {
        command_type: "BUDGET_UPSERT",
        payload: { month: op.month, limit: op.limit, carryover: op.carryover, ...(op.category_id ? { category_id: op.category_id } : {}), ...(b ? { expected_version: b.version } : {}) },
      };
    }
  }
}

// ---------------------------------------------------------------- routines ("Sáng nay bạn ăn gì?")
const SLOTS = ["breakfast", "lunch", "dinner"] as const;
const vnd = (n: number) => `${n.toLocaleString("vi-VN").replace(/,/g, ".")}đ`;

/** Recent expenses for routine learning (up to 300, ~1 month for most owners). */
async function routineTxs(gw: FinanceGateway, owner: string, now: Date): Promise<RoutineTx[]> {
  const first = (await gw.readTransactions(owner, 100, null)) as RoutineTx[];
  const floor = new Date(now.getTime() - 31 * 86_400_000 + 7 * 3_600_000).toISOString().slice(0, 10);
  return (await loadTxs(gw, owner, first as AgentTx[], floor)) as RoutineTx[];
}

export function currentSlot(now: Date): Slot | null {
  return slotOf(now.toISOString());
}

/** Options for a slot (today), whether the slot is already recorded, and the question to ask. */
export async function routineFor(gw: FinanceGateway, owner: string, slot: Slot, now: Date, txs?: RoutineTx[]) {
  const list = txs ?? (await routineTxs(gw, owner, now));
  return { slot, question: SLOT_QUESTION[slot], recorded: slotRecorded(list, slot, now), options: routineOptions(list, slot, now) };
}

/** Command id per (owner, day, slot, option): tapping the same answer twice (push + app) records it once. */
async function routineCommandId(owner: string, day: string, slot: string, key: string): Promise<string> {
  const h = await sha256Hex(`moma-routine|${owner}|${day}|${slot}|${key}`);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${((parseInt(h[16]!, 16) & 0x3) | 0x8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/**
 * A planned meal reminder made personal: "Sáng nay bạn ăn gì?" with the two most likely answers as buttons
 * (tap = recorded, no typing) + "Hôm nay không". Unchanged when nothing has been learned yet.
 */
export async function personalizeMealPush<P extends { meal: string; title: string; body: string; data: Record<string, unknown>; buttons: { id: string; text: string }[] }>(gw: FinanceGateway, owner: string, p: P, now: Date): Promise<P> {
  if (!(SLOTS as readonly string[]).includes(p.meal)) return p;
  try {
    const r = await routineFor(gw, owner, p.meal as Slot, now);
    if (!r.options.length) return p;
    const date = currentVnDate(now);
    return {
      ...p,
      title: r.question,
      body: `${r.options.map((o) => `${o.label} ${vnd(o.amount)}`).join(" · ")} — chạm để chọn`,
      data: { ...p.data, route: `/ai?routine=${p.meal}`, routine: { slot: p.meal, date, options: r.options.map((o) => ({ key: o.key, label: o.label, amount: o.amount })) } },
      buttons: [...r.options.slice(0, 2).map((o) => ({ id: `rt_${p.meal}_${o.key.replace(/\s+/g, "-")}`, text: optionText(o) })), { id: `skip_${p.meal}`, text: "Hôm nay không" }],
    };
  } catch {
    return p;
  }
}

/** Morning nudge: daily items (gửi xe, cà phê…) bought almost every day but not recorded yesterday. */
export async function routineMissedPush(gw: FinanceGateway, owner: string, now: Date): Promise<{ key: string; title: string; body: string; data: Record<string, unknown>; buttons: { id: string; text: string }[] } | null> {
  const clock = new Date(now.getTime() + 7 * 3_600_000);
  const minutes = clock.getUTCHours() * 60 + clock.getUTCMinutes();
  if (minutes < 8 * 60 + 30 || minutes >= 11 * 60) return null;
  const today = currentVnDate(now);
  const yesterday = new Date(Date.parse(`${today}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
  const missed = missedDaily(await routineTxs(gw, owner, now), yesterday, now);
  if (!missed.length) return null;
  const names = missed.map((m) => m.label.toLowerCase());
  return {
    key: `routine_missed:${yesterday}`,
    title: `Hôm qua bạn chưa ghi ${names.join(", ")}?`,
    body: `${missed.map((m) => `${m.label} ${vnd(m.amount)}`).join(" · ")} — như mọi ngày. Chạm "Ghi" để thêm.`,
    data: { type: "reminder", kind: "routine_missed", date: yesterday, route: `/ai?missed=${yesterday}`, routine: { slot: "missed", date: yesterday, options: missed.map((o) => ({ key: o.key, label: o.label, amount: o.amount })) } },
    buttons: [{ id: `rtm_${yesterday}`, text: missed.length > 1 ? `Ghi cả ${missed.length}` : "Ghi" }, { id: "rtm_no", text: "Không" }],
  };
}

export function registerAgentRoutes(app: Hono<any>, getDeps: (env: any) => AgentDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>, h: AgentHelpers) {
  // The agent plans concrete commands from one sentence. It never writes: the app executes the returned commands
  // through the normal idempotent /v1/commands path (automatically for low-risk steps if the owner allows it).
  app.post("/v1/ai/agent", auth, async (c) => {
    const d = getDeps(c.env);
    if (!d.ai) throw new DomainError("AI_DISABLED");
    h.needDevice(c);
    const body = AgentRequest.parse(await c.req.json().catch(() => ({})));
    return ok(c, await runAgentTurn(c, d, h, (c as any).get("owner"), body));
  });

  // Routine options for a slot (home chips, assistant on open, widget). slot=now picks the current part of the day.
  app.get("/v1/ai/routine", auth, async (c) => {
    const d = getDeps(c.env);
    const now = new Date();
    const want = c.req.query("slot") ?? "now";
    const owner = (c as any).get("owner") as string;
    if (want === "missed") {
      const today = currentVnDate(now);
      const day = c.req.query("date") ?? new Date(Date.parse(`${today}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new DomainError("VALIDATION_FAILED");
      return ok(c, { slot: "missed", date: day, options: missedDaily(await routineTxs(d.gw, owner, now), day, now) });
    }
    const slot = want === "now" ? currentSlot(now) : (SLOTS as readonly string[]).includes(want) ? (want as Slot) : undefined;
    if (slot === undefined) throw new DomainError("VALIDATION_FAILED");
    if (slot === null) return ok(c, { slot: null, options: [] });
    return ok(c, await routineFor(d.gw, owner, slot, now));
  });

  // One-tap answer (push button, home chip, widget): records the learned option(s). Same tap twice = recorded once.
  app.post("/v1/ai/routine/record", auth, async (c) => {
    const d = getDeps(c.env);
    const deviceId = h.needDevice(c);
    const body = RoutineRecord.safeParse(await c.req.json().catch(() => null));
    if (!body.success) throw new DomainError("VALIDATION_FAILED");
    const owner = (c as any).get("owner") as string;
    const now = new Date();
    const txs = await routineTxs(d.gw, owner, now);
    const today = currentVnDate(now);
    const missed = body.data.slot === "missed";
    const day = body.data.date ?? (missed ? new Date(Date.parse(`${today}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10) : today);
    const options = missed ? missedDaily(txs, day, now) : routineOptions(txs, body.data.slot as Slot, now, { limit: 6 });
    const wanted = body.data.keys.map((k) => k.replace(/-/g, " "));
    const chosen = options.filter((o) => wanted.includes(o.key) || wanted.includes("all"));
    if (!chosen.length) throw new DomainError("NOT_FOUND");
    const accounts = ((await d.gw.readAccounts(owner)) as { id: string; archived?: boolean }[]).filter((a) => !a.archived);
    const ctx: CommandContext = { ownerId: owner, sessionId: (c as any).get("session").sessionId, deviceId };
    const recorded: { tx_id: string; label: string; amount: number; command_id: string; undo: { ops: UndoOp[] } }[] = [];
    for (const o of chosen) {
      const account = accounts.find((a) => a.id === o.account_id) ?? accounts[0];
      if (!account) throw new DomainError("NOT_FOUND");
      const at = missed || day !== today ? new Date(Date.parse(`${day}T12:00:00+07:00`)).toISOString() : now.toISOString();
      const commandId = await routineCommandId(owner, day, body.data.slot, o.key);
      const command = {
        command_id: commandId, command_type: "TX_CREATE" as const, schema_version: 1 as const,
        payload: { kind: "EXPENSE" as const, account_id: account.id, amount: String(o.amount), effective_at: at, category_id: o.category_id, note: o.label, source: "AI" as const },
      };
      const hash = await sha256Hex(canonicalJson({ owner, command }));
      const res = await d.gw.executeCommand(ctx, commandId, hash, command);
      recorded.push({ tx_id: String(res.tx_id ?? ""), label: o.label, amount: o.amount, command_id: commandId, undo: { ops: [{ op: "REVERSE_TX", tx_id: String(res.tx_id ?? "") }] } });
    }
    return ok(c, { recorded, message: `Đã ghi ${recorded.map((r) => `${r.label} ${vnd(r.amount)}`).join(", ")}` });
  });

  // "Hoàn tác" of an agent step: resolves current versions and runs the reverse commands (idempotent per step).
  app.post("/v1/ai/undo", auth, async (c) => {
    const d = getDeps(c.env);
    const deviceId = h.needDevice(c);
    const r = UndoRequest.safeParse(await c.req.json().catch(() => null));
    if (!r.success) throw new DomainError("VALIDATION_FAILED");
    const owner = (c as any).get("owner") as string;
    const ctx: CommandContext = { ownerId: owner, sessionId: (c as any).get("session").sessionId, deviceId };
    const today = currentVnDate(new Date());
    const done: { op: string; command_type: string; status: unknown }[] = [];
    for (const [k, op] of r.data.ops.entries()) {
      const cmd = await undoCommand(d.gw, owner, op, today);
      if (!cmd) {
        done.push({ op: op.op, command_type: "", status: "ALREADY_UNDONE" });
        continue;
      }
      const commandId = await undoCommandId(r.data.step_command_id, k);
      const command = { command_id: commandId, command_type: cmd.command_type, schema_version: 1 as const, payload: cmd.payload };
      const hash = await sha256Hex(canonicalJson({ owner, command }));
      try {
        const res = await d.gw.executeCommand(ctx, commandId, hash, command);
        done.push({ op: op.op, command_type: cmd.command_type, status: res.status });
      } catch (e) {
        // Undone elsewhere in the meantime (e.g. the split was undone from its push): nothing left to take back.
        if (e instanceof DomainError && e.code === "INVALID_STATE") done.push({ op: op.op, command_type: cmd.command_type, status: "ALREADY_UNDONE" });
        else throw e;
      }
    }
    // Undoing teaches too: the habit behind the step loses weight.
    if (r.data.habit) await background(c, mgOf(d).upsert(owner, { kind: r.data.habit.kind, key: r.data.habit.key, value: {}, source: "undo" }));
    return ok(c, { undone: done });
  });
}
