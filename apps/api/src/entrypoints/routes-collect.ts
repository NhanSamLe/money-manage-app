import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import type { FinanceGateway } from "../modules/ledger/ports";
import { sendPush } from "../modules/push/onesignal";
import {
  incomeGoalPush,
  incomeProposalAmount,
  isIncomeTrigger,
  isQuiet,
  isSociable,
  milestonePush,
  monthEndAmount,
  monthEndPush,
  monthEndTarget,
  payableDuePush,
  pickGoal,
  reminderMessage,
  remindDuePush,
  settledPush,
  suggestedPush,
  vnParts,
  type ReminderInfo,
} from "../modules/collect/collect";
import { SupabaseCollectGateway, type CollectGateway, type SettleJson } from "../modules/collect/gateway";
import { DomainError } from "../shared/errors";

// Debt collection + self-running goals (migration 019, D-025): the best-effort hook after every new money-in / money-out
// (bank event, notification, manual / assistant entry), the cron sweep (re-check, batched pushes after quiet hours,
// reminders, month-end and milestones) and the HTTP routes used by the app and the assistant. Hooks never fail the
// operation that triggered them; pushes respect quiet hours 23:00–06:59 and are claimed once (pf_push_log).

export interface CollectDeps {
  cfg: Config;
  gw: FinanceGateway;
  pushFetch?: typeof fetch;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  cog?: CollectGateway;
}

export const cogOf = (d: CollectDeps): CollectGateway => d.cog ?? new SupabaseCollectGateway(d.cfg);

/** Hours of captured money the cron re-checks. */
export const COLLECT_SWEEP_HOURS = 72;

const UUID = z.string().uuid();
const ownerOf = (c: Context<any>): string => (c as any).get("owner");

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}
function parseOr<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}
function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "collect", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

async function push(d: CollectDeps, owner: string, title: string, body: string, route: string, type: string) {
  await sendPush(d.cfg, d.pushFetch ?? fetch, { ownerId: owner, title, body, data: { type, route }, androidGroup: "moma_collect" }).catch(() => false);
}

/** Pushes once per key (claimed in pf_push_log); false when the key was already used. */
async function pushOnce(d: CollectDeps, owner: string, key: string, title: string, body: string, route: string, type: string): Promise<boolean> {
  if (!(await cogOf(d).pushClaim(owner, key))) return false;
  await push(d, owner, title, body, route, type);
  return true;
}

const settledItem = (s: SettleJson) => ({ alias: s.debt.contact_alias, amount: Number(s.amount), note: s.debt.note, direction: s.debt.direction });

/** The reminder for one debt, with the message the owner sends. */
export function withMessage(info: ReminderInfo) {
  const m = reminderMessage(info);
  return { ...info, tone: m.tone, message: m.text };
}

export type CollectOutcome = "NONE" | "AUTO" | "SUGGESTED" | "GOAL";

/**
 * One new money-in / money-out: settle an open debt (memo code / name + amount) or suggest it; otherwise, for a salary
 * or large income, propose putting part of it into the goal that needs it most. Never throws.
 */
export async function collectAfterTx(d: CollectDeps, owner: string, txId: string | undefined, step: string, opts: { notify?: boolean; now?: Date } = {}): Promise<CollectOutcome> {
  if (!txId) return "NONE";
  const notify = opts.notify ?? true;
  const now = opts.now ?? new Date();
  const cog = cogOf(d);
  try {
    const r = await cog.tryTx(owner, txId);
    if (r.status === "AUTO" && r.settle_id) {
      if (notify && !isQuiet(now)) {
        const s = await cog.forTx(owner, r.repay_tx_id ?? txId);
        if (s) {
          const p = settledPush([settledItem(s)]);
          await pushOnce(d, owner, `collect-auto:${r.settle_id}`, p.title, p.body, `/tx/${r.repay_tx_id}`, "collect");
        }
      }
      return "AUTO";
    }
    if (r.status === "SUGGESTED") {
      if (notify && !isQuiet(now)) {
        const s = (await cog.suggestions(owner)).find((x) => x.money.tx_id === txId);
        if (s) {
          const p = suggestedPush(s.debt.contact_alias, Number(s.amount), s.debt.direction);
          await pushOnce(d, owner, `collect-sug:${txId}`, p.title, p.body, "/notifications", "collect_suggest");
        }
      }
      return "SUGGESTED";
    }
  } catch (e) {
    logFailure(step, e);
  }
  return (await goalAfterIncome(d, owner, txId, step, { notify, now })) ? "GOAL" : "NONE";
}

/** Salary / large income → "Trích X vào mục tiêu Y?" (one proposal per income). */
export async function goalAfterIncome(d: CollectDeps, owner: string, txId: string, step: string, opts: { notify?: boolean; now?: Date } = {}): Promise<boolean> {
  const now = opts.now ?? new Date();
  try {
    const cog = cogOf(d);
    const f = await cog.incomeFacts(owner, txId);
    if (!f || !f.account_id || !isIncomeTrigger(f, f.note)) return false;
    const goal = pickGoal(await cog.goalPlan(owner, vnParts(now).date));
    if (!goal) return false;
    const income = Number(f.amount);
    const amount = incomeProposalAmount(goal, income, Number(f.available));
    if (!amount) return false;
    const r = await cog.propose(owner, { goal_id: goal.id, account_id: f.account_id, amount: String(amount), reason: "INCOME", period: txId, source_tx: txId });
    if (r.status !== "PROPOSED" || !r.id) return false;
    if ((opts.notify ?? true) && !isQuiet(now)) {
      const label = /thuong/i.test((f.category_name ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "")) ? "Thưởng" : f.category_name === "Lương" ? "Lương" : "Tiền";
      const p = incomeGoalPush(label, income, goal.name, amount);
      await pushOnce(d, owner, `goal-prop:${r.id}`, p.title, p.body, "/planning?tab=1", "goal_proposal");
    }
    return true;
  } catch (e) {
    logFailure(`${step}:goal`, e);
    return false;
  }
}

/** /v1/commands hook: a newly created money-in / money-out (manual entry, captured notification, assistant). */
export function collectCandidate(command: { command_type: string; payload: unknown }, result: Record<string, unknown> | null | undefined): string | undefined {
  if (command.command_type !== "TX_CREATE" || result?.status !== "COMMITTED") return undefined;
  const p = command.payload as Record<string, unknown> | null;
  if (!p || !["INCOME", "UNKNOWN_CREDIT", "EXPENSE", "UNKNOWN_DEBIT"].includes(String(p.kind))) return undefined;
  return typeof result.tx_id === "string" ? result.tx_id : undefined;
}

export async function collectAfterCommand(d: CollectDeps, owner: string, command: { command_type: string; payload: unknown }, result: Record<string, unknown>): Promise<void> {
  // A repayment (or a whole debt) undone from the debt sheet / assistant: money MoMa had booked as that repayment
  // comes back exactly as it arrived (it really moved).
  if (["DEBT_PAYMENT_REVERSE", "DEBT_CANCEL"].includes(command.command_type) && result?.status === "COMMITTED") {
    await cogOf(d)
      .repair(owner)
      .catch((e) => logFailure("repair", e));
    return;
  }
  const txId = collectCandidate(command, result);
  if (txId) await collectAfterTx(d, owner, txId, "command");
}

/**
 * Cron (every 15 min): re-check recent money, then (outside quiet hours) one batched push for automatic settlements and
 * waiting proposals, reminders due (08:00–20:59), month-end under-spend and goal milestones. Never throws.
 */
export async function runCollectSweep(d: CollectDeps, now: Date = new Date()): Promise<{ checked: number; auto: number; suggested: number; pushed: number; reminders: number; proposals: number; milestones: number } | null> {
  try {
    const owner = await d.gw.getOwnerId();
    if (!owner) return null;
    const cog = cogOf(d);
    const out = { checked: 0, auto: 0, suggested: 0, pushed: 0, reminders: 0, proposals: 0, milestones: 0 };
    const sw = await cog.sweep(owner, COLLECT_SWEEP_HOURS).catch((e) => {
      logFailure("sweep", e);
      return null;
    });
    if (sw) Object.assign(out, { checked: sw.checked, auto: sw.auto, suggested: sw.suggested });
    const today = vnParts(now).date;

    // Month-end proposal (stored even at night; announced below when allowed).
    const month = monthEndTarget(now);
    if (month) {
      try {
        const s = await cog.monthSurplus(owner, month);
        const goal = pickGoal(await cog.goalPlan(owner, today));
        const amount = goal && s.surplus && s.account_id ? monthEndAmount(Number(s.surplus), Number(s.available), Number(goal.left_amount)) : null;
        if (goal && amount && s.account_id) {
          const r = await cog.propose(owner, { goal_id: goal.id, account_id: s.account_id, amount: String(amount), reason: "MONTH_END", period: month });
          if (r.status === "PROPOSED") out.proposals++;
        }
      } catch (e) {
        logFailure("month_end", e);
      }
    }
    if (isQuiet(now)) return out;

    // Automatic settlements not announced yet (e.g. recorded during the night): one push.
    try {
      const fresh: SettleJson[] = [];
      for (const s of await cog.recentAuto(owner, 48)) if (await cog.pushClaim(owner, `collect-auto:${s.id}`)) fresh.push(s);
      if (fresh.length) {
        const p = settledPush(fresh.map(settledItem));
        await push(d, owner, p.title, p.body, fresh.length === 1 ? `/tx/${fresh[0]!.repay_tx_id}` : "/planning?tab=0", "collect");
        out.pushed++;
      }
    } catch (e) {
      logFailure("announce", e);
    }

    // Goal proposals waiting to be announced (income at night, month-end).
    try {
      for (const pr of await cog.proposals(owner)) {
        const p =
          pr.reason === "MONTH_END"
            ? monthEndPush(pr.period, Number(pr.amount), pr.goal_name, Number(pr.amount))
            : incomeGoalPush("Tiền", Number(pr.amount), pr.goal_name, Number(pr.amount));
        if (pr.reason === "MONTH_END") {
          const s = await cog.monthSurplus(owner, pr.period).catch(() => null);
          if (s?.surplus) Object.assign(p, monthEndPush(pr.period, Number(s.surplus), pr.goal_name, Number(pr.amount)));
        }
        if (await pushOnce(d, owner, `goal-prop:${pr.id}`, p.title, p.body, "/planning?tab=1", "goal_proposal")) out.pushed++;
      }
    } catch (e) {
      logFailure("proposals", e);
    }

    // Milestones.
    try {
      for (const m of await cog.milestones(owner)) {
        const p = milestonePush(m.name, m.pct, Number(m.allocated), Number(m.target));
        if (await pushOnce(d, owner, `goal-ms:${m.goal_id}:${m.pct}`, p.title, p.body, "/planning?tab=1", "goal_milestone")) out.milestones++;
      }
    } catch (e) {
      logFailure("milestones", e);
    }

    // Reminders: only in sociable hours, once per stage (remind count) of each debt, batched.
    if (isSociable(now)) {
      try {
        const due = await cog.due(owner, today);
        const recv: ReminderInfo[] = [];
        const pay: ReminderInfo[] = [];
        for (const r of due) {
          const key = r.direction === "RECEIVABLE" ? `collect-due:${r.debt_id}:${r.remind_count ?? 0}` : `collect-pay:${r.debt_id}:${r.due_date ?? ""}`;
          if (await cog.pushClaim(owner, key)) (r.direction === "RECEIVABLE" ? recv : pay).push(r);
        }
        if (recv.length) {
          const p = remindDuePush(recv.map((r) => ({ alias: r.contact_alias, remaining: Number(r.remaining) })));
          await push(d, owner, p.title, p.body, recv.length === 1 ? `/debts/remind/${recv[0]!.debt_id}` : "/planning?tab=0", "collect_remind");
          out.reminders += recv.length;
        }
        if (pay.length) {
          const p = payableDuePush(pay.map((r) => ({ alias: r.contact_alias, remaining: Number(r.remaining), due_date: r.due_date })));
          await push(d, owner, p.title, p.body, pay.length === 1 ? `/debts/remind/${pay[0]!.debt_id}` : "/planning?tab=0", "collect_pay");
          out.reminders += pay.length;
        }
      } catch (e) {
        logFailure("reminders", e);
      }
    }
    return out;
  } catch (e) {
    logFailure("run", e);
    return null;
  }
}

export function registerCollectRoutes(app: Hono<any>, getDeps: (env: any) => CollectDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  const cog = (c: Context<any>) => cogOf(getDeps(c.env));
  const today = () => vnParts().date;

  // ---- automatic settlement
  app.get("/v1/collect/suggestions", auth, async (c) => ok(c, await cog(c).suggestions(ownerOf(c))));
  app.post("/v1/collect/:id/decide", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("id"));
    const body = parseOr(z.object({ accept: z.boolean() }).strict(), await c.req.json().catch(() => null));
    return ok(c, await cog(c).decide(ownerOf(c), id, body.accept));
  });
  app.post("/v1/collect/:id/undo", auth, async (c) => ok(c, await cog(c).undo(ownerOf(c), parseOr(UUID, c.req.param("id")))));
  // The debt sheet's "Hoàn tác" for a repayment: { undone: false } when it was not recorded automatically.
  app.post("/v1/collect/undo-by-tx", auth, async (c) => {
    const body = parseOr(z.object({ tx_id: UUID }).strict(), await c.req.json().catch(() => null));
    const r = await cog(c).undoByTx(ownerOf(c), body.tx_id);
    return ok(c, r ? { undone: true, ...r } : { undone: false });
  });
  app.get("/v1/transactions/:id/collect", auth, async (c) => ok(c, await cog(c).forTx(ownerOf(c), parseOr(UUID, c.req.param("id")))));

  // ---- reminders
  app.get("/v1/debts/reminders", auth, async (c) => ok(c, (await cog(c).due(ownerOf(c), today())).map(withMessage)));
  app.get("/v1/debts/:id/reminder", auth, async (c) => ok(c, withMessage(await cog(c).reminder(ownerOf(c), parseOr(UUID, c.req.param("id")), today()))));
  app.post("/v1/debts/:id/reminded", auth, async (c) => ok(c, await cog(c).markReminded(ownerOf(c), parseOr(UUID, c.req.param("id")))));
  app.post("/v1/debts/:id/snooze", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("id"));
    const body = parseOr(z.object({ days: z.number().int().min(1).max(60) }).strict(), await c.req.json().catch(() => null));
    const until = new Date(Date.parse(`${today()}T00:00:00Z`) + body.days * 86_400_000).toISOString().slice(0, 10);
    return ok(c, await cog(c).snooze(ownerOf(c), id, until));
  });
  app.put("/v1/contacts/:id/bank", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("id"));
    const body = parseOr(
      z
        .object({
          bank: z.string().trim().min(1).max(60).optional(),
          bin: z.string().regex(/^[0-9]{6}$/).nullable().optional(),
          account_number: z.string().max(30),
          holder: z.string().max(80).nullable().optional(),
        })
        .strict(),
      await c.req.json().catch(() => null),
    );
    return ok(c, await cog(c).contactBank(ownerOf(c), id, body));
  });

  // ---- goals
  app.get("/v1/goals/plan", auth, async (c) => ok(c, await cog(c).goalPlan(ownerOf(c), today())));
  app.get("/v1/goals/proposals", auth, async (c) => ok(c, await cog(c).proposals(ownerOf(c))));
  app.post("/v1/goals/proposals/:id/accept", auth, async (c) => ok(c, await cog(c).accept(ownerOf(c), parseOr(UUID, c.req.param("id")))));
  app.post("/v1/goals/proposals/:id/dismiss", auth, async (c) => ok(c, await cog(c).dismiss(ownerOf(c), parseOr(UUID, c.req.param("id")))));
}
