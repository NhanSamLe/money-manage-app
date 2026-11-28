import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import type { FinanceGateway } from "../modules/ledger/ports";
import {
  EVENT_KINDS,
  HISTORY_DAYS,
  actualWindow,
  collectActual,
  compareActual,
  estimateEvent,
  inferKind,
  shortVnd,
  vnd,
  type Estimate,
  type EventKind,
  type PastEvent,
  type SpendRow,
} from "../modules/plans/estimate";
import { SupabasePlanGateway, type EventPlanJson, type LifePlanJson, type PlanGateway, type SpendRowJson } from "../modules/plans/gateway";
import {
  DEFAULT_MARKET,
  LIFE_KINDS,
  inferLifeKind,
  lifeDefaults,
  monthLabel,
  projectPlan,
  savingsBaseline,
  type Baseline,
  type LifeKind,
  type MarketAssumptions,
  type Projection,
  type Wealth,
} from "../modules/plans/project";
import { sendPush } from "../modules/push/onesignal";
import { DomainError } from "../shared/errors";

// Kế hoạch & Dự toán (migration 021, D-027): event estimates + plan vs actual, life-plan projections, the cron step
// (day-before reminder, in-event alert, close + "Thực tế vs Dự toán", monthly life-plan line) and the helpers the
// assistant uses. Every computation is bounded (Workers free plan: 10 ms CPU): ≤ 120 days of history, ≤ 1200 rows.

export interface PlanDeps {
  cfg: Config;
  gw: FinanceGateway;
  pushFetch?: typeof fetch;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  pg?: PlanGateway;
  market?: MarketAssumptions;
}

export const pgOf = (d: PlanDeps): PlanGateway => d.pg ?? new SupabasePlanGateway(d.cfg);

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
  console.log(JSON.stringify({ op: "plans", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

// ---------------------------------------------------------------- input
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

export const EventBody = z.object({
  id: z.string().uuid().optional(),
  title: z.string().trim().min(1).max(120),
  kind: z.enum(EVENT_KINDS as [EventKind, ...EventKind[]]).optional(),
  date: z.string().regex(DATE_RE).optional(),
  time: z.string().regex(TIME_RE).optional(),
  starts_at: z.string().datetime({ offset: true }).optional(),
  ends_at: z.string().datetime({ offset: true }).optional(),
  hours: z.number().min(0.5).max(744).optional(),
  headcount: z.number().int().min(1).max(500).optional(),
  people: z.array(z.string().trim().min(1).max(80)).max(50).optional(),
  place: z.string().trim().max(120).optional(),
  owner_pays: z.boolean().optional(),
  transport: z.enum(["GRAB", "OWN", "NONE"]).optional(),
  note: z.string().trim().max(300).optional(),
});
export type EventBodyT = z.infer<typeof EventBody>;

const DEFAULT_TIME: Record<EventKind, string> = { NHAU: "19:00", AN_UONG: "18:30", CAFE: "15:00", TIEC: "18:00", SINH_NHAT: "18:30", DU_LICH: "07:00", KHAC: "18:00" };
const DEFAULT_HOURS: Record<EventKind, number> = { NHAU: 4, AN_UONG: 2, CAFE: 2, TIEC: 5, SINH_NHAT: 4, DU_LICH: 48, KHAC: 3 };

export function vnToday(now: Date = new Date()): string {
  return new Date(now.getTime() + 7 * 3_600_000).toISOString().slice(0, 10);
}

/** Times + kind + headcount of an event request (Vietnam local date/time when no ISO time is given). */
export function resolveEvent(b: EventBodyT, now: Date = new Date()) {
  const kind: EventKind = b.kind ?? inferKind(`${b.title} ${b.note ?? ""} ${b.place ?? ""}`);
  const starts = b.starts_at
    ? new Date(b.starts_at).toISOString()
    : new Date(`${b.date ?? vnToday(now)}T${b.time ?? DEFAULT_TIME[kind]}:00+07:00`).toISOString();
  const hours = b.hours ?? DEFAULT_HOURS[kind];
  const ends = b.ends_at ? new Date(b.ends_at).toISOString() : new Date(Date.parse(starts) + hours * 3_600_000).toISOString();
  if (Date.parse(ends) <= Date.parse(starts)) throw new DomainError("VALIDATION_FAILED");
  const people = (b.people ?? []).filter((p) => !/^(t[oô]i|m[iì]nh|b[aạ]n|me|self)$/i.test(p));
  const headcount = b.headcount ?? (people.length ? people.length + 1 : kind === "TIEC" ? 20 : kind === "SINH_NHAT" ? 6 : 1);
  return { kind, starts, ends, headcount, people };
}

// ---------------------------------------------------------------- estimation + actuals
export const toRows = (xs: SpendRowJson[]): SpendRow[] => xs.map((r) => ({ ...r, amount: Number(r.amount), owner_amount: Number(r.owner_amount) }));

export function pastEvents(plans: EventPlanJson[]): PastEvent[] {
  return plans
    .filter((p) => p.state === "DONE" && p.actual && p.estimate?.owner?.likely)
    .map((p) => ({ kind: p.kind as EventKind, estimated_owner: Number(p.estimate.owner.likely), actual_owner: Number(p.actual!.owner ?? 0) }));
}

export async function estimateFor(d: PlanDeps, owner: string, b: EventBodyT, now: Date = new Date()): Promise<{ estimate: Estimate; resolved: ReturnType<typeof resolveEvent> }> {
  const resolved = resolveEvent(b, now);
  const pg = pgOf(d);
  const to = now.toISOString();
  const from = new Date(now.getTime() - HISTORY_DAYS * 86_400_000).toISOString();
  const [rows, done] = await Promise.all([
    pg.spendRows(owner, from, to).catch(() => []),
    pg.eventList(owner, "DONE", new Date(now.getTime() - 365 * 86_400_000).toISOString(), to).catch(() => []),
  ]);
  const estimate = estimateEvent(
    { title: b.title, kind: resolved.kind, starts_at: resolved.starts, ends_at: resolved.ends, headcount: resolved.headcount, owner_pays: b.owner_pays, transport: b.transport },
    toRows(rows),
    pastEvents(done),
  );
  return { estimate, resolved };
}

export interface LiveActual {
  actual: ReturnType<typeof collectActual>;
  comparison: ReturnType<typeof compareActual>;
}

/** Money spent in the plan's window so far, compared with the estimate. */
export async function liveActual(d: PlanDeps, owner: string, p: EventPlanJson, now: Date = new Date()): Promise<LiveActual> {
  const w = actualWindow({ kind: p.kind as EventKind, starts_at: p.starts_at, ends_at: p.ends_at });
  // never beyond "now": an event in progress only counts what was spent so far
  const to = new Date(Math.min(Date.parse(w.to), now.getTime() + 60_000)).toISOString();
  if (Date.parse(to) <= Date.parse(w.from)) {
    const empty = collectActual({ kind: p.kind as EventKind, starts_at: p.starts_at, ends_at: p.ends_at }, []);
    return { actual: empty, comparison: compareActual({ owner: (p.estimate as Estimate).owner ?? { low: 0, likely: Number(p.budget ?? 0), high: 0 }, breakdown: (p.estimate as Estimate).breakdown ?? [], owner_pays: p.owner_pays, headcount: p.headcount }, empty) };
  }
  const rows = toRows(await pgOf(d).spendRows(owner, w.from, to)).filter((r) => Date.parse(r.at) <= now.getTime());
  const actual = collectActual({ kind: p.kind as EventKind, starts_at: p.starts_at, ends_at: p.ends_at }, rows);
  const est = p.estimate as Estimate;
  const comparison = compareActual(
    { owner: est.owner ?? { low: 0, likely: Number(p.budget ?? 0), high: 0 }, breakdown: est.breakdown ?? [], owner_pays: p.owner_pays, headcount: p.headcount },
    actual,
  );
  return { actual, comparison };
}

export async function saveEvent(d: PlanDeps, owner: string, b: EventBodyT, now: Date = new Date()): Promise<EventPlanJson & { live?: LiveActual }> {
  const { estimate, resolved } = await estimateFor(d, owner, b, now);
  return pgOf(d).eventUpsert(owner, {
    ...(b.id ? { id: b.id } : {}),
    title: b.title,
    kind: resolved.kind,
    starts_at: resolved.starts,
    ends_at: resolved.ends,
    headcount: estimate.headcount,
    people: resolved.people,
    place: b.place ?? "",
    owner_pays: estimate.owner_pays,
    transport: estimate.transport,
    note: b.note ?? "",
    estimate,
    budget: String(estimate.owner.likely),
  });
}

// ---------------------------------------------------------------- life plans
export const LifeBody = z.object({
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1).max(120),
  kind: z.enum(LIFE_KINDS as [LifeKind, ...LifeKind[]]).optional(),
  price: z.number().int().positive().max(1_000_000_000_000),
  down_pct: z.number().gt(0).max(100).optional(),
  loan_rate_pct: z.number().min(0).max(30).optional(),
  loan_years: z.number().int().min(0).max(35).optional(),
  inflation_pct: z.number().min(-5).max(30).optional(),
  income_growth_pct: z.number().min(-20).max(50).optional(),
  extra_saving: z.number().int().min(-1_000_000_000).max(1_000_000_000).optional(),
  goal_id: z.string().uuid().nullable().optional(),
  target_date: z.string().regex(DATE_RE).nullable().optional(),
});
export type LifeBodyT = z.infer<typeof LifeBody>;

export interface PlanBaseline {
  baseline: Baseline;
  wealth: Wealth;
  months: { month: string; income: number; expense: number; partial: boolean }[];
}

export async function baselineFor(d: PlanDeps, owner: string): Promise<PlanBaseline> {
  const pg = pgOf(d);
  const [m, w] = await Promise.all([pg.months(owner, 12), pg.wealth(owner)]);
  const months = m.map((x) => ({ month: x.month, income: Number(x.income), expense: Number(x.expense), partial: x.partial }));
  const wealth: Wealth = {
    assets: Number(w.assets),
    liabilities: Number(w.liabilities),
    receivable: Number(w.receivable),
    payable: Number(w.payable),
    goals: w.goals.map((g) => ({ id: g.id, name: g.name, target: Number(g.target), allocated: Number(g.allocated) })),
  };
  return { baseline: savingsBaseline(months, wealth), wealth, months };
}

/** Normalised life-plan parameters: kind inferred, sensible defaults for down payment / loan by kind. */
export function lifeParams(b: LifeBodyT) {
  const kind = b.kind ?? inferLifeKind(b.name);
  const dflt = lifeDefaults(kind, b.price);
  return {
    name: b.name,
    kind,
    price: b.price,
    down_pct: b.down_pct ?? dflt.down_pct,
    loan_rate_pct: b.loan_rate_pct ?? null,
    loan_years: b.loan_years ?? dflt.loan_years,
    inflation_pct: b.inflation_pct ?? null,
    income_growth_pct: b.income_growth_pct ?? null, // null = market default (keeps pace with inflation)
    extra_saving: b.extra_saving ?? 0,
    goal_id: b.goal_id ?? null,
    target_date: b.target_date ?? null,
  };
}

export function projectFor(p: ReturnType<typeof lifeParams> | LifePlanJson, base: PlanBaseline, d?: Pick<PlanDeps, "market">, now: Date = new Date()): Projection {
  const goal = p.goal_id ? base.wealth.goals.find((g) => g.id === p.goal_id) : undefined;
  return projectPlan(
    {
      name: p.name,
      kind: p.kind as LifeKind,
      price: Number(p.price),
      down_pct: Number(p.down_pct),
      loan_rate_pct: p.loan_rate_pct === null || p.loan_rate_pct === undefined ? null : Number(p.loan_rate_pct),
      loan_years: Number(p.loan_years),
      inflation_pct: p.inflation_pct === null || p.inflation_pct === undefined ? null : Number(p.inflation_pct),
      income_growth_pct: p.income_growth_pct === null || p.income_growth_pct === undefined ? null : Number(p.income_growth_pct),
      extra_saving: Number(p.extra_saving ?? 0),
      // a plan with its own goal counts what that goal holds; otherwise the owner's free money
      saved_now: goal ? goal.allocated : null,
    },
    base.baseline,
    now,
    d?.market ?? DEFAULT_MARKET,
  );
}

// ---------------------------------------------------------------- routes
export function registerPlanRoutes(app: Hono<any>, getDeps: (env: any) => PlanDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  app.post("/v1/plans/events/estimate", auth, async (c) => {
    const b = parseOr(EventBody, await c.req.json().catch(() => ({})));
    const { estimate, resolved } = await estimateFor(getDeps(c.env), ownerOf(c), b);
    return ok(c, { ...estimate, starts_at: resolved.starts, ends_at: resolved.ends });
  });

  app.post("/v1/plans/events", auth, async (c) => {
    const b = parseOr(EventBody, await c.req.json().catch(() => ({})));
    return ok(c, await saveEvent(getDeps(c.env), ownerOf(c), b));
  });

  app.get("/v1/plans/events", auth, async (c) => {
    const q = parseOr(z.object({ state: z.enum(["PLANNED", "DONE", "CANCELLED"]).optional() }), c.req.query());
    return ok(c, await pgOf(getDeps(c.env)).eventList(ownerOf(c), q.state ?? null, null, null));
  });

  app.get("/v1/plans/events/:id", auth, async (c) => {
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const p = await pgOf(d).eventGet(owner, id);
    // started and not closed yet: show the money spent so far against the estimate
    const live = p.state === "PLANNED" && Date.parse(p.starts_at) - 3_600_000 <= Date.now() ? await liveActual(d, owner, p).catch(() => undefined) : undefined;
    return ok(c, { ...p, ...(live ? { live } : {}) });
  });

  app.post("/v1/plans/events/:id/cancel", auth, async (c) => {
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    return ok(c, await pgOf(getDeps(c.env)).eventClose(ownerOf(c), id, "CANCELLED", null));
  });

  // Close now (or refresh a closed one): the actual spend becomes the plan's "Thực tế".
  app.post("/v1/plans/events/:id/close", auth, async (c) => {
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const p = await pgOf(d).eventGet(owner, id);
    const live = await liveActual(d, owner, p);
    return ok(c, await pgOf(d).eventClose(owner, id, "DONE", { ...live.actual, comparison: live.comparison }));
  });

  app.get("/v1/plans/baseline", auth, async (c) => ok(c, await baselineFor(getDeps(c.env), ownerOf(c))));

  app.post("/v1/plans/life/project", auth, async (c) => {
    const b = parseOr(LifeBody, await c.req.json().catch(() => ({})));
    const d = getDeps(c.env);
    const params = lifeParams(b);
    return ok(c, { plan: params, projection: projectFor(params, await baselineFor(d, ownerOf(c)), d) });
  });

  app.get("/v1/plans/life", auth, async (c) => {
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const [plans, base] = await Promise.all([pgOf(d).lifeList(owner), baselineFor(d, owner)]);
    return ok(c, { baseline: base.baseline, plans: plans.map((p) => ({ ...p, projection: projectFor(p, base, d) })) });
  });

  app.post("/v1/plans/life", auth, async (c) => {
    const b = parseOr(LifeBody, await c.req.json().catch(() => ({})));
    const d = getDeps(c.env);
    const owner = ownerOf(c);
    const params = lifeParams(b);
    const saved = await pgOf(d).lifeUpsert(owner, { ...(b.id ? { id: b.id } : {}), ...params });
    return ok(c, { ...saved, projection: projectFor(saved, await baselineFor(d, owner), d) });
  });

  app.delete("/v1/plans/life/:id", auth, async (c) => {
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    return ok(c, await pgOf(getDeps(c.env)).lifeDelete(ownerOf(c), id));
  });
}

// ---------------------------------------------------------------- cron
function vnHourOf(now: Date): number {
  return new Date(now.getTime() + 7 * 3_600_000).getUTCHours();
}
const quiet = (now: Date) => {
  const h = vnHourOf(now);
  return h >= 23 || h < 7;
};

async function push(d: PlanDeps, owner: string, title: string, body: string, route: string) {
  await sendPush(d.cfg, d.pushFetch ?? fetch, { ownerId: owner, title, body, data: { type: "plan", route }, androidGroup: "moma_plans" }).catch(() => false);
}

/** The best funded spending account (name + balance) for "VCB còn đủ". */
export function bestAccount(raw: unknown): { name: string; balance: number } | null {
  if (!Array.isArray(raw)) return null;
  let best: { name: string; balance: number } | null = null;
  for (const a of raw as Record<string, unknown>[]) {
    if (a.archived || a.hidden || !["BANK", "WALLET", "CASH"].includes(String(a.kind)) || a.balance === null || a.balance === undefined) continue;
    const bal = Number(a.balance);
    if (Number.isFinite(bal) && (!best || bal > best.balance)) best = { name: String(a.name), balance: bal };
  }
  return best;
}

/** "Mai đi nhậu với Nam: dự kiến ~850k (bạn ~350k) · VCB còn 2,1tr, đủ". */
export function reminderText(p: EventPlanJson, acc: { name: string; balance: number } | null, now: Date) {
  const est = p.estimate as Partial<Estimate>;
  const ownerLikely = Number(est.owner?.likely ?? p.budget ?? 0);
  const total = Number(est.total?.likely ?? ownerLikely);
  const day = vnToday(new Date(Date.parse(p.starts_at))) === vnToday(now) ? "Hôm nay" : "Ngày mai";
  const share = total !== ownerLikely ? ` (bạn ~${shortVnd(ownerLikely)})` : "";
  let money = "";
  if (acc) money = acc.balance >= ownerLikely ? ` · ${acc.name} còn ${shortVnd(acc.balance)}, đủ` : ` · ${acc.name} chỉ còn ${shortVnd(acc.balance)}, nên chuẩn bị thêm`;
  return { title: `${day}: ${p.title}`, body: `Dự kiến ~${shortVnd(total)}${share}${money}` };
}

/** Day-before reminder, in-event alert, close after the event + "Thực tế vs Dự toán", monthly life-plan line. */
export async function runPlanSweep(d: PlanDeps, now: Date = new Date()): Promise<{ reminded: number; alerted: number; closed: number; monthly: boolean } | null> {
  try {
    const owner = await d.gw.getOwnerId();
    if (!owner) return null;
    const pg = pgOf(d);
    const out = { reminded: 0, alerted: 0, closed: 0, monthly: false };
    if (quiet(now)) return out; // closing waits for the morning too, so its push is never held back
    const t = now.getTime();
    const open = await pg.eventList(owner, "PLANNED", new Date(t - 7 * 86_400_000).toISOString(), new Date(t + 36 * 3_600_000).toISOString());
    let accounts: unknown = null;
    for (const p of open.slice(0, 10)) {
      try {
        const s = Date.parse(p.starts_at);
        const e = Date.parse(p.ends_at);
        if (t >= e + 8 * 3_600_000) {
          const live = await liveActual(d, owner, p, now);
          await pg.eventClose(owner, p.id, "DONE", { ...live.actual, comparison: live.comparison });
          out.closed++;
          if (await pg.pushClaim(owner, `plan-done:${p.id}`)) await push(d, owner, `Thực tế vs Dự toán: ${p.title}`, live.comparison.summary, `/plans/event/${p.id}`);
        } else if (t < s - 3 * 3_600_000 && t >= s - 30 * 3_600_000 && !p.reminded_at) {
          if (await pg.eventMark(owner, p.id, "REMINDED")) {
            accounts ??= await d.gw.readAccounts(owner).catch(() => null);
            const r = reminderText(p, bestAccount(accounts), now);
            await push(d, owner, r.title, r.body, `/plans/event/${p.id}`);
            out.reminded++;
          }
        } else if (t >= s && t <= e + 3 * 3_600_000 && !p.alerted_at && Number(p.budget ?? 0) > 0) {
          const live = await liveActual(d, owner, p, now);
          const budget = Number(p.budget);
          if (live.actual.owner >= budget * 0.85 && (await pg.eventMark(owner, p.id, "ALERTED"))) {
            await push(d, owner, p.title, `Đã chi ${shortVnd(live.actual.owner)}/${shortVnd(budget)} dự toán`, `/plans/event/${p.id}`);
            out.alerted++;
          }
        }
      } catch (e) {
        logFailure("event", e);
      }
    }
    // Monthly life-plan progress: the 1st, from 09:00, once per month.
    const vn = new Date(t + 7 * 3_600_000);
    if (vn.getUTCDate() === 1 && vn.getUTCHours() >= 9) {
      try {
        const plans = await pg.lifeList(owner);
        if (plans.length && (await pg.pushClaim(owner, `plan-month:${vn.toISOString().slice(0, 7)}`))) {
          const base = await baselineFor(d, owner);
          const lines = plans.slice(0, 3).map((p) => {
            const pr = projectFor(p, base, d, now);
            return `${p.name}: ${pr.reachable ? `dự kiến ~${monthLabel(pr.reach_month)}` : "chưa đủ tích lũy"}`;
          });
          await push(d, owner, "Tiến độ kế hoạch lớn", `${lines.join(" · ")} (tích lũy ~${shortVnd(Math.max(0, base.baseline.monthly_saving))}/tháng)`, "/plans");
          out.monthly = true;
        }
      } catch (e) {
        logFailure("monthly", e);
      }
    }
    return out;
  } catch (e) {
    logFailure("sweep", e);
    return null;
  }
}

// ---------------------------------------------------------------- assistant
/** Lines of the chat card for an event estimate. */
export function estimateLines(e: Estimate): string[] {
  const lines = [e.summary, `Khoảng ${shortVnd(e.owner.low)}–${shortVnd(e.owner.high)} cho phần của bạn`];
  if (e.assumptions.length) lines.push(`Giả định: ${e.assumptions.slice(0, 2).join(" ")}`);
  return lines;
}

/**
 * Fills the assistant's plan actions before they reach the app: an event plan CALL gets its estimate as the card's
 * lines (the app then saves it with POST /plans/events, which re-computes the same estimate); a life plan CALL gets its
 * projection; ANSWER PLANS gets upcoming events + life plans. Best effort: a failure keeps the card without numbers.
 */
export async function enrichPlanActions(d: PlanDeps, owner: string, result: { actions: any[] }, now: Date = new Date()): Promise<void> {
  let base: PlanBaseline | undefined;
  for (const a of result.actions) {
    try {
      if (a.type === "CALL" && typeof a.call?.path === "string" && a.call.path.startsWith("/plans/events")) {
        const b = EventBody.safeParse(a.call.body ?? {});
        if (!b.success) continue;
        const { estimate } = await estimateFor(d, owner, b.data, now);
        a.lines = estimateLines(estimate);
      } else if (a.type === "CALL" && a.call?.path === "/plans/life") {
        const b = LifeBody.safeParse(a.call.body ?? {});
        if (!b.success) continue;
        base ??= await baselineFor(d, owner);
        const pr = projectFor(lifeParams(b.data), base, d, now);
        a.lines = [pr.summary, ...pr.what_if.filter((w) => w.reach_month).slice(0, 2).map((w) => `${w.label} → ${monthLabel(w.reach_month)}`)];
      } else if (a.type === "ANSWER" && a.what === "PLANS") {
        const pg = pgOf(d);
        base ??= await baselineFor(d, owner);
        const [events, life] = await Promise.all([
          pg.eventList(owner, null, new Date(now.getTime() - 14 * 86_400_000).toISOString(), null),
          pg.lifeList(owner),
        ]);
        a.data = {
          events: events.slice(0, 8).map((p) => ({
            id: p.id, title: p.title, starts_at: p.starts_at, state: p.state,
            estimate: Number(p.estimate?.owner?.likely ?? p.budget ?? 0),
            actual: p.actual ? Number(p.actual.owner ?? 0) : null,
            summary: p.actual?.comparison?.summary ?? null,
          })),
          life: life.slice(0, 5).map((p) => {
            const pr = projectFor(p, base!, d, now);
            return { id: p.id, name: p.name, reach_month: pr.reach_month, summary: pr.summary };
          }),
          monthly_saving: base.baseline.monthly_saving,
        };
      }
    } catch (e) {
      logFailure("agent", e);
    }
  }
}

/** "~850.000đ" helper re-exported for the assistant prompt/tests. */
export { vnd };
