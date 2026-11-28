import { afterEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { enrichPlanActions, resolveEvent, runPlanSweep } from "../../src/entrypoints/routes-plans";
import { resolveAgentOutput, type AgentContext } from "../../src/modules/ai/agent";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import {
  calibration,
  collectActual,
  compareActual,
  estimateEvent,
  inferKind,
  isRide,
  roundVnd,
  type SpendRow,
} from "../../src/modules/plans/estimate";
import type { EventPlanJson, LifePlanJson, PlanGateway, SpendRowJson } from "../../src/modules/plans/gateway";
import { addMonths, loanPayment, projectPlan, savingsBaseline, type MarketAssumptions } from "../../src/modules/plans/project";

const OWNER = "11111111-1111-4111-8111-111111111111";
const cfg: Config = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000, onesignalRestKey: "rk", onesignalAppId: "app" };

let n = 0;
const row = (at: string, amount: number, o: Partial<SpendRow> = {}): SpendRow => ({
  id: `r${++n}`, at, kind: "EXPENSE", amount, owner_amount: o.owner_amount ?? amount, group_size: null, category: null, merchant: null, note: null, ...o,
});

// 2026-12-05 19:00–23:00 Vietnam time
const S = "2026-12-05T12:00:00.000Z";
const E = "2026-12-05T16:00:00.000Z";

describe("event kind", () => {
  it("reads the kind from Vietnamese text", () => {
    expect(inferKind("Tối thứ 7 đi nhậu với nhóm Nam")).toBe("NHAU");
    expect(inferKind("Tổ chức tiệc tốt nghiệp tháng 1")).toBe("TIEC");
    expect(inferKind("Đi Đà Lạt 3 ngày")).toBe("DU_LICH");
    expect(inferKind("cà phê với Lan")).toBe("CAFE");
    expect(inferKind("Sinh nhật Huy")).toBe("SINH_NHAT");
    expect(inferKind("Lê Đào Nhân Sâm họp")).toBe("KHAC");
  });
  it("tells rides from fuel / parking", () => {
    expect(isRide({ category: "Di chuyển", merchant: "Grab", note: null, amount: 60_000 })).toBe(true);
    expect(isRide({ category: "Di chuyển", merchant: null, note: "đổ xăng", amount: 80_000 })).toBe(false);
    expect(isRide({ category: null, merchant: null, note: "Be chuyến về nhà", amount: 45_000 })).toBe(true);
  });
});

describe("estimate", () => {
  it("without history: priors, a split share and a late-night return ride", () => {
    const e = estimateEvent({ title: "Nhậu với nhóm Nam", starts_at: S, ends_at: E, headcount: 4 }, []);
    expect(e.kind).toBe("NHAU");
    expect(e.basis.source).toBe("prior");
    expect(e.rides).toEqual({ count: 2, each: 70_000, surge: true });
    expect(e.breakdown.map((i) => i.key)).toEqual(["food", "drinks", "rides", "misc"]);
    // food 550k + drinks 450k + rides 70k + 91k (≈160k) + misc 12 % (140k)
    expect(e.total.likely).toBe(1_300_000);
    // shared (550 + 450 + 140) / 4 + own rides 160k = 445k → 450k
    expect(e.owner.likely).toBe(450_000);
    expect(e.owner.low).toBeLessThan(e.owner.likely);
    expect(e.owner.high).toBeGreaterThan(e.owner.likely);
    expect(e.summary).toContain("Dự kiến ~1.300.000đ (bạn trả ~450.000đ sau khi chia)");
    expect(e.assumptions.join(" ")).toContain("Chưa có lịch sử");
  });

  it("from the owner's history: per-person cost of split bills and their usual Grab fare", () => {
    const rows = [
      ...[0, 1, 2].map((i) => row(`2026-11-0${i + 1}T13:00:00Z`, 1_200_000, { owner_amount: 300_000, group_size: 4, category: "Ăn uống", note: "Quán nhậu Bờ Kè" })),
      row("2026-11-02T12:30:00Z", 50_000, { category: "Di chuyển", merchant: "Grab" }),
      row("2026-11-03T12:30:00Z", 60_000, { category: "Di chuyển", merchant: "Grab" }),
      row("2026-11-04T12:30:00Z", 80_000, { category: "Di chuyển", merchant: "Be" }),
      row("2026-11-04T05:00:00Z", 500_000, { category: "Mua sắm", merchant: "Shopee" }),
    ];
    const e = estimateEvent({ title: "Nhậu", kind: "NHAU", starts_at: S, ends_at: "2026-12-05T14:00:00.000Z", headcount: 3 }, rows);
    expect(e.basis).toMatchObject({ samples: 3, ride_samples: 3, source: "history" });
    expect(e.per_head).toBe(280_000); // 3/5 × 300k + 2/5 × 250k prior
    expect(e.rides).toEqual({ count: 2, each: 60_000, surge: false });
    expect(e.total.likely).toBe(1_080_000);
    expect(e.owner.likely).toBe(440_000);
  });

  it("a graduation party the owner hosts: everyone's food, venue, photos — no split", () => {
    const e = estimateEvent({ title: "Tiệc tốt nghiệp", starts_at: "2027-01-10T11:00:00Z", ends_at: "2027-01-10T16:00:00Z", headcount: 30 }, []);
    expect(e.kind).toBe("TIEC");
    expect(e.owner_pays).toBe(true);
    expect(e.breakdown.map((i) => i.key)).toEqual(["food_drinks", "venue", "photo", "rides", "misc"]);
    expect(e.owner.likely).toBe(e.total.likely);
    expect(e.total.likely).toBe(9_000_000 + 1_500_000 + 1_500_000 + 160_000 + 970_000);
  });

  it("learns from closed plans: actual 20 % above estimate three times → estimates go up", () => {
    const past = [1, 2, 3].map(() => ({ kind: "NHAU" as const, estimated_owner: 500_000, actual_owner: 600_000 }));
    expect(calibration(past, "NHAU")).toEqual({ factor: 1.2, n: 3 });
    expect(calibration(past, "CAFE")).toEqual({ factor: 1, n: 0 });
    const base = estimateEvent({ title: "Nhậu", starts_at: S, ends_at: E, headcount: 4 }, []);
    const learned = estimateEvent({ title: "Nhậu", starts_at: S, ends_at: E, headcount: 4 }, [], past);
    expect(learned.total.likely).toBeGreaterThan(base.total.likely);
    expect(learned.basis.calibration).toBe(1.2);
    expect(learned.assumptions.join(" ")).toContain("3 lần trước");
  });

  it("own vehicle: no Grab line", () => {
    const e = estimateEvent({ title: "Ăn tối", kind: "AN_UONG", starts_at: S, transport: "OWN" }, []);
    expect(e.rides).toBeNull();
    expect(e.breakdown.some((i) => i.key === "rides")).toBe(false);
  });
});

describe("plan vs actual", () => {
  const plan = { kind: "NHAU" as const, starts_at: S, ends_at: E };
  const rows = [
    row("2026-12-05T11:30:00Z", 70_000, { merchant: "Grab" }), // going there
    row("2026-12-05T13:00:00Z", 1_200_000, { owner_amount: 300_000, group_size: 4, category: "Ăn uống", note: "Lẩu" }), // the bill, split
    row("2026-12-05T16:30:00Z", 91_000, { merchant: "Grab" }), // home late
    row("2026-12-05T19:00:00Z", 450_000, { category: "Mua sắm", merchant: "Shopee" }), // 02:00, unrelated
    row("2026-12-05T06:00:00Z", 40_000, { category: "Ăn uống", note: "Cơm trưa" }), // lunch, outside
  ];

  it("collects the outing's money (owner's share after the split, both rides)", () => {
    const a = collectActual(plan, rows);
    expect(a.count).toBe(3);
    expect(a.total).toBe(1_361_000);
    expect(a.owner).toBe(461_000);
    expect(a.buckets).toEqual({ food: 300_000, rides: 161_000, other: 0 });
  });

  it("compares with the estimate", () => {
    const est = estimateEvent({ title: "Nhậu", starts_at: S, ends_at: E, headcount: 4 }, []);
    const ok = compareActual(est, collectActual(plan, rows));
    expect(ok.pct).toBe(2);
    expect(ok.summary).toBe("Thực tế 461.000đ, đúng dự toán (+2%).");
    const over = compareActual(est, { total: 0, owner: 600_000, buckets: { food: 440_000, rides: 160_000, other: 0 }, tx_ids: ["x"], count: 1 });
    expect(over.pct).toBe(33);
    expect(over.driver).toBe("food");
    expect(over.summary).toContain("vượt 33% so với dự toán, chủ yếu do ăn uống");
    expect(compareActual(est, { total: 0, owner: 0, buckets: { food: 0, rides: 0, other: 0 }, tx_ids: [], count: 0 }).summary).toContain("Chưa thấy");
  });
});

describe("life plan projection", () => {
  const flat: MarketAssumptions = { priceInflationPct: () => 0, cpiPct: () => 0, depositRatePct: () => 0, loanRatePct: () => 9, source: "test" };
  const months = [
    ...["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"].map((m, i) => ({ month: m, income: 20_000_000, expense: i === 2 ? 40_000_000 : 12_000_000 })),
    { month: "2026-11", income: 3_000_000, expense: 9_000_000, partial: true },
  ];
  const wealth = { assets: 100_000_000, liabilities: 0, receivable: 5_000_000, payable: 0, goals: [{ id: "g", name: "Laptop", target: 30_000_000, allocated: 20_000_000 }] };
  const now = new Date("2026-11-29T03:00:00Z");

  it("baseline: medians ignore a one-off month and the partial current month", () => {
    expect(savingsBaseline(months, wealth)).toEqual({ monthly_income: 20_000_000, monthly_expense: 12_000_000, monthly_saving: 8_000_000, months_used: 6, available: 80_000_000 });
  });

  it("loan payment (annuity)", () => {
    expect(loanPayment(1_000_000_000, 9, 20)).toBeCloseTo(8_997_260, -1);
    expect(loanPayment(120_000_000, 0, 1)).toBe(10_000_000);
    expect(loanPayment(0, 9, 20)).toBe(0);
  });

  it("house 1 tỷ, 30 % down: reach month, loan, what-if", () => {
    const b = savingsBaseline(months, wealth);
    const p = projectPlan({ name: "Căn hộ", kind: "HOUSE", price: 1_000_000_000, down_pct: 30, loan_years: 20 }, b, now, flat);
    // 80tr now + 8tr/month ≥ 300tr after 28 months
    expect(p.months).toBe(28);
    expect(p.reach_month).toBe(addMonths("2026-11", 28));
    expect(p.reach_month).toBe("2029-03");
    expect(p.loan_amount).toBe(700_000_000);
    expect(p.monthly_payment).toBe(roundVnd(loanPayment(700_000_000, 9, 20)));
    expect(p.what_if.find((w) => w.label.includes("2tr"))?.reach_month).toBe("2028-09"); // 10tr/month → 22 months
    expect(p.summary).toContain("~T3/2029");
    expect(p.summary).toContain("T9/2028");
    expect(p.timeline[0]).toEqual({ month: "2026-11", saved: 80_000_000, needed: 300_000_000 });
  });

  it("price inflation pushes the date out; a linked goal counts only its own savings", () => {
    const b = savingsBaseline(months, wealth);
    const infl: MarketAssumptions = { ...flat, priceInflationPct: () => 10 };
    const p = projectPlan({ name: "Căn hộ", kind: "HOUSE", price: 1_000_000_000, down_pct: 30 }, b, now, infl);
    expect(p.months!).toBeGreaterThan(28);
    const goalOnly = projectPlan({ name: "Căn hộ", kind: "HOUSE", price: 1_000_000_000, down_pct: 30, saved_now: 20_000_000 }, b, now, flat);
    expect(goalOnly.months).toBe(35); // 20tr + 8tr × 35 = 300tr
  });

  it("spending more than earning: no date, a gentle message", () => {
    const b = savingsBaseline([{ month: "2026-10", income: 10_000_000, expense: 12_000_000 }], { ...wealth, assets: 0, goals: [] });
    const p = projectPlan({ name: "Xe", kind: "CAR", price: 500_000_000, down_pct: 100 }, b, now, flat);
    expect(p.reachable).toBe(false);
    expect(p.reach_month).toBeNull();
    expect(p.summary).toContain("chi tiêu đang bằng hoặc hơn thu nhập");
  });
});

describe("assistant steps", () => {
  const ctx: AgentContext = { today: "2026-11-29", nowIso: "2026-11-29T03:00:00.000Z", accounts: [], categories: [], contacts: [], debts: [], goals: [] } as unknown as AgentContext;
  const run = (steps: unknown[]) => resolveAgentOutput({ reply: "ok", steps }, ctx);

  it("PLAN_EVENT becomes a low-risk save call the server fills with the estimate", () => {
    const a = run([{ do: "PLAN_EVENT", title: "Nhậu với nhóm Nam", kind: "NHAU", date: "2026-12-05", time: "19:00", people: ["Nam", "Lan"], headcount: "3" }]).actions[0] as any;
    expect(a.type).toBe("CALL");
    expect(a.risk).toBe("low");
    expect(a.call.path).toBe("/plans/events");
    expect(a.call.body).toMatchObject({ title: "Nhậu với nhóm Nam", kind: "NHAU", date: "2026-12-05", time: "19:00", people: ["Nam", "Lan"], headcount: 3 });
    expect(a.call.body.id).toMatch(/^[0-9a-f-]{36}$/);
    const ask = run([{ do: "PLAN_EVENT", save: false, title: "Đi Đà Lạt", date: "2026-12-20" }]).actions[0] as any;
    expect(ask.call.path).toBe("/plans/events/estimate");
    expect(run([{ do: "PLAN_EVENT", date: "2026-12-05" }]).actions[0]!.type).toBe("ASK");
    expect(run([{ do: "PLAN_EVENT", title: "x", date: "2031-01-01" }]).actions[0]!.type).toBe("ASK");
  });

  it("PLAN_LIFE and ANSWER PLANS", () => {
    const a = run([{ do: "PLAN_LIFE", name: "Mua căn hộ", kind: "HOUSE", price: "2.500.000.000", down_pct: "30%" }]).actions[0] as any;
    expect(a).toMatchObject({ type: "CALL", risk: "low", call: { method: "POST", path: "/plans/life" } });
    expect(a.call.body).toMatchObject({ name: "Mua căn hộ", kind: "HOUSE", price: 2_500_000_000, down_pct: 30 });
    expect(run([{ do: "PLAN_LIFE", name: "Xe" }]).actions[0]!.type).toBe("ASK");
    expect(run([{ do: "ANSWER", what: "PLANS" }]).actions[0]).toMatchObject({ type: "ANSWER", what: "PLANS" });
  });
});

// ---------------------------------------------------------------- routes + cron with an in-memory gateway
function fakePg(rows: SpendRowJson[] = []) {
  const events = new Map<string, EventPlanJson>();
  const life = new Map<string, LifePlanJson>();
  const claims = new Set<string>();
  const pg: PlanGateway & { events: typeof events; life: typeof life } = {
    events,
    life,
    async eventUpsert(_o, p) {
      const id = (p.id as string) ?? crypto.randomUUID();
      const prev = events.get(id);
      const e = { ...(prev ?? { state: "PLANNED", actual: null, reminded_at: null, alerted_at: null, closed_at: null, created_at: "", updated_at: "", version: 0 }), ...p, id, version: (prev?.version ?? 0) + 1 } as EventPlanJson;
      events.set(id, e);
      return e;
    },
    async eventList(_o, state, from, to) {
      return [...events.values()].filter((e) => (!state || e.state === state) && (!from || e.ends_at >= from) && (!to || e.starts_at < to));
    },
    async eventGet(_o, id) {
      const e = events.get(id);
      if (!e) throw new Error("NOT_FOUND");
      return e;
    },
    async eventClose(_o, id, state, actual) {
      const e = { ...events.get(id)!, state, actual: state === "DONE" ? actual : null, closed_at: "now" } as EventPlanJson;
      events.set(id, e);
      return e;
    },
    async eventMark(_o, id, what) {
      const e = events.get(id)!;
      const k = what === "REMINDED" ? "reminded_at" : "alerted_at";
      if (e[k]) return false;
      events.set(id, { ...e, [k]: "now" });
      return true;
    },
    async spendRows(_o, from, to) {
      return rows.filter((r) => r.at >= from && r.at < to);
    },
    async months() {
      return ["2026-06", "2026-07", "2026-08", "2026-09", "2026-10"].map((m) => ({ month: m, income: "20000000", expense: "12000000", partial: false }));
    },
    async wealth() {
      return { assets: "80000000", liabilities: "0", receivable: "0", payable: "0", goals: [] };
    },
    async lifeUpsert(_o, p) {
      const id = (p.id as string) ?? crypto.randomUUID();
      const l = { ...p, id, price: String(p.price), extra_saving: String(p.extra_saving ?? 0), created_at: "", updated_at: "", version: 1 } as unknown as LifePlanJson;
      life.set(id, l);
      return l;
    },
    async lifeList() {
      return [...life.values()];
    },
    async lifeDelete(_o, id) {
      life.delete(id);
      return { id, archived: true };
    },
    async pushClaim(_o, key) {
      if (claims.has(key)) return false;
      claims.add(key);
      return true;
    },
  };
  return pg;
}

const gw = {
  getOwnerId: vi.fn(async () => OWNER),
  readAccounts: vi.fn(async () => [
    { id: "a", name: "VCB", kind: "BANK", balance: "2100000" },
    { id: "b", name: "Tiền mặt", kind: "CASH", balance: "300000" },
  ]),
} as unknown as FinanceGateway;
const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "s" })) } as unknown as SessionVerifier;
const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };

/** sendPush stores the inbox item (global fetch) and calls OneSignal (pushFetch): capture both. */
function pushes() {
  const sent: { title: string; body: string }[] = [];
  vi.stubGlobal("fetch", vi.fn(async () => new Response("true", { status: 200, headers: { "content-type": "application/json" } })));
  const pushFetch = vi.fn(async (_u: unknown, init: RequestInit) => {
    const b = JSON.parse(String(init.body));
    sent.push({ title: b.headings.vi, body: b.contents.vi });
    return new Response("{}", { status: 200 });
  }) as unknown as typeof fetch;
  return { sent, pushFetch };
}

afterEach(() => vi.unstubAllGlobals());

describe("plan routes", () => {
  it("estimate (no write), save, live actual, close", async () => {
    const rows: SpendRowJson[] = [
      { id: "t1", at: "2026-11-20T13:00:00Z", kind: "EXPENSE", amount: "1200000", owner_amount: "300000", group_size: 4, category: "Ăn uống", merchant: null, note: "Lẩu" },
    ];
    const pg = fakePg(rows);
    const app = buildApp(() => ({ cfg, gw, verifier, pg }) as any);
    const env = {} as never;
    const body = { title: "Nhậu với nhóm Nam", date: "2026-11-20", time: "19:00", people: ["Nam", "Lan", "Huy"] };

    const est = (await (await app.request("/v1/plans/events/estimate", { method: "POST", headers, body: JSON.stringify(body) }, env)).json()) as any;
    expect(est.data.kind).toBe("NHAU");
    expect(est.data.headcount).toBe(4);
    expect(est.data.starts_at).toBe("2026-11-20T12:00:00.000Z");
    expect(pg.events.size).toBe(0);

    const id = "55555555-5555-4555-8555-555555555555";
    const saved = (await (await app.request("/v1/plans/events", { method: "POST", headers, body: JSON.stringify({ ...body, id }) }, env)).json()) as any;
    expect(saved.data).toMatchObject({ id, kind: "NHAU", headcount: 4, people: ["Nam", "Lan", "Huy"] });
    expect(Number(saved.data.budget)).toBe(saved.data.estimate.owner.likely);

    const got = (await (await app.request(`/v1/plans/events/${id}`, { headers }, env)).json()) as any;
    expect(got.data.live.actual.owner).toBe(300_000); // started (in the past) → money spent so far

    const closed = (await (await app.request(`/v1/plans/events/${id}/close`, { method: "POST", headers }, env)).json()) as any;
    expect(closed.data.state).toBe("DONE");
    expect(closed.data.actual.owner).toBe(300_000);
    expect(closed.data.actual.comparison.summary).toContain("Thực tế 300.000đ");

    expect((await app.request("/v1/plans/events", { method: "POST", headers, body: JSON.stringify({ title: "" }) }, env)).status).toBe(400);
    expect((await app.request("/v1/plans/events/not-a-uuid", { headers }, env)).status).toBe(400);
  });

  it("life plans: project without saving, save, list with projections", async () => {
    const pg = fakePg();
    const app = buildApp(() => ({ cfg, gw, verifier, pg }) as any);
    const env = {} as never;
    const pr = (await (await app.request("/v1/plans/life/project", { method: "POST", headers, body: JSON.stringify({ name: "Mua căn hộ", price: 2_500_000_000 }) }, env)).json()) as any;
    expect(pr.data.plan).toMatchObject({ kind: "HOUSE", down_pct: 30, loan_years: 20 });
    expect(pr.data.projection.reachable).toBe(true);
    expect(pg.life.size).toBe(0);
    const saved = (await (await app.request("/v1/plans/life", { method: "POST", headers, body: JSON.stringify({ name: "Mua xe máy", price: 60_000_000 }) }, env)).json()) as any;
    expect(saved.data).toMatchObject({ kind: "CAR", down_pct: 100 });
    expect(saved.data.projection.months).toBe(0); // 80tr free already covers 60tr
    const list = (await (await app.request("/v1/plans/life", { headers }, env)).json()) as any;
    expect(list.data.baseline.monthly_saving).toBe(8_000_000);
    expect(list.data.plans).toHaveLength(1);
    expect((await app.request("/v1/plans/life", { method: "POST", headers, body: JSON.stringify({ name: "x", price: -1 }) }, env)).status).toBe(400);
  });
});

describe("plan cron", () => {
  const start = "2026-12-05T12:00:00.000Z"; // 19:00 VN
  const end = "2026-12-05T16:00:00.000Z";
  const plan = (pg: ReturnType<typeof fakePg>) =>
    pg.eventUpsert(OWNER, {
      id: "66666666-6666-4666-8666-666666666666", title: "Nhậu với Nam", kind: "NHAU", starts_at: start, ends_at: end, headcount: 3, people: ["Nam", "Lan"],
      owner_pays: false, transport: "GRAB", estimate: { total: { likely: 900_000 }, owner: { likely: 350_000, low: 280_000, high: 480_000 }, breakdown: [] }, budget: "350000", place: null, note: null,
    });

  it("day-before reminder once, with the best account", async () => {
    const pg = fakePg();
    await plan(pg);
    const { sent, pushFetch } = pushes();
    const now = new Date("2026-12-04T13:00:00Z"); // 20:00 VN the day before
    expect((await runPlanSweep({ cfg, gw, pg, pushFetch }, now))!.reminded).toBe(1);
    expect(sent[0]).toEqual({ title: "Ngày mai: Nhậu với Nam", body: "Dự kiến ~900k (bạn ~350k) · VCB còn 2,1tr, đủ" });
    expect((await runPlanSweep({ cfg, gw, pg, pushFetch }, new Date("2026-12-04T14:00:00Z")))!.reminded).toBe(0);
  });

  it("quiet hours: nothing", async () => {
    const pg = fakePg();
    await plan(pg);
    const { sent, pushFetch } = pushes();
    expect(await runPlanSweep({ cfg, gw, pg, pushFetch }, new Date("2026-12-04T17:00:00Z"))).toEqual({ reminded: 0, alerted: 0, closed: 0, monthly: false }); // 00:00 VN
    expect(sent).toHaveLength(0);
  });

  it("in-event alert at 85 % of the budget, then close the next morning with plan vs actual", async () => {
    const pg = fakePg([
      { id: "t1", at: "2026-12-05T13:00:00Z", kind: "EXPENSE", amount: "1200000", owner_amount: "300000", group_size: 4, category: "Ăn uống", merchant: null, note: "Lẩu" },
      { id: "t2", at: "2026-12-05T16:20:00Z", kind: "EXPENSE", amount: "120000", owner_amount: "120000", group_size: null, category: "Di chuyển", merchant: "Grab", note: null },
    ]);
    await plan(pg);
    const { sent, pushFetch } = pushes();
    expect((await runPlanSweep({ cfg, gw, pg, pushFetch }, new Date("2026-12-05T14:00:00Z")))!.alerted).toBe(1); // 21:00 VN, 300k ≥ 85 % of 350k
    expect(sent.at(-1)!.body).toBe("Đã chi 300k/350k dự toán");
    const r = await runPlanSweep({ cfg, gw, pg, pushFetch }, new Date("2026-12-06T01:00:00Z")); // 08:00 VN next day
    expect(r!.closed).toBe(1);
    const p = pg.events.get("66666666-6666-4666-8666-666666666666")!;
    expect(p.state).toBe("DONE");
    expect(p.actual!.owner).toBe(420_000);
    expect(sent.at(-1)).toEqual({ title: "Thực tế vs Dự toán: Nhậu với Nam", body: "Thực tế 420.000đ, vượt 20% so với dự toán, chủ yếu do ăn uống." });
  });

  it("monthly life-plan line on the 1st from 09:00, once", async () => {
    const pg = fakePg();
    await pg.lifeUpsert(OWNER, { name: "Căn hộ", kind: "HOUSE", price: 1_000_000_000, down_pct: 30, loan_rate_pct: null, loan_years: 20, inflation_pct: 0, income_growth_pct: 0, extra_saving: 0, goal_id: null });
    const { sent, pushFetch } = pushes();
    const now = new Date("2027-01-01T02:30:00Z"); // 09:30 VN
    expect((await runPlanSweep({ cfg, gw, pg, pushFetch }, now))!.monthly).toBe(true);
    expect(sent[0]!.title).toBe("Tiến độ kế hoạch lớn");
    expect(sent[0]!.body).toMatch(/^Căn hộ: dự kiến ~T\d+\/20\d\d \(tích lũy ~8tr\/tháng\)$/);
    expect((await runPlanSweep({ cfg, gw, pg, pushFetch }, new Date("2027-01-01T03:00:00Z")))!.monthly).toBe(false);
  });
});

describe("assistant enrichment", () => {
  it("event and life cards get their numbers; ANSWER PLANS gets the list", async () => {
    const pg = fakePg();
    await pg.lifeUpsert(OWNER, { name: "Căn hộ", kind: "HOUSE", price: 1_000_000_000, down_pct: 30, loan_rate_pct: null, loan_years: 20, inflation_pct: 0, income_growth_pct: 0, extra_saving: 0, goal_id: null });
    const result = {
      actions: [
        { id: "s1", type: "CALL", call: { method: "POST", path: "/plans/events", body: { title: "Nhậu với nhóm Nam", date: "2026-12-05", people: ["Nam", "Lan", "Huy"] } }, lines: [] as string[] },
        { id: "s2", type: "CALL", call: { method: "POST", path: "/plans/life", body: { name: "Mua xe", price: 600_000_000 } }, lines: [] as string[] },
        { id: "s3", type: "ANSWER", what: "PLANS", data: null as unknown },
      ],
    };
    await enrichPlanActions({ cfg, gw, pg }, OWNER, result, new Date("2026-11-29T03:00:00Z"));
    expect(result.actions[0]!.lines![0]).toMatch(/^Dự kiến ~[\d.]+đ \(bạn trả ~[\d.]+đ sau khi chia\)/);
    expect(result.actions[0]!.lines![1]).toMatch(/^Khoảng /);
    expect(result.actions[1]!.lines![0]).toContain("Mua xe 600tr");
    expect((result.actions[2] as any).data.life[0]).toMatchObject({ name: "Căn hộ" });
    expect((result.actions[2] as any).data.monthly_saving).toBe(8_000_000);
  });

  it("resolveEvent: people → headcount, default time by kind", () => {
    const r = resolveEvent({ title: "Cà phê với Lan", date: "2026-12-01", people: ["Lan", "tôi"] });
    expect(r).toMatchObject({ kind: "CAFE", headcount: 2, people: ["Lan"], starts: "2026-12-01T08:00:00.000Z", ends: "2026-12-01T10:00:00.000Z" });
  });
});
