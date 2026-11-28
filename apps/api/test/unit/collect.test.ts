import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import {
  formatVnd,
  incomeProposalAmount,
  isIncomeTrigger,
  isQuiet,
  isSociable,
  milestonePush,
  monthEndAmount,
  monthEndTarget,
  pickGoal,
  reminderMessage,
  remindDuePush,
  settledPush,
  toneFor,
  type GoalPlan,
  type IncomeFacts,
  type ReminderInfo,
} from "../../src/modules/collect/collect";
import type { CollectGateway, SettleJson } from "../../src/modules/collect/gateway";
import { collectAfterTx, collectCandidate, runCollectSweep } from "../../src/entrypoints/routes-collect";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import { resolveAgentOutput, type AgentContext } from "../../src/modules/ai/agent";

const OWNER = "11111111-1111-4111-8111-111111111111";
// 10:00 and 23:30 in Vietnam
const DAY = new Date("2026-11-20T03:00:00Z");
const NIGHT = new Date("2026-11-20T16:30:00Z");

const info = (over: Partial<ReminderInfo> = {}): ReminderInfo => ({
  debt_id: "d1",
  direction: "RECEIVABLE",
  contact_alias: "Nam",
  remaining: "535000",
  principal: "535000",
  note: "tiền nhà",
  originated_at: "2026-11-05T02:00:00Z",
  due_date: null,
  overdue_days: 0,
  age_days: 15,
  memo: "MOMA 8F3A2B",
  memo_code: "8F3A2B",
  remind_count: 0,
  last_reminded_at: null,
  next_at: null,
  learned_days: null,
  contact_bank: null,
  ...over,
});

const plan = (over: Partial<GoalPlan> = {}): GoalPlan => ({
  id: "g1",
  name: "Laptop",
  target: "25000000",
  allocated: "0",
  left_amount: "25000000",
  pct: 0,
  due_date: "2027-11-20",
  months_left: 12,
  required_monthly: "2083334",
  pace_monthly: "0",
  eta: null,
  on_track: false,
  version: 1,
  ...over,
});

describe("formatting and clocks", () => {
  it("formats VND like the app", () => {
    expect(formatVnd(535000)).toBe("535.000đ");
    expect(formatVnd("1600000")).toBe("1.600.000đ");
  });
  it("quiet hours are 23:00–06:59 Vietnam time; reminders only 08:00–20:59", () => {
    expect(isQuiet(DAY)).toBe(false);
    expect(isQuiet(NIGHT)).toBe(true);
    expect(isQuiet(new Date("2026-11-20T00:30:00Z"))).toBe(false); // 07:30
    expect(isSociable(new Date("2026-11-20T00:30:00Z"))).toBe(false); // 07:30
    expect(isSociable(DAY)).toBe(true);
    expect(isSociable(new Date("2026-11-20T14:30:00Z"))).toBe(false); // 21:30
  });
  it("month-end proposals on the last two days and on the 1st for the month before", () => {
    expect(monthEndTarget(new Date("2026-11-29T03:00:00Z"))).toBe("2026-11");
    expect(monthEndTarget(new Date("2026-11-30T03:00:00Z"))).toBe("2026-11");
    expect(monthEndTarget(new Date("2026-12-01T03:00:00Z"))).toBe("2026-11");
    expect(monthEndTarget(new Date("2027-01-01T03:00:00Z"))).toBe("2026-12");
    expect(monthEndTarget(new Date("2026-11-15T03:00:00Z"))).toBeNull();
  });
});

describe("reminder messages", () => {
  it("first nudge is warm, names the thing and the memo code", () => {
    const m = reminderMessage(info());
    expect(m.tone).toBe("first");
    expect(m.text).toBe('Hi Nam, mình gửi bạn tiền nhà 535.000đ nhé. Bạn chuyển giúp mình qua mã QR này (nội dung "MOMA 8F3A2B") là được nha. Cảm ơn bạn nhiều!');
  });
  it("grows firmer with reminders / lateness but stays polite", () => {
    expect(toneFor({ remind_count: 1, overdue_days: 0 })).toBe("second");
    expect(toneFor({ remind_count: 0, overdue_days: 3 })).toBe("second");
    expect(toneFor({ remind_count: 2, overdue_days: 0 })).toBe("firm");
    expect(toneFor({ remind_count: 0, overdue_days: 20 })).toBe("firm");
    const firm = reminderMessage(info({ remind_count: 2 }));
    expect(firm.text).toContain("từ 05/11");
    expect(firm.text).toContain("trong tuần này");
    expect(firm.text).toContain("Cảm ơn bạn");
  });
  it("without a short note it says 'khoản tiền'", () => {
    expect(reminderMessage(info({ note: null })).text).toContain("khoản tiền 535.000đ");
    expect(reminderMessage(info({ note: "ăn lẩu" })).text).toContain("khoản ăn lẩu 535.000đ");
  });
  it("push texts batch several people", () => {
    expect(remindDuePush([{ alias: "Nam", remaining: 535000 }]).title).toBe("Nhắc Nam trả 535.000đ?");
    expect(remindDuePush([{ alias: "Nam", remaining: 535000 }, { alias: "Lan", remaining: 200000 }]).body).toContain("Nam 535.000đ, Lan 200.000đ");
    expect(settledPush([{ alias: "Nam", amount: 535000, note: "tiền nhà", direction: "RECEIVABLE" }]).title).toBe("Nam đã trả 535.000đ · tiền nhà");
    expect(settledPush([{ alias: "Huy", amount: 300000, note: null, direction: "PAYABLE" }]).title).toBe("Đã trả Huy 300.000đ");
    expect(milestonePush("Laptop", 50, 12_500_000, 25_000_000).title).toBe("🎉 Mục tiêu Laptop đã đạt 50%");
    expect(milestonePush("Laptop", 100, 25_000_000, 25_000_000).title).toBe("🎉 Hoàn thành mục tiêu Laptop!");
  });
});

describe("goal math", () => {
  const facts = (over: Partial<IncomeFacts> = {}): IncomeFacts => ({
    tx_id: "t", kind: "INCOME", status: "POSTED", source: "BANK", amount: "15000000", account_id: "a",
    category_name: "Lương", avg_monthly_income: "15000000", available: "20000000", ...over,
  });
  it("salary, bonus words or a large income trigger; small or non-income does not", () => {
    expect(isIncomeTrigger(facts())).toBe(true);
    expect(isIncomeTrigger(facts({ category_name: null, kind: "UNKNOWN_CREDIT" }), "CT LUONG THANG 11")).toBe(true);
    expect(isIncomeTrigger(facts({ category_name: null, amount: "8000000", avg_monthly_income: "15000000" }))).toBe(true); // ≥ 40%
    expect(isIncomeTrigger(facts({ category_name: null, amount: "4000000", avg_monthly_income: "15000000" }))).toBe(false);
    expect(isIncomeTrigger(facts({ amount: "2000000" }))).toBe(false);
    expect(isIncomeTrigger(facts({ kind: "EXPENSE" }))).toBe(false);
    expect(isIncomeTrigger(facts({ status: "VOID" }))).toBe(false);
  });
  it("proposes the required monthly saving rounded up to 50k, capped by what is left and free", () => {
    expect(incomeProposalAmount(plan(), 15_000_000, 20_000_000)).toBe(2_100_000);
    expect(incomeProposalAmount(plan({ left_amount: "1200000" }), 15_000_000, 20_000_000)).toBe(1_200_000);
    expect(incomeProposalAmount(plan(), 15_000_000, 1_234_567)).toBe(1_230_000);
    expect(incomeProposalAmount(plan({ required_monthly: null, due_date: null }), 15_000_000, 20_000_000)).toBe(1_500_000); // 10%
    expect(incomeProposalAmount(plan(), 15_000_000, 30_000)).toBeNull();
  });
  it("month-end puts the under-spend (≥ 100k, floor 50k) aside", () => {
    expect(monthEndAmount(320_000, 5_000_000, 25_000_000)).toBe(300_000);
    expect(monthEndAmount(90_000, 5_000_000, 25_000_000)).toBeNull();
    expect(monthEndAmount(800_000, 260_000, 25_000_000)).toBe(250_000);
  });
  it("picks the goal that is behind first, then the nearest due date", () => {
    const a = plan({ id: "a", on_track: true, due_date: "2027-01-01" });
    const b = plan({ id: "b", on_track: false, due_date: "2027-06-01" });
    const c = plan({ id: "c", on_track: null, due_date: null, left_amount: "0" });
    expect(pickGoal([a, b, c])!.id).toBe("b");
    expect(pickGoal([a, plan({ id: "d", on_track: true, due_date: "2026-12-31" })])!.id).toBe("d");
    expect(pickGoal([c])).toBeNull();
  });
});

// ---------------------------------------------------------------- hooks with a fake gateway
const cfg = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000, onesignalAppId: "app", onesignalRestKey: "key" } as Config;
const settle = (over: Partial<SettleJson> = {}): SettleJson => ({
  id: "s1", state: "AUTO", score: 100, hints: ["memo"], amount: "535000", created_at: "2026-11-20T03:00:00Z", repay_tx_id: "rp1", restored_tx_id: null,
  debt: { id: "d1", direction: "RECEIVABLE", contact_id: "c1", contact_alias: "Nam", principal: "535000", remaining: "0", note: "tiền nhà", state: "SETTLED" },
  money: { tx_id: "tx1", kind: "UNKNOWN_CREDIT", status: "VOID", amount: "535000", effective_at: "2026-11-20T03:00:00Z", note: "NAM", merchant: null, source: "BANK", account_id: "a1", account_name: "VCB", institution: "Vietcombank" },
  ...over,
});

function fakeCog(over: Partial<CollectGateway> = {}) {
  const claimed = new Set<string>();
  const cog = {
    tryTx: vi.fn(async () => ({ status: "NONE" as const })),
    sweep: vi.fn(async () => ({ checked: 0, auto: 0, suggested: 0, repaired: 0, failed: 0 })),
    suggestions: vi.fn(async () => [] as SettleJson[]),
    forTx: vi.fn(async () => settle()),
    recentAuto: vi.fn(async () => [] as SettleJson[]),
    decide: vi.fn(),
    undo: vi.fn(),
    undoByTx: vi.fn(),
    reminder: vi.fn(),
    due: vi.fn(async () => [] as ReminderInfo[]),
    markReminded: vi.fn(),
    snooze: vi.fn(),
    contactBank: vi.fn(),
    goalPlan: vi.fn(async () => [plan()]),
    incomeFacts: vi.fn(async () => null),
    propose: vi.fn(async () => ({ status: "PROPOSED" as const, id: "p1" })),
    proposals: vi.fn(async () => []),
    accept: vi.fn(),
    dismiss: vi.fn(),
    monthSurplus: vi.fn(),
    milestones: vi.fn(async () => []),
    repair: vi.fn(async () => 0),
    pushClaim: vi.fn(async (_o: string, k: string) => {
      if (claimed.has(k)) return false;
      claimed.add(k);
      return true;
    }),
    ...over,
  } as unknown as CollectGateway & Record<string, ReturnType<typeof vi.fn>>;
  return cog;
}
function pushSpy() {
  const sent: { title: string; body: string; route: string }[] = [];
  const f = vi.fn(async (url: string, init: RequestInit) => {
    if (String(url).includes("onesignal")) {
      const b = JSON.parse(String(init.body));
      sent.push({ title: b.headings?.vi ?? b.headings?.en, body: b.contents?.vi ?? b.contents?.en, route: b.data?.route });
    }
    return new Response("{}", { status: 200 });
  });
  vi.stubGlobal("fetch", f); // inbox RPC
  return { sent, f: f as unknown as typeof fetch };
}
const gw = { getOwnerId: vi.fn(async () => OWNER) } as unknown as FinanceGateway;

describe("collect hooks", () => {
  it("only new money-in / money-out commands are candidates", () => {
    expect(collectCandidate({ command_type: "TX_CREATE", payload: { kind: "UNKNOWN_CREDIT" } }, { status: "COMMITTED", tx_id: "t" })).toBe("t");
    expect(collectCandidate({ command_type: "TX_CREATE", payload: { kind: "TRANSFER" } }, { status: "COMMITTED", tx_id: "t" })).toBeUndefined();
    expect(collectCandidate({ command_type: "TX_CREATE", payload: { kind: "EXPENSE" } }, { status: "REPLAYED", tx_id: "t" })).toBeUndefined();
    expect(collectCandidate({ command_type: "DEBT_REPAY", payload: {} }, { status: "COMMITTED", tx_id: "t" })).toBeUndefined();
  });

  it("automatic settlement pushes once by day, waits at night; the sweep announces it in the morning in one push", async () => {
    const { sent, f } = pushSpy();
    const cog = fakeCog({ tryTx: vi.fn(async () => ({ status: "AUTO" as const, settle_id: "s1", repay_tx_id: "rp1", debt_id: "d1" })) });
    expect(await collectAfterTx({ cfg, gw, cog, pushFetch: f }, OWNER, "tx1", "test", { now: DAY })).toBe("AUTO");
    expect(sent).toEqual([{ title: "Nam đã trả 535.000đ · tiền nhà", body: expect.stringContaining("không tính là thu nhập"), route: "/tx/rp1" }]);

    sent.length = 0;
    const night = fakeCog({
      tryTx: vi.fn(async () => ({ status: "AUTO" as const, settle_id: "s2", repay_tx_id: "rp2" })),
      recentAuto: vi.fn(async () => [settle({ id: "s2", repay_tx_id: "rp2" }), settle({ id: "s3", repay_tx_id: "rp3", debt: { ...settle().debt, contact_alias: "Lan", note: null }, amount: "200000" })]),
    });
    await collectAfterTx({ cfg, gw, cog: night, pushFetch: f }, OWNER, "tx2", "test", { now: NIGHT });
    expect(sent).toEqual([]);
    await runCollectSweep({ cfg, gw, cog: night, pushFetch: f }, NIGHT);
    expect(sent).toEqual([]); // still night
    await runCollectSweep({ cfg, gw, cog: night, pushFetch: f }, DAY);
    expect(sent).toEqual([{ title: "Đã ghi 2 khoản trả nợ", body: expect.stringContaining("Nam 535.000đ, Lan 200.000đ"), route: "/planning?tab=0" }]);
    await runCollectSweep({ cfg, gw, cog: night, pushFetch: f }, DAY);
    expect(sent).toHaveLength(1); // claimed once
    vi.unstubAllGlobals();
  });

  it("no settlement: a salary proposes a goal allocation with one push", async () => {
    const { sent, f } = pushSpy();
    const cog = fakeCog({
      incomeFacts: vi.fn(async () => ({ tx_id: "t", kind: "INCOME", status: "POSTED", source: "BANK", amount: "15000000", account_id: "a1", category_name: "Lương", avg_monthly_income: "0", available: "20000000", note: null })),
    });
    expect(await collectAfterTx({ cfg, gw, cog, pushFetch: f }, OWNER, "t", "test", { now: DAY })).toBe("GOAL");
    expect(cog.propose).toHaveBeenCalledWith(OWNER, { goal_id: "g1", account_id: "a1", amount: "2100000", reason: "INCOME", period: "t", source_tx: "t" });
    expect(sent).toEqual([{ title: "Lương về 15.000.000đ 🎉", body: "Trích 2.100.000đ vào mục tiêu Laptop? Chạm để trích ngay.", route: "/planning?tab=1" }]);
    vi.unstubAllGlobals();
  });

  it("a failing gateway never throws out of the hook", async () => {
    const cog = fakeCog({ tryTx: vi.fn(async () => { throw new Error("db down"); }), incomeFacts: vi.fn(async () => { throw new Error("db down"); }) });
    await expect(collectAfterTx({ cfg, gw, cog }, OWNER, "t", "test", { now: DAY })).resolves.toBe("NONE");
  });

  it("reminders are pushed only in sociable hours, batched and once per stage", async () => {
    const { sent, f } = pushSpy();
    const cog = fakeCog({ due: vi.fn(async () => [info(), info({ debt_id: "d2", contact_alias: "Lan", remaining: "200000" }), info({ debt_id: "d3", direction: "PAYABLE", contact_alias: "Huy", remaining: "300000", due_date: "2026-11-21" })]) });
    await runCollectSweep({ cfg, gw, cog, pushFetch: f }, new Date("2026-11-20T00:30:00Z")); // 07:30
    expect(sent).toEqual([]);
    await runCollectSweep({ cfg, gw, cog, pushFetch: f }, DAY);
    expect(sent.map((s) => s.title)).toEqual(["Nhắc nợ 2 người?", "Sắp đến hạn trả Huy 300.000đ"]);
    expect(sent[1]!.route).toBe("/debts/remind/d3");
    await runCollectSweep({ cfg, gw, cog, pushFetch: f }, DAY);
    expect(sent).toHaveLength(2);
    vi.unstubAllGlobals();
  });
});

describe("assistant: Nhắc nợ from chat", () => {
  const ctx = (): AgentContext => ({
    today: "2026-11-20",
    nowIso: "2026-11-20T03:00:00.000Z",
    accounts: [{ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", name: "VCB", kind: "BANK" }],
    categories: [],
    contacts: [],
    debts: [
      { id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", direction: "RECEIVABLE", contact_alias: "Nam", remaining: "535000", state: "OPEN", overdue: true },
      { id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", direction: "RECEIVABLE", contact_alias: "Lan", remaining: "200000", state: "OPEN" },
      { id: "ffffffff-ffff-4fff-8fff-ffffffffffff", direction: "PAYABLE", contact_alias: "Huy", remaining: "300000", state: "OPEN", overdue: true },
    ],
    goals: [],
  });
  it("'nhắc Nam trả tiền' becomes a reminder card for that receivable", () => {
    const r = resolveAgentOutput({ reply: "Mình soạn sẵn tin nhắc Nam nhé.", steps: [{ do: "REMIND_DEBT", debt: "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }] }, ctx());
    expect(r.actions).toEqual([expect.objectContaining({ type: "REMIND", debt_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", title: "Nhắc Nam trả 535.000 ₫?" })]);
  });
  it("a payable or unknown debt is not a reminder; it asks instead", () => {
    const r = resolveAgentOutput({ steps: [{ do: "REMIND_DEBT", debt: "ffffffff-ffff-4fff-8fff-ffffffffffff" }] }, ctx());
    expect(r.actions[0]!.type).toBe("ASK");
  });
  it("talking about debts proactively offers to remind overdue receivables only", () => {
    const r = resolveAgentOutput({ steps: [{ do: "ANSWER", what: "DEBTS" }] }, ctx());
    expect(r.actions.map((a) => a.type)).toEqual(["ANSWER", "REMIND"]);
    expect((r.actions[1] as { debt_id: string }).debt_id).toBe("dddddddd-dddd-4ddd-8ddd-dddddddddddd");
  });
});