import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runBudgetCron, type BudgetGateway } from "../../src/entrypoints/routes-budgets";
import {
  mainCategory,
  pacePush,
  pacing,
  proposeBudgets,
  realisticPush,
  recurringMonthly,
  roundUpTo,
  splitOutliers,
  type BudgetNow,
  type CategoryRef,
  type HistoryRow,
} from "../../src/modules/budgets/plan";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { RemindersGateway } from "../../src/modules/reminders/gateway";

const FOOD = "11111111-1111-4111-8111-000000000001";
const COFFEE = "11111111-1111-4111-8111-000000000002"; // child of FOOD
const MOVE = "11111111-1111-4111-8111-000000000003";
const SHOP = "11111111-1111-4111-8111-000000000004";
const RENT = "11111111-1111-4111-8111-000000000005";
const cats: CategoryRef[] = [
  { id: FOOD, name: "Ăn uống", type: "EXPENSE", parent_id: null, icon: "restaurant" },
  { id: COFFEE, name: "Cà phê", type: "EXPENSE", parent_id: FOOD },
  { id: MOVE, name: "Di chuyển", type: "EXPENSE", parent_id: null },
  { id: SHOP, name: "Mua sắm", type: "EXPENSE", parent_id: null },
  { id: RENT, name: "Nhà ở", type: "EXPENSE", parent_id: null },
];

const day = (base: string, n: number) => new Date(Date.parse(`${base}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

/** `days` days ending at `to`, one row per day per spec. */
function daily(to: string, days: number, category_id: string, amount: number, extra: Partial<HistoryRow> = {}): HistoryRow[] {
  return Array.from({ length: days }, (_, i) => ({ day: day(to, -i), category_id, amount, recurring: false, ...extra }));
}

const budget = (b: Partial<BudgetNow> & Pick<BudgetNow, "category_id" | "limit" | "spent">): BudgetNow => ({
  id: `b-${b.category_id ?? "all"}`,
  category_name: cats.find((c) => c.id === b.category_id)?.name ?? "Tổng chi tiêu",
  icon: null,
  carried: 0,
  version: 1,
  ...b,
});

describe("proposal math", () => {
  it("rounds up to 50.000 with 5% headroom and rolls children into the main category", () => {
    expect(roundUpTo(1)).toBe(50_000);
    expect(roundUpTo(3_150_000)).toBe(3_150_000);
    expect(roundUpTo(3_150_001)).toBe(3_200_000);
    const byId = new Map(cats.map((c) => [c.id, c]));
    expect(mainCategory(COFFEE, byId)).toBe(FOOD);
    // 60 days: 70.000/day food + 30.000/day coffee (child) -> 100.000/day -> 30 days * 1.05 = 3.150.000
    const rows = [...daily("2026-11-30", 60, FOOD, 70_000), ...daily("2026-11-30", 60, COFFEE, 30_000)];
    const r = proposeBudgets({ month: "2026-12", toDay: "2026-11-30", rows, categories: cats, existing: [], past: [], recurringMonthly: 0 });
    expect(r.history_days).toBe(60);
    expect(r.items).toHaveLength(1);
    // December has 31 days: 100.000 * 31 * 1.05 = 3.255.000 -> 3.300.000
    expect(r.items[0]).toMatchObject({ category_id: FOOD, name: "Ăn uống", proposed: 3_300_000, reason: "new" });
    expect(r.items[0]!.note).toContain("60 ngày");
  });

  it("excludes recurring / fixed costs from categories but adds them to the overall total", () => {
    const rows = [
      ...daily("2026-11-30", 60, MOVE, 20_000),
      { day: "2026-11-06", category_id: RENT, amount: 530_000, recurring: true },
      { day: "2026-10-06", category_id: RENT, amount: 530_000, recurring: true },
    ];
    const r = proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows, categories: cats, existing: [], past: [], recurringMonthly: 530_000 });
    expect(r.items.map((i) => i.category_id)).toEqual([MOVE]); // no "Nhà ở" budget from recurring rent
    // 20.000 * 30 * 1.05 = 630.000 -> 650.000; total = 650.000 + 550.000 (530k rounded up)
    expect(r.items[0]!.proposed).toBe(650_000);
    expect(r.total).toMatchObject({ category_id: null, proposed: 1_200_000 });
    expect(r.total!.note).toContain("chi cố định");
  });

  it("ignores one-off big purchases (outliers) and says so", () => {
    expect(splitOutliers([50_000, 60_000, 40_000, 55_000, 45_000, 9_000_000])).toEqual({
      kept: [50_000, 60_000, 40_000, 55_000, 45_000],
      outliers: [9_000_000],
    });
    expect(splitOutliers([200_000, 25_000_000]).outliers).toEqual([25_000_000]);
    const rows = [...daily("2026-11-30", 30, SHOP, 10_000), { day: "2026-11-15", category_id: SHOP, amount: 20_000_000, recurring: false }];
    const r = proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows, categories: cats, existing: [], past: [], recurringMonthly: 0 });
    // 10.000/day * 30 * 1.05 = 315.000 -> 350.000 (the 20.000.000 laptop is not a monthly habit)
    expect(r.items[0]).toMatchObject({ category_id: SHOP, proposed: 350_000, excluded_outliers: 1 });
    expect(r.items[0]!.note).toContain("bỏ qua 1 khoản lớn bất thường");
  });

  it("weights the last 30 days when habits shift", () => {
    // Window 02/09..30/11 (90 days): 30 days at 10.000 (Sept), nothing in Oct, 30 days at 50.000 (Nov).
    // whole window 1.800.000/90 = 20.000/day; last 30 days 50.000/day -> 0.6*50.000 + 0.4*20.000 = 38.000/day
    const rows = [...daily("2026-10-01", 60, MOVE, 10_000), ...daily("2026-11-30", 30, MOVE, 50_000)];
    const r = proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows, categories: cats, existing: [], past: [], recurringMonthly: 0 });
    expect(r.history_days).toBe(90);
    // 38.000 * 30 * 1.05 = 1.197.000 -> 1.200.000 (the old 10.000/day habit alone would give 350.000)
    expect(r.items[0]!.proposed).toBe(1_200_000);
  });

  it("keeps, raises or lowers against the current limit", () => {
    const rows = daily("2026-11-30", 30, FOOD, 100_000); // ~3.150.000 needed
    const run = (limit: number) =>
      proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows, categories: cats, existing: [budget({ category_id: FOOD, limit, spent: 0 })], past: [], recurringMonthly: 0 }).items[0]!;
    expect(run(3_000_000)).toMatchObject({ reason: "keep", proposed: 3_000_000, current_limit: 3_000_000 });
    expect(run(2_000_000)).toMatchObject({ reason: "raise", proposed: 3_150_000 });
    expect(run(5_000_000)).toMatchObject({ reason: "lower", proposed: 3_150_000 });
  });

  it("re-proposes a realistic limit for a category overspent month after month instead of nagging", () => {
    const rows = daily("2026-11-30", 30, FOOD, 80_000); // pace ~2.520.000 -> 2.550.000
    const past = [
      { month: "2026-10", category_id: FOOD, limit: 2_000_000, spent: 3_400_000 },
      { month: "2026-09", category_id: FOOD, limit: 2_000_000, spent: 3_600_000 },
      { month: "2026-08", category_id: FOOD, limit: 2_000_000, spent: 1_900_000 },
    ];
    const r = proposeBudgets({ month: "2026-12", toDay: "2026-11-30", rows, categories: cats, existing: [budget({ category_id: FOOD, limit: 2_000_000, spent: 0 })], past, recurringMonthly: 0 });
    expect(r.items[0]).toMatchObject({ reason: "realistic", proposed: 3_500_000 });
    expect(r.chronic).toEqual([FOOD]);
    const push = realisticPush(r, { minutes: 10 * 60 });
    expect(push).toMatchObject({ key: "budget_fix:2026-12" });
    expect(push!.body).toContain("3.500.000đ");
    expect(realisticPush(r, { minutes: 22 * 60 })).toBeNull(); // evening: no
  });

  it("needs a week of history and skips tiny categories", () => {
    expect(proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows: daily("2026-11-30", 5, FOOD, 100_000), categories: cats, existing: [], past: [], recurringMonthly: 0 }).items).toEqual([]);
    const r = proposeBudgets({ month: "2026-11", toDay: "2026-11-30", rows: [...daily("2026-11-30", 30, FOOD, 100_000), { day: "2026-11-20", category_id: SHOP, amount: 15_000, recurring: false }], categories: cats, existing: [], past: [], recurringMonthly: 0 });
    expect(r.items.map((i) => i.category_id)).toEqual([FOOD]);
  });

  it("monthly equivalent of recurring rules uses the owner's share", () => {
    expect(
      recurringMonthly([
        { kind: "EXPENSE", amount: "1600000", interval: "MONTHLY", enabled: true, split: { owner_share: "530000" } },
        { kind: "EXPENSE", amount: "120000", interval: "YEARLY", enabled: true },
        { kind: "EXPENSE", amount: "60000", interval: "WEEKLY", enabled: true },
        { kind: "INCOME", amount: "15000000", interval: "MONTHLY", enabled: true },
        { kind: "EXPENSE", amount: "99000", interval: "MONTHLY", enabled: false },
      ]),
    ).toBe(530_000 + 10_000 + 260_000);
  });
});

describe("pacing", () => {
  const today = new Map<string, number>([[COFFEE, 30_000]]);

  it("spreads what is left over the remaining days and subtracts what was spent today", () => {
    // Nov 19 (30 days): 12 days left incl. today. Limit 3.000.000, spent 1.830.000 of which 30.000 today.
    const p = pacing({ today: "2026-11-19", budgets: [budget({ category_id: FOOD, limit: 3_000_000, spent: 1_830_000 })], todaySpent: today, categories: cats });
    expect(p.days_left).toBe(12);
    // (3.000.000 - 1.800.000) / 12 = 100.000 allowance; safe today = 70.000
    expect(p.items[0]).toMatchObject({ daily_allowance: 100_000, safe_today: 70_000, today_spent: 30_000, status: "ok" });
  });

  it("flags 'fast' only when clearly ahead after the first days, 'over' when over", () => {
    const at = (date: string, spent: number) =>
      pacing({ today: date, budgets: [budget({ category_id: FOOD, limit: 3_000_000, spent })], todaySpent: new Map(), categories: cats }).items[0]!;
    expect(at("2026-11-10", 1_300_000)).toMatchObject({ status: "fast", ahead_pct: 30 }); // expected 1.000.000
    expect(at("2026-11-10", 1_150_000).status).toBe("ok"); // 15% ahead: fine
    expect(at("2026-11-03", 900_000).status).toBe("ok"); // too early to judge
    expect(at("2026-11-20", 3_100_000)).toMatchObject({ status: "over", safe_today: 0 });
  });

  it("overall budget counts all of today's spending; no budgets -> nothing", () => {
    const p = pacing({ today: "2026-11-19", budgets: [budget({ category_id: null, limit: 6_000_000, spent: 2_000_000 })], todaySpent: new Map([[MOVE, 50_000], [COFFEE, 30_000]]), categories: cats });
    expect(p.items).toEqual([]);
    expect(p.overall).toMatchObject({ today_spent: 80_000 });
    expect(pacing({ today: "2026-11-19", budgets: [], todaySpent: new Map(), categories: cats }).overall).toBeNull();
  });

  it("push: one a day, worst category, waking hours, never for chronic categories", () => {
    const p = pacing({
      today: "2026-11-10",
      budgets: [budget({ category_id: FOOD, limit: 3_000_000, spent: 1_500_000 }), budget({ category_id: MOVE, limit: 1_000_000, spent: 400_000 })],
      todaySpent: new Map(),
      categories: cats,
    });
    const push = pacePush(p, { date: "2026-11-10", minutes: 12 * 60, chronic: new Set() });
    expect(push).toMatchObject({ key: "pace:2026-11-10", title: "Ăn uống đang chi nhanh hơn dự kiến" });
    expect(push!.body).toContain("Còn 21 ngày");
    expect(push!.body).toContain("nhanh hơn kế hoạch 50%");
    // Di chuyển is next worst (33% ahead) once Ăn uống is chronic
    expect(pacePush(p, { date: "2026-11-10", minutes: 12 * 60, chronic: new Set([FOOD]) })!.title).toContain("Di chuyển");
    expect(pacePush(p, { date: "2026-11-10", minutes: 8 * 60, chronic: new Set() })).toBeNull();
    expect(pacePush(p, { date: "2026-11-10", minutes: 23 * 60 + 30, chronic: new Set() })).toBeNull();
  });
});

// ---------------------------------------------------------------- cron + routes
const OWNER = "22222222-2222-4222-8222-222222222222";
const cfg = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000, onesignalRestKey: "k", onesignalAppId: "app" } as Config;

function fakes(opts: { thisMonth?: unknown[]; lastMonth?: unknown[]; history?: HistoryRow[]; settings?: unknown } = {}) {
  const claimed = new Set<string>();
  const commands: any[] = [];
  const budgets: Record<string, unknown[]> = { "2026-12-01": opts.thisMonth ?? [], "2026-11-01": opts.lastMonth ?? [] };
  const gw = {
    getOwnerId: vi.fn(async () => OWNER),
    readCategories: vi.fn(async () => cats),
    readBudgets: vi.fn(async (_o: string, m: string) => budgets[m] ?? []),
    readRecurring: vi.fn(async () => []),
    executeCommand: vi.fn(async (ctx: unknown, id: string, _h: string, cmd: unknown) => {
      commands.push({ ctx, id, cmd });
      return { status: "COMMITTED" };
    }),
  } as unknown as FinanceGateway;
  const rg = {
    settingsRead: vi.fn(async () => opts.settings ?? null),
    pushClaim: vi.fn(async (_o: string, k: string) => (claimed.has(k) ? false : (claimed.add(k), true))),
  } as unknown as RemindersGateway;
  const bg: BudgetGateway = { history: vi.fn(async () => opts.history ?? daily("2026-12-01", 60, FOOD, 100_000)) };
  const pushes: any[] = [];
  const pushFetch = vi.fn(async (url: string, init: RequestInit) => {
    if (String(url).includes("onesignal")) pushes.push(JSON.parse(String(init.body)));
    return new Response(JSON.stringify({ id: "n1" }), { status: 200 });
  }) as unknown as typeof fetch;
  // sendPush also stores the inbox item through the global fetch.
  vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 200 })));
  return { deps: { cfg, gw, rg, bg, pushFetch }, claimed, commands, pushes, gw };
}

// 2026-12-02 10:00 Vietnam = 03:00 UTC
const DEC2_10H = new Date("2026-12-02T03:00:00Z");

describe("budget cron", () => {
  it("a new month without budgets gets last month's categories with fresh limits, once, through BUDGET_UPSERT", async () => {
    const last = [
      { id: "x1", category_id: FOOD, category_name: "Ăn uống", limit_amount: "2000000", carried: "0", spent: "2100000", carryover: true, version: 3 },
      { id: "x2", category_id: null, category_name: "Tổng chi tiêu", limit_amount: "6000000", carried: "0", spent: "5000000", carryover: false, version: 1 },
    ];
    const f = fakes({ lastMonth: last });
    const done = await runBudgetCron(f.deps, OWNER, DEC2_10H);
    expect(done).toContain("budget_auto:2026-12");
    expect(f.commands).toHaveLength(2);
    const food = f.commands.find((c) => c.cmd.payload.category_id === FOOD);
    // server-initiated: no device / session
    expect(food.ctx).toMatchObject({ ownerId: OWNER, deviceId: null });
    expect(food.cmd).toMatchObject({ command_type: "BUDGET_UPSERT", payload: { month: "2026-12", carryover: true } });
    expect(Number(food.cmd.payload.limit)).toBeGreaterThan(2_000_000); // habit-adjusted (100.000/day)
    expect(f.pushes.some((p) => String(p.headings?.vi ?? p.headings?.en ?? "").includes("Đã đặt ngân sách tháng 12/2026"))).toBe(true);
    // Second tick: claimed, nothing written again.
    await runBudgetCron(f.deps, OWNER, new Date("2026-12-02T03:15:00Z"));
    expect(f.commands).toHaveLength(2);
  });

  it("does nothing at night, when disabled, or when the month already has budgets", async () => {
    const last = [{ id: "x1", category_id: FOOD, category_name: "Ăn uống", limit_amount: "2000000", spent: "0", version: 1 }];
    const night = fakes({ lastMonth: last });
    expect(await runBudgetCron(night.deps, OWNER, new Date("2026-12-01T17:00:00Z"))).toEqual([]); // 00:00 local
    const off = fakes({ lastMonth: last, settings: { budget_auto: { enabled: false }, budget_pacing: { enabled: false } } });
    expect(await runBudgetCron(off.deps, OWNER, DEC2_10H)).toEqual([]);
    expect(off.commands).toEqual([]);
    const has = fakes({ lastMonth: last, thisMonth: [{ id: "y", category_id: FOOD, category_name: "Ăn uống", limit_amount: "1000000", spent: "0", version: 1 }] });
    await runBudgetCron(has.deps, OWNER, DEC2_10H);
    expect(has.commands).toEqual([]);
  });

  it("pacing push at most once a day and only on the hour check", async () => {
    const now = new Date("2026-12-12T05:00:00Z"); // 12:00 local, day 12
    const thisMonth = [{ id: "b1", category_id: FOOD, category_name: "Ăn uống", limit_amount: "3000000", carried: "0", spent: "2000000", version: 1 }];
    const f = fakes({ thisMonth, history: [] });
    expect(await runBudgetCron(f.deps, OWNER, now)).toContain("pace:2026-12-12");
    expect(await runBudgetCron(f.deps, OWNER, new Date("2026-12-12T06:00:00Z"))).not.toContain("pace:2026-12-12");
    const f2 = fakes({ thisMonth, history: [] });
    expect(await runBudgetCron(f2.deps, OWNER, new Date("2026-12-12T05:20:00Z"))).toEqual([]); // not the hour check
  });
});

describe("budget routes", () => {
  const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "33333333-3333-4333-8333-333333333333" })) } as unknown as SessionVerifier;
  const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };

  it("proposals, one-tap apply (skips unchanged, passes versions) and pacing", async () => {
    const f = fakes({ thisMonth: [{ id: "b1", category_id: FOOD, category_name: "Ăn uống", limit_amount: "1000000", carried: "0", spent: "0", version: 4 }] });
    const app = buildApp(() => ({ cfg, gw: f.gw, verifier, bg: f.deps.bg, rg: f.deps.rg }) as any);
    const prop = await app.request("/v1/budgets/proposals?month=2026-12", { headers }, {} as never);
    expect(prop.status).toBe(200);
    const data = ((await prop.json()) as any).data;
    expect(data.items[0]).toMatchObject({ category_id: FOOD, reason: "raise", current_limit: 1_000_000, current_version: 4 });

    const apply = await app.request(
      "/v1/budgets/proposals/apply",
      { method: "POST", headers, body: JSON.stringify({ month: "2026-12", items: [{ category_id: FOOD, limit: "3300000" }, { category_id: FOOD, limit: "1000000" }] }) },
      {} as never,
    );
    expect(apply.status).toBe(200);
    expect(f.commands).toHaveLength(1); // the unchanged 1.000.000 is skipped
    expect(f.commands[0].cmd.payload).toMatchObject({ month: "2026-12", limit: "3300000", category_id: FOOD, expected_version: 4 });
    expect(f.commands[0].ctx).toMatchObject({ deviceId: "44444444-4444-4444-4444-444444444444" });

    expect((await app.request("/v1/budgets/proposals/apply", { method: "POST", headers, body: JSON.stringify({ items: [] }) }, {} as never)).status).toBe(400);
    expect((await app.request("/v1/budgets/proposals?month=2026-13", { headers }, {} as never)).status).toBe(400);
    const pace = await app.request("/v1/budgets/pacing", { headers }, {} as never);
    expect(pace.status).toBe(200);
    expect(((await pace.json()) as any).data).toHaveProperty("days_left");
  });
});
