import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runScheduled } from "../../src/entrypoints/routes-insights";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Smart reminders + insights against the real API code, PostgREST and Postgres (migration 008).
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let aiApp: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
const env = {} as never;
const pushes: any[] = [];
const fakePush = (async (_url: unknown, init?: RequestInit) => {
  pushes.push(JSON.parse(String(init?.body)));
  return new Response(JSON.stringify({ id: "n" }), { status: 200 });
}) as typeof fetch;
const aiOutput = JSON.stringify({
  title: "Hôm nay chi tiêu hợp lý",
  summary: "Bạn chi chủ yếu cho ăn uống. Mức chi trong tầm kiểm soát.",
  highlights: ["Ăn uống là khoản lớn nhất"],
  suggestions: ["Mang cơm trưa 2 ngày trong tuần", "Đặt mức chi ăn uống cố định"],
});
const deps = (withAi: boolean) => ({
  cfg,
  gw: new SupabaseFinanceGateway(cfg),
  verifier: new SessionVerifier(cfg),
  pushFetch: fakePush,
  ...(withAi ? { ai: async () => ({ content: aiOutput, usage: { prompt_tokens: 500, completion_tokens: 150 } }) } : {}),
});

async function call(method: string, path: string, body?: unknown, a = app) {
  const headers: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` };
  const res = await a.request(path, { method, headers, body: body === undefined ? null : JSON.stringify(body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const res = await app.request(
    "/v1/commands",
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, "idempotency-key": id },
      body: JSON.stringify({ command_id: id, command_type: type, schema_version: 1, payload }),
    },
    env,
  );
  const json = (await res.json()) as { data?: any };
  expect(res.status).toBe(200);
  return json.data;
}

const localToday = () => new Date(Date.now() + 7 * 3_600_000).toISOString().slice(0, 10);

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000, onesignalRestKey: "push-key", cronSecret: "e2e-cron-secret" };
  app = buildApp(() => deps(false));
  aiApp = buildApp(() => deps(true));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Sâm" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("reminders", () => {
  let cash = "";
  let food = "";
  let move = "";

  it("is quiet before any account exists", async () => {
    expect(await runScheduled(deps(false), new Date(`${localToday()}T21:45:00+07:00`))).toEqual([]);
    expect(pushes).toHaveLength(0);
  });

  it("serves default settings and saves a partial update", async () => {
    const d = await call("GET", "/v1/reminders/settings");
    expect(d.status).toBe(200);
    expect(d.json.data).toEqual({
      meals: { breakfast: { enabled: true, time: "09:30" }, lunch: { enabled: true, time: "13:00" }, dinner: { enabled: true, time: "20:00" } },
      cash_check: { enabled: true, time: "21:30" },
      daily_review: { enabled: true, time: "22:00" },
      weekly_review: { enabled: true, weekday: 7, time: "20:00" },
      monthly_review: { enabled: true, time: "20:00" },
      budget_alerts: { enabled: true },
    });
    const put = await call("PUT", "/v1/reminders/settings", { ...d.json.data, meals: { ...d.json.data.meals, lunch: { enabled: true, time: "12:30" } } });
    expect(put.status).toBe(200);
    expect(put.json.data.meals.lunch.time).toBe("12:30");
    expect((await call("GET", "/v1/reminders/settings")).json.data.meals.lunch.time).toBe("12:30");
    const bad = await call("PUT", "/v1/reminders/settings", { cash_check: { time: "9:7" } });
    expect(bad.status).toBe(400);
    expect(bad.json.error?.code).toBe("VALIDATION_FAILED");
  });

  it("reports today's meals and skips", async () => {
    const acc = await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Ví", name: "Tiền mặt", opening_amount: "3000000", baseline_at: "2026-10-01T00:00:00Z" });
    cash = acc.account_id;
    const cats = (await call("GET", "/v1/categories")).json.data as any[];
    food = cats.find((c) => c.name === "Ăn uống").id;
    move = cats.find((c) => c.name === "Di chuyển").id;
    await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: "35000", effective_at: "2026-11-20T00:30:00Z", category_id: food });

    const t = await call("GET", "/v1/reminders/today");
    expect(t.status).toBe(200);
    expect(t.json.data.date).toBe(localToday());
    expect(Object.keys(t.json.data.done).sort()).toEqual(["breakfast", "dinner", "lunch"]);

    const s = await call("POST", "/v1/reminders/skip", { kind: "lunch", date: "2026-11-20", skip: true });
    expect(s.status).toBe(200);
    expect(s.json.data).toEqual({ date: "2026-11-20", skipped: ["lunch"], done: { breakfast: true, lunch: false, dinner: false } });
    const un = await call("POST", "/v1/reminders/skip", { kind: "lunch", date: "2026-11-20", skip: false });
    expect(un.json.data.skipped).toEqual([]);
    expect((await call("POST", "/v1/reminders/skip", { kind: "snack", skip: true })).status).toBe(400);
    expect((await call("POST", "/v1/reminders/skip", { kind: "lunch", date: "2026-02-30", skip: true })).status).toBe(400);
  });

  it("runs insights with rules, reuses within the cooldown, lists and reads them", async () => {
    const r = await call("POST", "/v1/insights/run", { period: "WEEK" });
    expect(r.status).toBe(200);
    const ins = r.json.data;
    expect(ins).toMatchObject({ period: "WEEK", reused: false, source: "rules" });
    expect(typeof ins.title).toBe("string");
    expect(ins.suggestions.length).toBeGreaterThanOrEqual(2);
    for (const k of ["income", "expense", "net", "prev_expense", "daily_avg"]) expect(ins.numbers[k]).toMatch(/^-?\d+$/);
    expect(ins.numbers.forecast_expense).toMatch(/^\d+$/);
    expect(Array.isArray(ins.numbers.by_category)).toBe(true);

    const again = await call("POST", "/v1/insights/run", { period: "WEEK" });
    expect(again.json.data).toMatchObject({ id: ins.id, reused: true });

    const list = await call("GET", "/v1/insights?period=WEEK&limit=5");
    expect(list.json.data.map((x: any) => x.id)).toEqual([ins.id]);
    const one = await call("GET", `/v1/insights/${ins.id}`);
    expect(one.json.data).toMatchObject({ id: ins.id, title: ins.title, period_start: ins.period_start });
    expect((await call("GET", `/v1/insights/${crypto.randomUUID()}`)).status).toBe(404);
    expect((await call("GET", "/v1/insights/not-a-uuid")).status).toBe(400);
    expect((await call("POST", "/v1/insights/run", { period: "YEAR" })).status).toBe(400);
  });

  it("uses DeepSeek wording through the budget guard when AI is on", async () => {
    const r = await call("POST", "/v1/insights/run", { period: "MONTH" }, aiApp);
    expect(r.status).toBe(200);
    expect(r.json.data).toMatchObject({ period: "MONTH", source: "ai", title: "Hôm nay chi tiêu hợp lý" });
    expect(r.json.data.suggestions).toContain("Mang cơm trưa 2 ngày trong tuần");
    const usage = await h.db.query("select state from pf_ai_usage where owner_id = $1", [owner]);
    expect(usage.rows.map((x) => x.state)).toContain("SETTLED");
  });

  it("scheduled run: meal + cash check + budget alert once, then the daily review with its insight", async () => {
    const today = localToday();
    // 90% of a small transport budget this month (not a meal)
    await cmd("BUDGET_UPSERT", { month: today.slice(0, 7), limit: "100000", carryover: false, category_id: move });
    await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: "90000", effective_at: new Date().toISOString(), category_id: move });
    const budgetId = ((await call("GET", "/v1/budgets")).json.data as any[])[0].id;

    pushes.length = 0;
    const first = await runScheduled(deps(false), new Date(`${today}T21:45:00+07:00`));
    expect(first).toEqual(expect.arrayContaining([`meal:dinner:${today}`, `cash_check:${today}`, `budget:${budgetId}:80:${today.slice(0, 7)}`]));
    const dinner = pushes.find((p) => p.data?.kind === "dinner");
    expect(dinner).toMatchObject({
      headings: { vi: "Bạn ăn tối chưa?" },
      include_aliases: { external_id: [owner] },
      data: { type: "reminder", kind: "dinner", route: "/quick-entry" },
      buttons: [{ id: "skip_dinner", text: "Hôm nay không ăn" }, { id: "log", text: "Ghi ngay" }],
    });
    expect(pushes.find((p) => p.data?.kind === "cash_check")).toMatchObject({ headings: { vi: "Kiểm tra tiền mặt cuối ngày" }, data: { route: "/accounts" } });
    expect(pushes.find((p) => p.data?.type === "budget")?.headings.vi).toBe("Sắp hết ngân sách Di chuyển");

    const n = pushes.length;
    expect(await runScheduled(deps(false), new Date(`${today}T21:50:00+07:00`))).toEqual([]); // claimed: nothing twice
    expect(pushes.length).toBe(n);

    const second = await runScheduled(deps(false), new Date(`${today}T22:05:00+07:00`));
    expect(second).toContain(`review:day:${today}`);
    const review = pushes.find((p) => p.data?.type === "insight" && p.data?.period === "DAY");
    expect(review.data.route).toBe(`/insights/${review.data.id}`);
    const ins = await call("GET", `/v1/insights/${review.data.id}`);
    expect(ins.status).toBe(200);
    expect(ins.json.data.title).toBe(review.headings.vi);
    expect(await runScheduled(deps(false), new Date(`${today}T22:20:00+07:00`))).toEqual([]);
    const claims = await h.db.query("select key from pf_push_log where owner_id = $1", [owner]);
    expect(claims.rows.map((r) => r.key)).toContain(`budget:${budgetId}:80:${today.slice(0, 7)}`);
  });

  it("skipped meals are not reminded", async () => {
    const today = localToday();
    await call("POST", "/v1/reminders/skip", { kind: "breakfast", skip: true });
    pushes.length = 0;
    const r = await runScheduled(deps(false), new Date(`${today}T09:45:00+07:00`));
    expect(r).not.toContain(`meal:breakfast:${today}`);
    expect(pushes.filter((p) => p.data?.kind === "breakfast")).toEqual([]);
  });

  it("internal tick: secret required, same scheduler, idempotent", async () => {
    const tick = (secret?: string) =>
      app.request("/v1/internal/tick", { method: "POST", headers: secret ? { "x-cron-secret": secret } : {} }, env);
    expect((await tick()).status).toBe(401);
    expect((await tick("wrong")).status).toBe(401);
    const first = await tick("e2e-cron-secret");
    expect(first.status).toBe(200);
    const s1 = ((await first.json()) as any).data;
    expect(s1).toEqual({ processed: expect.any(Number), meals: expect.any(Number), cash_check: expect.any(Number), reviews: expect.any(Number), budget_alerts: expect.any(Number) });
    const second = ((await (await tick("e2e-cron-secret")).json()) as any).data;
    expect(second.processed).toBe(0);
  });
});
