import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runPlanSweep } from "../../src/entrypoints/routes-plans";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Kế hoạch & Dự toán (migration 021) against the real API code, PostgREST and Postgres: an estimate learned from the
// owner's own split bills and Grab rides, plan vs actual after the event, life-plan projections from real months.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
const env = {} as never;
let cash = "";
let food = "";
let move = "";
let salary = "";

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` }, body: body === undefined ? null : JSON.stringify(body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const res = await app.request(
    "/v1/commands",
    { method: "POST", headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, "idempotency-key": id }, body: JSON.stringify({ command_id: id, command_type: type, schema_version: 1, payload }) },
    env,
  );
  const j = (await res.json()) as any;
  expect(res.status, JSON.stringify(j)).toBe(200);
  return j.data;
}
const spend = (amount: number, at: Date, category: string, extra: Record<string, unknown> = {}) =>
  cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: String(amount), effective_at: at.toISOString(), category_id: category, ...extra });
/** Vietnam local date-time → Date. */
const vn = (s: string) => new Date(`${s}:00+07:00`);
/** Vietnam calendar date d days ago (negative = ahead). */
const vnDay = (d: number) => new Date(Date.now() + 7 * 3_600_000 - d * 86_400_000).toISOString().slice(0, 10);
const daysAgo = (d: number, hhmm: string) => {
  const day = new Date(Date.now() + 7 * 3_600_000 - d * 86_400_000).toISOString().slice(0, 10);
  return vn(`${day}T${hhmm}`);
};

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  cash = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Tiền mặt", opening_amount: "50000000", baseline_at: new Date(Date.now() - 200 * 86_400_000).toISOString() })).account_id;
  const cats = (await call("GET", "/v1/categories")).json.data as any[];
  const pick = (type: string, re: RegExp) => (cats.find((c) => c.type === type && re.test(c.name)) ?? cats.find((c) => c.type === type)).id as string;
  food = pick("EXPENSE", /ăn uống/i);
  move = pick("EXPENSE", /di chuyển/i);
  salary = pick("INCOME", /lương/i);
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("event plans", () => {
  it("estimate from the owner's split bills and Grab rides; Postgres normalises and flags the rows", async () => {
    // three earlier nights out: 1.200.000 split 4 ways (owner keeps 300.000), Grab rides 50k / 60k / 80k
    for (const [d, ride] of [[20, 50_000], [13, 60_000], [6, 80_000]] as const) {
      const bill = await spend(1_200_000, daysAgo(d, "20:00"), food, { merchant: "Quán nhậu Bờ Kè" });
      await cmd("SPLIT_APPLY", { tx_id: bill.tx_id, shares: [{ name: "Nam", amount: "300000" }, { name: "Lan", amount: "300000" }, { name: "Huy", amount: "300000" }] });
      await spend(ride, daysAgo(d, "19:30"), move, { merchant: "Grab" });
    }
    await spend(450_000, daysAgo(5, "10:00"), food, { merchant: "Siêu thị", note: "Đồ dùng" }); // not an evening out

    const from = daysAgo(30, "00:00").toISOString();
    const rows = (await h.db.query("select public.pf_plan_spend_rows($1, $2, now()) as r", [owner, from])).rows[0].r as any[];
    const ride = rows.find((r) => r.merchant === "Grab");
    expect(ride).toMatchObject({ ride: true, hour: 19 });
    const bill = rows.find((r) => r.merchant === "Quán nhậu Bờ Kè");
    expect(bill).toMatchObject({ ride: false, food: true, owner_amount: "300000", group_size: 4, hour: 20 });
    expect(bill.norm).toContain(" nhau ");

    const est = await call("POST", "/v1/plans/events/estimate", { title: "Nhậu với nhóm Nam", date: vnDay(-3), time: "19:00", hours: 2, people: ["Nam", "Lan"] });
    expect(est.status).toBe(200);
    expect(est.json.data).toMatchObject({ kind: "NHAU", headcount: 3, basis: { samples: 3, ride_samples: 3, source: "history" } });
    expect(est.json.data.per_head).toBe(280_000);
    expect(est.json.data.rides).toEqual({ count: 2, each: 60_000, surge: false });
    expect(est.json.data.owner.likely).toBe(440_000);
  });

  it("save → actual in the window (owner's share after the split) → close with plan vs actual → cancel rules", async () => {
    const id = crypto.randomUUID();
    const date = vnDay(1);
    const saved = await call("POST", "/v1/plans/events", { id, title: "Nhậu với Nam, Lan", date, time: "19:00", hours: 3, people: ["Nam", "Lan"] });
    expect(saved.status).toBe(200);
    expect(saved.json.data).toMatchObject({ id, kind: "NHAU", headcount: 3, state: "PLANNED", people: ["Nam", "Lan"] });
    const budget = Number(saved.json.data.budget);
    expect(budget).toBe(saved.json.data.estimate.owner.likely);
    // same id again = update, never a second plan
    expect((await call("POST", "/v1/plans/events", { id, title: "Nhậu với Nam, Lan", date, time: "19:00", hours: 3, people: ["Nam", "Lan"], place: "Quận 1" })).json.data.version).toBe(2);

    // what really happened: Grab there, the bill split 3 ways, Grab home late; a purchase the next noon is not part of it
    await spend(70_000, daysAgo(1, "18:40"), move, { merchant: "Grab" });
    const bill = await spend(1_500_000, daysAgo(1, "21:15"), food, { merchant: "Quán nhậu" });
    await cmd("SPLIT_APPLY", { tx_id: bill.tx_id, shares: [{ name: "Nam", amount: "500000" }, { name: "Lan", amount: "500000" }] });
    await spend(95_000, daysAgo(1, "23:30"), move, { merchant: "Be" });
    await spend(300_000, daysAgo(0, "12:00"), food, { merchant: "Cơm trưa văn phòng" });

    const live = await call("GET", `/v1/plans/events/${id}`);
    expect(live.json.data.live.actual).toMatchObject({ owner: 665_000, total: 1_665_000, count: 3, buckets: { food: 500_000, rides: 165_000, other: 0 } });

    const closed = await call("POST", `/v1/plans/events/${id}/close`);
    expect(closed.json.data.state).toBe("DONE");
    expect(closed.json.data.actual.owner).toBe(665_000);
    expect(closed.json.data.actual.comparison.summary).toMatch(/^Thực tế 665\.000đ/);

    // the closed plan teaches the next estimate (actual / estimate ratio)
    const next = await call("POST", "/v1/plans/events/estimate", { title: "Nhậu", kind: "NHAU", date: vnDay(-5), people: ["Nam", "Lan"] });
    expect(next.json.data.basis.past_events).toBe(1);

    const other = crypto.randomUUID();
    await call("POST", "/v1/plans/events", { id: other, title: "Cà phê", date: vnDay(-2) });
    expect((await call("POST", `/v1/plans/events/${other}/cancel`)).json.data.state).toBe("CANCELLED");
    expect((await call("POST", `/v1/plans/events/${other}/close`)).json.error?.code).toBe("INVALID_STATE");
    expect((await call("POST", "/v1/plans/events", { id: other, title: "Cà phê", date: vnDay(-2) })).json.error?.code).toBe("INVALID_STATE");
    const list = await call("GET", "/v1/plans/events?state=DONE");
    expect(list.json.data.map((p: any) => p.id)).toEqual([id]);
  });

  it("the cron reminds the day before (once)", async () => {
    const id = crypto.randomUUID();
    const t = Date.now() + 20 * 3_600_000;
    await call("POST", "/v1/plans/events", { id, title: "Tiệc tốt nghiệp", starts_at: new Date(t).toISOString(), headcount: 30 });
    const vnHour = new Date(Date.now() + 7 * 3_600_000).getUTCHours();
    const now = vnHour >= 23 || vnHour < 7 ? new Date(Date.now() + 9 * 3_600_000) : new Date(); // outside quiet hours
    const deps = { cfg, gw: new SupabaseFinanceGateway(cfg) };
    const r1 = await runPlanSweep(deps, now);
    if (now.getTime() < t - 3 * 3_600_000) {
      expect(r1!.reminded).toBe(1);
      expect((await h.db.query("select reminded_at is not null as r from pf_event_plan where id = $1", [id])).rows[0].r).toBe(true);
      expect((await h.db.query("select count(*)::int as n from pf_notification where owner_id = $1 and title like '%Tiệc tốt nghiệp%'", [owner])).rows[0].n).toBe(1);
      expect((await runPlanSweep(deps, now))!.reminded).toBe(0);
    }
  });
});

describe("life plans", () => {
  it("projection from real months; null rates stay null (market defaults); linked goal; archive", async () => {
    // income 20tr and spending ~12tr in each of the last 3 complete months
    for (const m of [1, 2, 3]) {
      const d = new Date(Date.now() + 7 * 3_600_000);
      const day = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - m, 10, 3));
      await cmd("TX_CREATE", { kind: "INCOME", account_id: cash, amount: "20000000", effective_at: day.toISOString(), category_id: salary });
      await spend(12_000_000, new Date(day.getTime() + 86_400_000), food, { note: "Chi tiêu tháng" });
    }
    const base = await call("GET", "/v1/plans/baseline");
    expect(base.json.data.baseline.monthly_income).toBe(20_000_000);
    expect(base.json.data.months).toHaveLength(12);

    const goal = (await cmd("GOAL_CREATE", { name: "Mua căn hộ", target: "750000000" })).goal_id as string;
    const saved = await call("POST", "/v1/plans/life", { name: "Mua căn hộ", price: 2_500_000_000, goal_id: goal });
    expect(saved.status).toBe(200);
    expect(saved.json.data).toMatchObject({ kind: "HOUSE", down_pct: 30, loan_years: 20, goal_id: goal, inflation_pct: null, income_growth_pct: null });
    expect(saved.json.data.projection.saved_now).toBe(0); // the goal holds nothing yet
    expect(saved.json.data.projection.assumptions.join(" ")).toContain("tăng theo lạm phát");

    const list = await call("GET", "/v1/plans/life");
    expect(list.json.data.plans).toHaveLength(1);
    expect(list.json.data.plans[0].projection.summary).toContain("Mua căn hộ");
    expect((await call("DELETE", `/v1/plans/life/${saved.json.data.id}`)).status).toBe(200);
    expect((await call("GET", "/v1/plans/life")).json.data.plans).toHaveLength(0);
    expect((await call("POST", "/v1/plans/life", { name: "x", price: 1, goal_id: crypto.randomUUID() })).json.error?.code).toBe("NOT_FOUND");
  });
});
