import type { Context, Hono } from "hono";
import { z } from "zod";
import { serviceHeaders, type Config } from "../bootstrap/config";
import {
  PACE_FROM_MIN,
  pacePush,
  pacing,
  prevMonth,
  proposeBudgets,
  realisticPush,
  recurringMonthly,
  addDays,
  vnd,
  type BudgetNow,
  type CategoryRef,
  type HistoryRow,
  type PacingResult,
  type PastOutcome,
  type ProposalResult,
} from "../modules/budgets/plan";
import { implementedCommand } from "../modules/ledger/command-schemas";
import type { CommandContext, FinanceGateway } from "../modules/ledger/ports";
import { sendPush } from "../modules/push/onesignal";
import { SupabaseRemindersGateway, type RemindersGateway } from "../modules/reminders/gateway";
import { localClock } from "../modules/reminders/schedule";
import { resolveSettings } from "../modules/reminders/settings";
import { canonicalJson, sha256Hex } from "../shared/canonical";
import { DomainError } from "../shared/errors";

// Self-adjusting budgets (D-026): proposals from real spending, one-tap apply, daily pacing ("mỗi ngày nên ~X"),
// a calm pacing push and the monthly auto-apply that keeps budgets going without the owner re-entering them.

export interface BudgetGateway {
  history(owner: string, from: string, to: string): Promise<HistoryRow[]>;
}

export class SupabaseBudgetGateway implements BudgetGateway {
  constructor(private readonly cfg: Config) {}
  async history(owner: string, from: string, to: string): Promise<HistoryRow[]> {
    const res = await fetch(`${this.cfg.supabaseUrl}/rest/v1/rpc/pf_budget_history`, {
      method: "POST",
      headers: serviceHeaders(this.cfg),
      body: JSON.stringify({ p_owner: owner, p_from: from, p_to: to }),
      signal: AbortSignal.timeout(this.cfg.dbTimeoutMs),
    });
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
      if (body.code !== "P0001") console.log(JSON.stringify({ op: "rpc_failed", rpc: "pf_budget_history", status: res.status, pg: body.code ?? null }));
      throw new DomainError(body.code === "P0001" && body.message ? body.message : "DB_ERROR");
    }
    const rows = (await res.json()) as { tx_id?: string; day: string; category_id: string; amount: string; recurring: boolean }[];
    return (rows ?? []).map((r) => ({ ...(r.tx_id ? { tx_id: r.tx_id } : {}), day: r.day, category_id: r.category_id, amount: Number(r.amount), recurring: Boolean(r.recurring) }));
  }
}

export interface BudgetDeps {
  cfg: Config;
  gw: FinanceGateway;
  pushFetch?: typeof fetch;
  rg?: RemindersGateway;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  bg?: BudgetGateway;
}

const bgOf = (d: BudgetDeps): BudgetGateway => d.bg ?? new SupabaseBudgetGateway(d.cfg);
const rgOf = (d: BudgetDeps): RemindersGateway => d.rg ?? new SupabaseRemindersGateway(d.cfg);

const MONTH = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/);

type BudgetJson = { id: string; category_id: string | null; category_name: string; icon?: string | null; limit_amount: string; carried?: string; spent: string; carryover?: boolean; version: number };

function toBudgetNow(b: BudgetJson): BudgetNow {
  return {
    id: b.id,
    category_id: b.category_id,
    category_name: b.category_name,
    icon: b.icon ?? null,
    limit: Number(b.limit_amount),
    carried: Number(b.carried ?? 0),
    spent: Number(b.spent),
    carryover: Boolean(b.carryover),
    version: b.version,
  };
}

async function readBudgets(d: BudgetDeps, owner: string, month: string): Promise<BudgetNow[]> {
  const raw = (await d.gw.readBudgets(owner, `${month}-01`)) as BudgetJson[] | null;
  return (Array.isArray(raw) ? raw : []).map(toBudgetNow);
}

async function readCategories(d: BudgetDeps, owner: string): Promise<CategoryRef[]> {
  const raw = (await d.gw.readCategories(owner)) as CategoryRef[] | null;
  return Array.isArray(raw) ? raw : [];
}

/** Proposals for `month` from the 90 days up to yesterday (local). */
export async function computeProposals(d: BudgetDeps, owner: string, month: string, now: Date): Promise<ProposalResult> {
  const today = localClock(now).date;
  const toDay = addDays(today, -1);
  const [rows, categories, existing, recurring, ...past] = await Promise.all([
    bgOf(d).history(owner, addDays(toDay, -89), toDay),
    readCategories(d, owner),
    readBudgets(d, owner, month),
    d.gw.readRecurring(owner, today).catch(() => []),
    ...[1, 2, 3].map((n) => readBudgets(d, owner, prevMonth(month, n)).then((list) => list.map((b) => ({ month: prevMonth(month, n), category_id: b.category_id, limit: b.limit + b.carried, spent: b.spent }) as PastOutcome))),
  ]);
  return proposeBudgets({
    month,
    toDay,
    rows,
    categories,
    existing,
    past: past.flat(),
    recurringMonthly: recurringMonthly(Array.isArray(recurring) ? (recurring as never[]) : []),
  });
}

/** Pacing of the current month's budgets with today's spending per category. */
export async function computePacing(d: BudgetDeps, owner: string, now: Date): Promise<PacingResult> {
  const today = localClock(now).date;
  const [budgets, rows, categories] = await Promise.all([
    readBudgets(d, owner, today.slice(0, 7)),
    bgOf(d).history(owner, today, today),
    readCategories(d, owner),
  ]);
  const todaySpent = new Map<string, number>();
  for (const r of rows) todaySpent.set(r.category_id, (todaySpent.get(r.category_id) ?? 0) + r.amount);
  return pacing({ today, budgets, todaySpent, categories });
}

/** Deterministic command id (UUID v4 layout) so a repeated apply / cron run replays instead of writing twice. */
export async function stableId(seed: string): Promise<string> {
  const h = await sha256Hex(seed);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${((parseInt(h[16]!, 16) & 0x3) | 0x8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/**
 * Writes the given limits for `month` through BUDGET_UPSERT (creates or updates with the current version). Unchanged
 * limits are skipped. Returns how many budgets were written.
 */
export async function applyBudgets(
  d: BudgetDeps,
  ctx: CommandContext,
  month: string,
  items: { category_id: string | null; limit: number; carryover?: boolean | undefined }[],
  seed: string,
): Promise<number> {
  const owner = ctx.ownerId;
  const current = new Map((await readBudgets(d, owner, month)).map((b) => [b.category_id ?? "*", b]));
  let n = 0;
  for (const it of items) {
    if (!(it.limit > 0)) continue;
    const cur = current.get(it.category_id ?? "*");
    if (cur && cur.limit === it.limit) continue;
    const commandId = await stableId(`moma-budget|${seed}|${owner}|${month}|${it.category_id ?? "*"}|${it.limit}|${cur?.version ?? 0}`);
    const command = implementedCommand.parse({
      command_id: commandId,
      command_type: "BUDGET_UPSERT",
      schema_version: 1,
      payload: {
        month,
        limit: String(it.limit),
        carryover: it.carryover ?? cur?.carryover ?? false,
        ...(it.category_id ? { category_id: it.category_id } : {}),
        ...(cur ? { expected_version: cur.version } : {}),
      },
    });
    const hash = await sha256Hex(canonicalJson({ owner, command }));
    await d.gw.executeCommand(ctx, commandId, hash, command);
    n++;
  }
  return n;
}

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}

export function registerBudgetRoutes(
  app: Hono<any>,
  getDeps: (env: any) => BudgetDeps,
  auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>,
  needDevice: (c: Context<any>) => string,
) {
  app.get("/v1/budgets/proposals", auth, async (c) => {
    const q = z.object({ month: MONTH.optional() }).safeParse(c.req.query());
    if (!q.success) throw new DomainError("VALIDATION_FAILED");
    const now = new Date();
    return ok(c, await computeProposals(getDeps(c.env), (c as any).get("owner"), q.data.month ?? localClock(now).month, now));
  });

  app.post("/v1/budgets/proposals/apply", auth, async (c) => {
    const deviceId = needDevice(c);
    const body = z
      .object({
        month: MONTH.optional(),
        items: z.array(z.object({ category_id: z.string().uuid().nullable(), limit: z.string().regex(/^[0-9]{1,16}$/) })).min(1).max(60),
      })
      .safeParse(await c.req.json().catch(() => null));
    if (!body.success) throw new DomainError("VALIDATION_FAILED");
    const owner = (c as any).get("owner") as string;
    const month = body.data.month ?? localClock(new Date()).month;
    const ctx: CommandContext = { ownerId: owner, sessionId: (c as any).get("session").sessionId, deviceId };
    const applied = await applyBudgets(
      getDeps(c.env),
      ctx,
      month,
      body.data.items.map((i) => ({ category_id: i.category_id, limit: Number(i.limit) })),
      "apply",
    );
    return ok(c, { month, applied });
  });

  app.get("/v1/budgets/pacing", auth, async (c) => {
    return ok(c, await computePacing(getDeps(c.env), (c as any).get("owner"), new Date()));
  });
}

function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "scheduled", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

/**
 * Cron part of the budgets (never throws, every push claimed once):
 * 1. New month without budgets but budgets last month -> write this month's limits from fresh proposals (same
 *    categories, habits-adjusted) and tell the owner once.
 * 2. One pacing push a day for the category clearly running ahead; one "đặt mức thực tế" suggestion a month for a
 *    category that keeps going over (instead of nagging).
 */
export async function runBudgetCron(d: BudgetDeps, owner: string, now: Date): Promise<string[]> {
  const done: string[] = [];
  const clock = localClock(now);
  if (clock.minutes < 7 * 60 || clock.minutes >= 23 * 60) return done;
  const rg = rgOf(d);
  let settings;
  try {
    settings = resolveSettings(await rg.settingsRead(owner));
  } catch (e) {
    logFailure("budget.settings", e);
    return done;
  }
  const pushOn = Boolean(d.cfg.onesignalRestKey);
  const send = (title: string, body: string, data: Record<string, unknown>) =>
    sendPush(d.cfg, d.pushFetch ?? fetch, { ownerId: owner, title, body, data, androidGroup: "moma_budget" });

  let proposals: ProposalResult | null = null;
  const proposalsOnce = async () => (proposals ??= await computeProposals(d, owner, clock.month, now));

  if (settings.budget_auto.enabled) {
    try {
      const [thisMonth, lastMonth] = await Promise.all([readBudgets(d, owner, clock.month), readBudgets(d, owner, prevMonth(clock.month))]);
      if (thisMonth.length === 0 && lastMonth.length > 0 && (await rg.pushClaim(owner, `budget_auto:${clock.month}`))) {
        const p = await proposalsOnce();
        const by = new Map([...p.items, ...(p.total ? [p.total] : [])].map((i) => [i.category_id ?? "*", i.proposed]));
        const items = lastMonth.map((b) => ({ category_id: b.category_id, limit: by.get(b.category_id ?? "*") ?? b.limit, carryover: b.carryover }));
        // Cron has no session / device: pf_execute_command accepts a null device for server-initiated commands.
        const ctx = { ownerId: owner, sessionId: null, deviceId: null } as unknown as CommandContext;
        const n = await applyBudgets(d, ctx, clock.month, items, "auto");
        if (n > 0) {
          done.push(`budget_auto:${clock.month}`);
          if (pushOn) {
            const top = items
              .filter((i) => i.category_id)
              .sort((a, b) => b.limit - a.limit)
              .slice(0, 2)
              .map((i) => `${lastMonth.find((b) => b.category_id === i.category_id)?.category_name ?? ""} ${vnd(i.limit)}`)
              .join(", ");
            const [y, m] = clock.month.split("-");
            await send(`Đã đặt ngân sách tháng ${m}/${y}`, `Theo thói quen chi tiêu của bạn${top ? `: ${top}…` : ""} Chạm để xem hoặc chỉnh.`, {
              type: "budget_auto",
              month: clock.month,
              route: "/planning?tab=2",
            });
          }
        }
      }
    } catch (e) {
      logFailure("budget.auto", e);
    }
  }

  // Checked once an hour (first tick of the hour) to keep the cron light; each push is still claimed once.
  if (pushOn && settings.budget_pacing.enabled && clock.minutes >= PACE_FROM_MIN && clock.minutes % 60 < 15) {
    try {
      const p = await proposalsOnce();
      const chronic = new Set(p.chronic);
      const fix = realisticPush(p, { minutes: clock.minutes });
      if (fix && (await rg.pushClaim(owner, fix.key))) {
        await send(fix.title, fix.body, fix.data);
        done.push(fix.key);
      }
      const pace = pacePush(await computePacing(d, owner, now), { date: clock.date, minutes: clock.minutes, chronic });
      if (pace && (await rg.pushClaim(owner, pace.key))) {
        await send(pace.title, pace.body, pace.data);
        done.push(pace.key);
      }
    } catch (e) {
      logFailure("budget.pace", e);
    }
  }
  return done;
}
