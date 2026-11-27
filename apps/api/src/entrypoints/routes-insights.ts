import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import type { FinanceGateway } from "../modules/ledger/ports";
import { MODEL, MONTHLY_CAP_MICRO, actualMicro, buildRequestBody, estimateMicro, parseModelJson, type ProviderCall } from "../modules/ai/assistant";
import {
  COOLDOWN_MS,
  INSIGHT_MAX_OUTPUT_TOKENS,
  buildInsightMessages,
  computeNumbers,
  ensureLimitSuggestion,
  parseAiText,
  periodBounds,
  periodLabel,
  ruleText,
  type BudgetInput,
  type InsightText,
} from "../modules/insights/analysis";
import { sendPush } from "../modules/push/onesignal";
import { SupabaseRemindersGateway, type RemindersGateway } from "../modules/reminders/gateway";
import { decidePushes, localClock, type BudgetRow, type Period } from "../modules/reminders/schedule";
import { ReminderSettingsPatch, resolveSettings } from "../modules/reminders/settings";
import { DomainError } from "../shared/errors";
import type { MemoryGateway } from "../modules/ai/memory-gateway";
import { REFLECT_FROM_MIN, runReflection } from "./routes-memory";

// Smart reminders + spending insights: HTTP routes (registered from http.ts) and the cron entry (scheduled()).

export interface InsightDeps {
  cfg: Config;
  gw: FinanceGateway;
  ai?: ProviderCall;
  pushFetch?: typeof fetch;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  rg?: RemindersGateway;
  /** Assistant memory gateway (nightly reflection); defaults to the Supabase RPC gateway. */
  mg?: MemoryGateway;
}

const PERIOD = z.enum(["DAY", "WEEK", "MONTH"]);
const DATE = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/).refine((s) => !Number.isNaN(Date.parse(`${s}T00:00:00Z`)) && new Date(`${s}T00:00:00Z`).toISOString().startsWith(s));
const MEAL = z.enum(["breakfast", "lunch", "dinner"]);

const rgOf = (d: InsightDeps): RemindersGateway => d.rg ?? new SupabaseRemindersGateway(d.cfg);

function parseOr<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}
const ownerOf = (c: Context<any>): string => (c as any).get("owner");

function todayPayload(s: { date: string; skipped: string[]; done: Record<string, boolean> }) {
  return { date: s.date, skipped: s.skipped, done: { breakfast: Boolean(s.done.breakfast), lunch: Boolean(s.done.lunch), dinner: Boolean(s.done.dinner) } };
}

export function registerInsightRoutes(app: Hono<any>, getDeps: (env: any) => InsightDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  app.get("/v1/reminders/settings", auth, async (c) => {
    const d = getDeps(c.env);
    return ok(c, resolveSettings(await rgOf(d).settingsRead(ownerOf(c))));
  });

  app.put("/v1/reminders/settings", auth, async (c) => {
    const d = getDeps(c.env);
    const patch = parseOr(ReminderSettingsPatch, await c.req.json().catch(() => null));
    const rg = rgOf(d);
    const owner = ownerOf(c);
    const merged = resolveSettings(await rg.settingsRead(owner), patch);
    await rg.settingsWrite(owner, merged);
    return ok(c, merged);
  });

  app.get("/v1/reminders/today", auth, async (c) => {
    const d = getDeps(c.env);
    return ok(c, todayPayload(await rgOf(d).dayStatus(ownerOf(c), localClock(new Date()).date)));
  });

  app.post("/v1/reminders/skip", auth, async (c) => {
    const d = getDeps(c.env);
    const body = parseOr(z.object({ kind: MEAL, date: DATE.optional(), skip: z.boolean() }), await c.req.json().catch(() => null));
    const day = body.date ?? localClock(new Date()).date;
    return ok(c, todayPayload(await rgOf(d).skipSet(ownerOf(c), body.kind, day, body.skip)));
  });

  app.get("/v1/insights", auth, async (c) => {
    const d = getDeps(c.env);
    const q = parseOr(z.object({ period: PERIOD.optional(), limit: z.coerce.number().int().min(1).max(100).default(20) }), c.req.query());
    return ok(c, await rgOf(d).insightList(ownerOf(c), q.period ?? null, q.limit ?? 20));
  });

  app.get("/v1/insights/:id", auth, async (c) => {
    const d = getDeps(c.env);
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    return ok(c, await rgOf(d).insightGet(ownerOf(c), id));
  });

  app.post("/v1/insights/run", auth, async (c) => {
    const d = getDeps(c.env);
    const { period } = parseOr(z.object({ period: PERIOD }), await c.req.json().catch(() => null));
    return ok(c, await runInsight(d, ownerOf(c), period, new Date()));
  });

  // Fallback trigger for an external scheduler (the Cloudflare cron may be unavailable on the account). Same logic as
  // scheduled(); every push is claimed in pf_push_log, so cron + tick double triggering is harmless.
  app.post("/v1/internal/tick", async (c) => {
    const d = getDeps(c.env);
    if (!d.cfg.cronSecret) throw new DomainError("NOT_FOUND");
    if (!(await secretEquals(c.req.header("x-cron-secret") ?? "", d.cfg.cronSecret))) throw new DomainError("UNAUTHENTICATED");
    return ok(c, tickSummary(await runScheduled(d, new Date())));
  });
}

/** Constant-time comparison (both sides hashed first, so length differences leak nothing either). */
export async function secretEquals(given: string, expected: string): Promise<boolean> {
  const h = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([h(given), h(expected)]);
  let diff = given.length === 0 ? 1 : 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/** Counts only (no keys, ids or amounts). */
export function tickSummary(keys: string[]) {
  const n = (prefix: string) => keys.filter((k) => k.startsWith(prefix)).length;
  return { processed: keys.length, meals: n("meal:"), cash_check: n("cash_check:"), reviews: n("review:"), budget_alerts: n("budget:") };
}

/**
 * Computes (or reuses) the insight for the period containing `anchor` (default: today, local). A run for the same
 * period start created within the cooldown is returned as is with reused=true, so the cron never recomputes what the
 * owner just ran by hand.
 */
export async function runInsight(
  d: InsightDeps,
  owner: string,
  period: Period,
  now: Date,
  opts: { anchor?: string } = {},
): Promise<Record<string, unknown> & { id: string; title: string; summary: string; reused: boolean }> {
  const rg = rgOf(d);
  const today = localClock(now).date;
  const b = periodBounds(period, opts.anchor ?? today, today);
  const latest = await rg.insightLatest(owner, period);
  if (latest && latest.period_start === b.start && now.getTime() - Date.parse(String(latest.created_at)) < COOLDOWN_MS[period]) {
    return { ...(latest as any), reused: true };
  }
  const [cur, prev, hist, budgetsRaw] = await Promise.all([
    rg.periodStats(owner, b.start, b.asOf),
    rg.periodStats(owner, b.prevStart, b.prevEnd),
    rg.periodStats(owner, b.histStart, b.histEnd),
    d.gw.readBudgets(owner, `${b.start.slice(0, 7)}-01`),
  ]);
  const budgets = (Array.isArray(budgetsRaw) ? budgetsRaw : []) as BudgetInput[];
  const numbers = computeNumbers(b, cur, prev, hist, budgets);
  const { next } = periodLabel(b, today);
  let text: InsightText | null = null;
  let source = "rules";
  if (d.ai) {
    text = await aiWording(d, owner, () => buildInsightMessages(b, numbers, today, budgets), (raw) => parseAiText(raw, numbers, next));
    if (text) source = "ai";
  }
  text ??= ensureLimitSuggestion(ruleText(b, numbers, today, budgets), numbers, next);
  const created = await rg.insightCreate(owner, period, b.start, b.end, { ...text, numbers, source, as_of: now.toISOString() });
  return { ...(created as any), reused: false };
}

/** DeepSeek through the monthly budget guard. Any failure (over budget, provider down, bad output) -> null. */
async function aiWording<T>(
  d: InsightDeps,
  owner: string,
  build: () => { messages: unknown[]; bytes: number },
  parse: (raw: unknown) => T | null,
): Promise<T | null> {
  if (!d.ai) return null;
  try {
    const { messages, bytes } = build();
    const { id: reservation } = await d.gw.aiReserve(owner, estimateMicro(bytes, INSIGHT_MAX_OUTPUT_TOKENS), MONTHLY_CAP_MICRO, "deepseek", MODEL);
    let out;
    try {
      out = await d.ai({ ...buildRequestBody(messages, INSIGHT_MAX_OUTPUT_TOKENS), temperature: 0.3 });
    } catch {
      await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined);
      return null;
    }
    await d.gw.aiSettle(owner, reservation, actualMicro(out.usage)).catch(() => undefined);
    return parse(parseModelJson(out.content));
  } catch (e) {
    console.log(JSON.stringify({ op: "insight.ai", outcome: "fallback", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
    return null;
  }
}

function logFailure(step: string, e: unknown, key?: string) {
  console.log(JSON.stringify({ op: "scheduled", step, key, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

const short = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

/** One cron tick. Never throws; logs one JSON line per failure. Returns the keys that were pushed (or run). */
export async function runScheduled(d: InsightDeps, now: Date): Promise<string[]> {
  const done: string[] = [];
  try {
    const owner = await d.gw.getOwnerId();
    if (!owner) return done;
    const rg = rgOf(d);
    const clock = localClock(now);
    const settings = resolveSettings(await rg.settingsRead(owner).catch((e) => (logFailure("settings", e), null)));
    const status = await rg.dayStatus(owner, clock.date);
    let budgets: BudgetRow[] = [];
    if (settings.budget_alerts.enabled) {
      try {
        budgets = ((await d.gw.readBudgets(owner, `${clock.month}-01`)) as BudgetRow[]) ?? [];
      } catch (e) {
        logFailure("budgets", e);
      }
    }
    const pushOn = Boolean(d.cfg.onesignalRestKey);
    const send = (m: Parameters<typeof sendPush>[2]) => sendPush(d.cfg, d.pushFetch ?? fetch, m);
    for (const p of decidePushes({ now, settings, status, budgets })) {
      // Without push only the reviews are useful (the insight appears in the app); other reminders wait for push.
      if (!pushOn && p.type !== "review") continue;
      try {
        if (!(await rg.pushClaim(owner, p.key))) continue;
        if (p.type === "budget") for (const k of p.alsoClaim) await rg.pushClaim(owner, k);
        if (p.type === "review") {
          const ins = await runInsight(d, owner, p.period, now, { anchor: p.anchor });
          if (pushOn) {
            await send({
              ownerId: owner,
              title: short(ins.title, 80),
              body: short(ins.summary, 160),
              data: { type: "insight", id: ins.id, period: p.period, route: `/insights/${ins.id}` },
              androidGroup: "moma_insight",
            });
          }
        } else {
          await send({
            ownerId: owner,
            title: p.title,
            body: p.body,
            data: p.data,
            androidGroup: p.type === "budget" ? "moma_budget" : "moma_reminder",
            ...(p.type === "meal" ? { buttons: p.buttons } : {}),
          });
        }
        done.push(p.key);
      } catch (e) {
        logFailure(p.type, e, p.key);
      }
    }
    // Nightly reflection of the assistant's memory: once per local day after 23:00, claimed like a push (no push).
    if (clock.minutes >= REFLECT_FROM_MIN) {
      const key = `reflect:${clock.date}`;
      try {
        if (await rg.pushClaim(owner, key)) {
          await runReflection(d, owner);
          done.push(key);
        }
      } catch (e) {
        logFailure("reflect", e, key);
      }
    }
  } catch (e) {
    logFailure("run", e);
  }
  return done;
}
