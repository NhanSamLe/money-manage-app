import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { analyzeBill, parseBillJson, readBillByRules, runSplitSweep, splitAfterTx, splitCandidate, vnToday } from "../../src/entrypoints/routes-splits";
import type { ProviderCall } from "../../src/modules/ai/assistant";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import { implementedCommand } from "../../src/modules/ledger/command-schemas";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { SplitGateway } from "../../src/modules/split/gateway";
import {
  appliedPush,
  computeShares,
  fold,
  matchContact,
  matchRule,
  missedPush,
  occurrenceWindow,
  proposedPush,
  roundUp,
  vnd,
  type SplitContext,
  type SplitRule,
} from "../../src/modules/split/split";

const OWNER = "11111111-1111-4111-8111-111111111111";
const TX = "22222222-2222-4222-8222-222222222222";
const RULE = "33333333-3333-4333-8333-333333333333";
const OCC = "44444444-4444-4444-8444-444444444444";
const VCB = "55555555-5555-4555-8555-555555555555";
const MOMO = "66666666-6666-4666-8666-666666666666";
const NAM = "77777777-7777-4777-8777-777777777777";
const LAN = "88888888-8888-4888-8888-888888888888";
const RENT = "99999999-9999-4999-8999-999999999999";
const FOOD = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

describe("computeShares", () => {
  it("1.600.000 for 3 incl. owner, rounded up to 5.000: others 535.000 each, owner 530.000", () => {
    const r = computeShares(1_600_000, [{ contact_id: NAM, name: "Nam" }, { contact_id: LAN, name: "Lan" }]);
    expect(r.shares.map((s) => s.amount)).toEqual([535_000, 535_000]);
    expect(r.owner_amount).toBe(530_000);
  });
  it("rounding steps: none / 1.000 / 10.000", () => {
    const ps = [{ name: "A" }, { name: "B" }];
    expect(computeShares(1_600_000, ps, { rounding: 0 }).shares[0]!.amount).toBe(533_334);
    expect(computeShares(1_600_000, ps, { rounding: 1000 }).shares[0]!.amount).toBe(534_000);
    expect(computeShares(1_600_000, ps, { rounding: 10000 }).shares[0]!.amount).toBe(540_000);
    expect(computeShares(1_600_000, ps, { rounding: 10000 }).owner_amount).toBe(520_000);
  });
  it("fixed and percent shares, equal remainder", () => {
    const r = computeShares(1_000_000, [
      { name: "A", mode: "FIXED", value: 200_000 },
      { name: "B", mode: "PERCENT", value: 30 },
      { name: "C" },
    ]);
    // 1.000.000 - 200.000 - 300.000 = 500.000 / (C + owner) = 250.000
    expect(r.shares.map((s) => s.amount)).toEqual([200_000, 300_000, 250_000]);
    expect(r.owner_amount).toBe(250_000);
  });
  it("owner not included: rounding never makes the others pay more than the bill", () => {
    const r = computeShares(1_000_000, [{ name: "A" }, { name: "B" }, { name: "C" }], { ownerShare: false });
    expect(r.shares.reduce((a, s) => a + s.amount, 0)).toBe(1_000_000);
    expect(r.owner_amount).toBe(0);
    expect(r.shares.map((s) => s.amount)).toEqual([335_000, 335_000, 330_000]);
  });
  it("rejects fixed shares above the bill and bad input", () => {
    expect(() => computeShares(100_000, [{ name: "A", mode: "FIXED", value: 200_000 }])).toThrow("SPLIT_INVALID");
    expect(() => computeShares(0, [])).toThrow("VALIDATION_FAILED");
    expect(() => computeShares(100_000, [{ name: "A", mode: "PERCENT", value: 120 }])).toThrow("VALIDATION_FAILED");
    expect(computeShares(100_000, []).owner_amount).toBe(100_000);
  });
  it("roundUp", () => {
    expect(roundUp(533_333.3, 5000)).toBe(535_000);
    expect(roundUp(535_000, 5000)).toBe(535_000);
    expect(roundUp(1.2, 0)).toBe(2);
  });
});

function rule(over: Partial<SplitRule> = {}): SplitRule {
  return {
    id: RULE,
    name: "Tiền nhà",
    amount: "1600000",
    account_id: VCB,
    interval: "MONTHLY",
    category_id: RENT,
    window_start: 5,
    window_end: 10,
    tolerance_pct: 10,
    payee_keywords: ["CO HOA"],
    rounding: 5000,
    owner_share: true,
    auto_apply: true,
    participants: [
      { contact_id: NAM, name: "Nam", mode: "EQUAL" },
      { contact_id: LAN, name: "Lan", mode: "EQUAL" },
    ],
    occurrences: [{ id: OCC, due_date: "2026-12-05" }],
    ...over,
  };
}

function ctx(over: Partial<SplitContext["tx"]> = {}, rules: SplitRule[] = [rule()], extra: Partial<SplitContext> = {}): SplitContext {
  return {
    tx: {
      id: TX,
      kind: "UNKNOWN_DEBIT",
      status: "POSTED",
      amount: "1600000",
      account_id: VCB,
      // 2026-12-06 10:00 in Vietnam
      effective_at: "2026-12-06T03:00:00Z",
      note: "CK TIEN NHA T12",
      merchant: null,
      category_id: null,
      source: "BANK",
      ...over,
    },
    live: null,
    matched_occurrence: false,
    dismissed_rules: [],
    rules,
    ...extra,
  };
}

describe("matchRule", () => {
  it("exact amount, right account, in the window -> AUTO", () => {
    const m = matchRule(ctx())!;
    expect(m.decision).toBe("AUTO");
    expect(m.occurrence.id).toBe(OCC);
    expect(m.hints).toContain("Đúng số tiền");
  });
  it("payment a little early (slack) still matches; far outside the window does not", () => {
    expect(matchRule(ctx({ effective_at: "2026-12-02T03:00:00Z" }))).not.toBeNull();
    expect(matchRule(ctx({ effective_at: "2026-12-20T03:00:00Z" }))).toBeNull();
    expect(matchRule(ctx({ effective_at: "2026-11-25T03:00:00Z" }))).toBeNull();
  });
  it("amount outside the tolerance does not match", () => {
    expect(matchRule(ctx({ amount: "1900000" }))).toBeNull();
  });
  it("close amount from another account without keywords -> PROPOSE", () => {
    const m = matchRule(ctx({ amount: "1650000", account_id: MOMO, note: "Thanh toan" }))!;
    expect(m.decision).toBe("PROPOSE");
  });
  it("exact amount from another account with the landlord's name -> AUTO", () => {
    expect(matchRule(ctx({ account_id: MOMO, note: "Chuyen tien cho Co Hoa" }))!.decision).toBe("AUTO");
  });
  it("rules with auto_apply off always propose; dismissed rules and already split bills are skipped", () => {
    expect(matchRule(ctx({}, [rule({ auto_apply: false })]))!.decision).toBe("PROPOSE");
    expect(matchRule(ctx({}, [rule()], { dismissed_rules: [RULE] }))).toBeNull();
    expect(matchRule(ctx({}, [rule()], { live: { id: "x", state: "PROPOSED" } }))).toBeNull();
    expect(matchRule(ctx({}, [rule()], { matched_occurrence: true }))).toBeNull();
    expect(matchRule(ctx({ kind: "INCOME" }))).toBeNull();
    expect(matchRule(ctx({ status: "VOID" }))).toBeNull();
  });
  it("plain recurring item (no window settings): needs ±1% and the account or its name", () => {
    const netflix = rule({ name: "Netflix", amount: "70000", window_start: null, window_end: null, payee_keywords: [], participants: [], occurrences: [{ id: OCC, due_date: "2026-12-06" }] });
    // A 65.000đ coffee must not become "Có phải Netflix?".
    expect(matchRule(ctx({ amount: "65000", note: "CAFE HIGHLANDS" }, [netflix]))).toBeNull();
    expect(matchRule(ctx({ amount: "70000", account_id: MOMO, note: "CAFE" }, [netflix]))).toBeNull();
    expect(matchRule(ctx({ amount: "70000", note: "x" }, [netflix]))!.decision).toBe("AUTO");
    expect(matchRule(ctx({ amount: "70000", account_id: MOMO, note: "NETFLIX.COM" }, [netflix]))).not.toBeNull();
  });
  it("two rules equally likely -> PROPOSE (never auto-picks between them)", () => {
    const other = rule({ id: "r2", name: "Tiền phòng", payee_keywords: [] });
    const m = matchRule(ctx({ note: "chuyen khoan" }, [rule({ payee_keywords: [] }), other]))!;
    expect(m.decision).toBe("PROPOSE");
  });
  it("window clamps to the month's last day", () => {
    expect(occurrenceWindow({ interval: "MONTHLY", window_start: 28, window_end: 31 }, "2027-02-28")).toEqual(["2027-02-25", "2027-03-03"]);
    expect(occurrenceWindow({ interval: "WEEKLY", window_start: null, window_end: null }, "2026-12-07")).toEqual(["2026-12-04", "2026-12-10"]);
  });
});

describe("texts and names", () => {
  it("push texts", () => {
    expect(vnd(1600000)).toBe("1.600.000đ");
    expect(appliedPush("tiền nhà", 1600000, [{ name: "Nam", amount: "535000" }, { name: "Lan", amount: 535000 }])).toEqual({
      title: "Đã ghi tiền nhà 1.600.000đ",
      body: "Nam nợ 535.000đ, Lan nợ 535.000đ · Chạm để xem hoặc hoàn tác",
    });
    expect(proposedPush("tiền nhà", 1600000, []).body).toBe("Chạm để xác nhận");
    expect(missedPush("tiền nhà", "2026-12-05", 5, 10)).toEqual({
      title: "Chưa thấy khoản tiền nhà tháng 12",
      body: "Thường trả ngày 5–10. Nếu đã trả, mở MoMa để ghi nhận.",
    });
  });
  it("matchContact: exact folded, unique partial, ambiguous -> null", () => {
    const cs = [
      { id: NAM, alias: "Nam Nguyễn" },
      { id: LAN, alias: "Lan" },
      { id: "x", alias: "Lan Anh" },
    ];
    expect(matchContact("nam", cs)?.id).toBe(NAM);
    expect(matchContact("LAN", cs)?.id).toBe(LAN);
    expect(matchContact("Hùng", cs)).toBeNull();
    expect(fold("Đức Hùng")).toBe("duc hung");
  });
  it("bill parsing", () => {
    expect(parseBillJson({ total: "1.240.000", category: "Ăn uống", items: "Lẩu, 6 bia", group: true, confidence: 0.9, people: [{ name: "Nam", amount: null }, { name: "" }] })).toEqual({
      total: 1240000,
      period: null,
      merchant: null,
      category: "Ăn uống",
      people: [{ name: "Nam", amount: null }],
      items: "Lẩu, 6 bia",
      group: true,
      confidence: 0.9,
    });
    expect(parseBillJson("x")).toBeNull();
    const r = readBillByRules("EVN HCMC\nTien dien thang 11\nTong cong thanh toan: 845.000 d", ["Ăn uống", "Hóa đơn điện"]);
    expect(r.total).toBe(845000);
    expect(r.category).toBe("Hóa đơn điện");
  });
  it("vnToday uses Vietnam time", () => {
    expect(vnToday(new Date("2026-12-31T18:00:00Z"))).toBe("2027-01-01");
  });
});

describe("command schemas", () => {
  const wrap = (command_type: string, payload: unknown) => ({ command_id: TX, command_type, schema_version: 1, payload });
  it("RECURRING_SPLIT_UPSERT / SPLIT_APPLY / SPLIT_UNDO / SPLIT_DISMISS", () => {
    expect(
      implementedCommand.safeParse(
        wrap("RECURRING_SPLIT_UPSERT", {
          name: "Tiền nhà",
          account_id: VCB,
          amount: "1600000",
          category_id: RENT,
          next_date: "2026-12-05",
          enabled: true,
          window_start: 5,
          window_end: 10,
          rounding: 5000,
          participants: [{ contact_id: NAM, mode: "EQUAL" }],
        }),
      ).success,
    ).toBe(true);
    expect(implementedCommand.safeParse(wrap("RECURRING_SPLIT_UPSERT", { name: "x", account_id: VCB, amount: "1", category_id: RENT, next_date: "2026-12-05", enabled: true, window_start: 10, window_end: 5 })).success).toBe(false);
    expect(implementedCommand.safeParse(wrap("SPLIT_APPLY", { tx_id: TX, shares: [{ name: "Nam", amount: "535000" }] })).success).toBe(true);
    expect(implementedCommand.safeParse(wrap("SPLIT_APPLY", { tx_id: TX, shares: [{ amount: "535000" }] })).success).toBe(false);
    expect(implementedCommand.safeParse(wrap("SPLIT_UNDO", { application_id: TX })).success).toBe(true);
    expect(implementedCommand.safeParse(wrap("SPLIT_DISMISS", { application_id: TX })).success).toBe(true);
  });
});

// ---------------------------------------------------------------- hooks with a fake gateway

function fakeSg(c: SplitContext | null) {
  const sg = {
    syncOccurrences: vi.fn(async () => 0),
    context: vi.fn(async () => c),
    apply: vi.fn(async (_o: string, req: any) => ({
      application_id: "app-1",
      tx_id: req.tx_id,
      shares: req.shares.map((s: any, i: number) => ({ contact_id: s.contact_id ?? `c${i}`, name: s.name ?? "?", amount: s.amount, debt_id: `d${i}` })),
      owner_amount: "530000",
    })),
    propose: vi.fn(async (_o: string, _req: any) => ({ status: "PROPOSED" as const, application_id: "app-2" })),
    undo: vi.fn(async () => ({ application_id: "app-1", state: "UNDONE", debts_cancelled: 2 })),
    dismiss: vi.fn(async () => ({ application_id: "app-2", state: "DISMISSED" })),
    list: vi.fn(async () => []),
    missed: vi.fn(async () => [] as any[]),
    ruleSuggestions: vi.fn(async () => []),
    recentDebits: vi.fn(async () => [] as string[]),
    pushClaim: vi.fn(async () => true),
    billAnnotate: vi.fn(async (_o: string, txId: string) => ({ tx_id: txId, reclassified: true, previous: { kind: "UNKNOWN_DEBIT", category_id: null, merchant: null, note: "CK" } })),
  };
  return sg as unknown as SplitGateway & typeof sg;
}

const cfg: Config = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000, onesignalRestKey: "rk", onesignalAppId: "app" };
let pushes: any[] = [];
const pushFetch = vi.fn(async (_u: any, init: any) => {
  pushes.push(JSON.parse(String(init.body)));
  return new Response("{}", { status: 200 });
});

function gw(extra: Record<string, unknown> = {}) {
  return {
    getOwnerId: vi.fn(async () => OWNER),
    readContacts: vi.fn(async () => [
      { id: NAM, alias: "Nam" },
      { id: LAN, alias: "Lan" },
    ]),
    readCategories: vi.fn(async () => [
      { id: RENT, name: "Nhà ở", type: "EXPENSE" },
      { id: FOOD, name: "Ăn uống", type: "EXPENSE" },
    ]),
    aiReserve: vi.fn(async () => ({ id: "r" })),
    aiSettle: vi.fn(async () => ({})),
    aiMarkUnknown: vi.fn(async () => ({})),
    ...extra,
  } as unknown as FinanceGateway;
}

beforeEach(() => {
  pushes = [];
  // Inbox writes (sendPush -> pf_notification_add) go to the fake Supabase URL.
  vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 200 })));
});
afterEach(() => vi.unstubAllGlobals());

describe("splitAfterTx", () => {
  it("AUTO: applies category, occurrence and the two debts, then pushes the summary", async () => {
    const sg = fakeSg(ctx());
    expect(await splitAfterTx({ cfg, gw: gw(), sg, pushFetch }, OWNER, TX, "test")).toBe("APPLIED");
    const req = sg.apply.mock.calls[0]![1];
    expect(req).toMatchObject({ tx_id: TX, category_id: RENT, recurring_id: RULE, occurrence_id: OCC, source: "RECURRING", merchant: "Tiền nhà" });
    expect(req.shares).toEqual([
      { contact_id: NAM, name: "Nam", amount: "535000" },
      { contact_id: LAN, name: "Lan", amount: "535000" },
    ]);
    expect(pushes[0].headings.vi ?? pushes[0].headings.en).toBe("Đã ghi Tiền nhà 1.600.000đ");
    expect(pushes[0].contents.vi ?? pushes[0].contents.en).toBe("Nam nợ 535.000đ, Lan nợ 535.000đ · Chạm để xem hoặc hoàn tác");
    expect(pushes[0].data.route).toBe(`/tx/${TX}`);
  });
  it("PROPOSE: stores a proposal with the computed shares", async () => {
    const sg = fakeSg(ctx({ amount: "1650000", account_id: MOMO, note: "x" }));
    expect(await splitAfterTx({ cfg, gw: gw(), sg, pushFetch }, OWNER, TX, "test")).toBe("PROPOSED");
    expect(sg.apply).not.toHaveBeenCalled();
    expect(sg.propose.mock.calls[0]![1]).toMatchObject({ tx_id: TX, recurring_id: RULE, owner_amount: String(1_650_000 - 2 * 550_000) });
  });
  it("plain rule (nobody owes anything): matched quietly, no extra push", async () => {
    const plain = rule({ participants: [], window_start: null, window_end: null, occurrences: [{ id: OCC, due_date: "2026-12-06" }] });
    const sg = fakeSg(ctx({}, [plain]));
    expect(await splitAfterTx({ cfg, gw: gw(), sg, pushFetch }, OWNER, TX, "t")).toBe("APPLIED");
    expect(pushes).toEqual([]);
  });
  it("no rule / failures never throw", async () => {
    expect(await splitAfterTx({ cfg, gw: gw(), sg: fakeSg(ctx({}, [])) }, OWNER, TX, "t")).toBe("NONE");
    const sg = fakeSg(ctx());
    sg.apply.mockRejectedValueOnce(new Error("boom"));
    expect(await splitAfterTx({ cfg, gw: gw(), sg }, OWNER, TX, "t")).toBe("NONE");
    expect(await splitAfterTx({ cfg, gw: gw(), sg }, OWNER, undefined, "t")).toBe("NONE");
  });
  it("syncs occurrences first when the context has none", async () => {
    const sg = fakeSg(ctx({}, [rule({ occurrences: [] })]));
    await splitAfterTx({ cfg, gw: gw(), sg }, OWNER, TX, "t");
    expect(sg.syncOccurrences).toHaveBeenCalled();
  });
  it("splitCandidate: committed TX_CREATE money-out only", () => {
    expect(splitCandidate({ command_type: "TX_CREATE", payload: { kind: "EXPENSE" } }, { status: "COMMITTED", tx_id: TX })).toBe(TX);
    expect(splitCandidate({ command_type: "TX_CREATE", payload: { kind: "INCOME" } }, { status: "COMMITTED", tx_id: TX })).toBeUndefined();
    expect(splitCandidate({ command_type: "TX_CREATE", payload: { kind: "EXPENSE" } }, { status: "REPLAYED", tx_id: TX })).toBeUndefined();
  });
});

describe("runSplitSweep", () => {
  it("re-checks recent payments and reminds a missed window once", async () => {
    const sg = fakeSg(ctx());
    sg.recentDebits.mockResolvedValue([TX]);
    sg.missed.mockResolvedValue([{ occurrence_id: OCC, recurring_id: RULE, name: "tiền nhà", amount: "1600000", due_date: "2026-11-05", window_start: 5, window_end: 10 }]);
    const r = await runSplitSweep({ cfg, gw: gw(), sg, pushFetch }, new Date("2026-11-12T03:00:00Z"));
    expect(r).toEqual({ checked: 1, applied: 1, proposed: 0, reminded: 1 });
    expect(sg.pushClaim).toHaveBeenCalledWith(OWNER, `split-missed:${OCC}`);
    expect(pushes.map((p) => p.headings.vi ?? p.headings.en)).toContain("Chưa thấy khoản tiền nhà tháng 11");
    sg.pushClaim.mockResolvedValue(false);
    pushes = [];
    sg.recentDebits.mockResolvedValue([]);
    expect((await runSplitSweep({ cfg, gw: gw(), sg, pushFetch }))!.reminded).toBe(0);
    expect(pushes).toEqual([]);
  });
});

// ---------------------------------------------------------------- bill analysis

function aiReturning(json: unknown): ProviderCall {
  return vi.fn(async () => ({ content: JSON.stringify(json), usage: { prompt_tokens: 10, completion_tokens: 10 } })) as unknown as ProviderCall;
}

describe("analyzeBill", () => {
  const foodTx = { kind: "UNKNOWN_DEBIT", amount: "1240000", note: "VCB 0001 TT", effective_at: "2026-12-20T12:00:00Z" };
  it("confident reading: category + merchant + item note applied in place, nothing to split for a solo bill", async () => {
    const sg = fakeSg(ctx(foodTx, []));
    const ai = aiReturning({ total: 1240000, category: "Ăn uống", merchant: "Lẩu Hội An", items: "Lẩu, 6 bia", group: false, confidence: 0.9, people: [] });
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai }, OWNER, TX, "LAU HOI AN ... TONG 1.240.000");
    expect(sg.billAnnotate).toHaveBeenCalledWith(OWNER, TX, { category_id: FOOD, merchant: "Lẩu Hội An", note: "Lẩu, 6 bia" });
    expect(r.updated?.previous.note).toBe("CK");
    expect(r.amount_mismatch).toBeNull();
    expect(r.split).toBe("NONE");
    expect(sg.propose).not.toHaveBeenCalled();
  });
  it("total differs from the recorded amount: warning only, money untouched", async () => {
    const sg = fakeSg(ctx(foodTx, []));
    const ai = aiReturning({ total: 1340000, category: "Ăn uống", confidence: 0.9 });
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai }, OWNER, TX, "...");
    expect(r.amount_mismatch).toEqual({ bill_total: "1340000", tx_amount: "1240000" });
    expect(JSON.stringify(sg.billAnnotate.mock.calls)).not.toContain("1340000");
  });
  it("group bill: split proposal (people named on the bill, equal shares rounded)", async () => {
    const sg = fakeSg(ctx(foodTx, []));
    const ai = aiReturning({ total: 1240000, category: "Ăn uống", items: "Lẩu", group: true, confidence: 0.9, people: [{ name: "nam" }, { name: "Hùng" }] });
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai }, OWNER, TX, "...");
    expect(r.split).toBe("PROPOSED");
    const p = sg.propose.mock.calls[0]![1];
    expect(p.source).toBe("BILL");
    // 1.240.000 / 3 = 413.333 -> 415.000; Nam matched to the contact, Hùng is a new person.
    expect(p.shares).toEqual([
      { contact_id: NAM, name: "Nam", amount: "415000" },
      { contact_id: null, name: "Hùng", amount: "415000" },
    ]);
  });
  it("group bill without names: empty proposal (the app asks who)", async () => {
    const sg = fakeSg(ctx(foodTx, []));
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai: aiReturning({ category: "Ăn uống", group: true, confidence: 0.9 }) }, OWNER, TX, "...");
    expect(r.split).toBe("PROPOSED");
    expect(sg.propose.mock.calls[0]![1].shares).toEqual([]);
  });
  it("unsure reading: one-tap suggestion, nothing applied", async () => {
    const sg = fakeSg(ctx(foodTx, []));
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai: aiReturning({ category: "Ăn uống", confidence: 0.55 }) }, OWNER, TX, "...");
    expect(sg.billAnnotate).not.toHaveBeenCalled();
    expect(r.suggestion).toMatchObject({ category_id: FOOD, confidence: 0.55 });
  });
  it("a recurring rule for the bill applies at once", async () => {
    const sg = fakeSg(ctx());
    const r = await analyzeBill({ cfg, gw: gw(), sg, ai: aiReturning({ category: "Nhà ở", confidence: 0.9 }) }, OWNER, TX, "HOP DONG THUE NHA");
    expect(r.split).toBe("APPLIED");
    expect(sg.apply).toHaveBeenCalled();
  });
  it("AI off: keyword fallback still finds the category", async () => {
    const sg = fakeSg(ctx({ ...foodTx, amount: "845000" }, []));
    const g = gw({ readCategories: vi.fn(async () => [{ id: RENT, name: "Hóa đơn điện", type: "EXPENSE" }]) });
    const r = await analyzeBill({ cfg, gw: g, sg }, OWNER, TX, "EVN tien dien. Tong cong: 845.000");
    expect(r.reading.category).toBe("Hóa đơn điện");
    expect(r.suggestion?.category_id).toBe(RENT);
  });
});

describe("routes", () => {
  const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };
  const env = {} as never;
  function app(sg: SplitGateway, ai?: ProviderCall) {
    const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "s" })) } as unknown as SessionVerifier;
    return buildApp(() => ({ cfg, gw: gw(), verifier, sg, ...(ai ? { ai } : {}) }) as any);
  }
  it("POST /v1/splits/propose computes shares and matches names", async () => {
    const sg = fakeSg(ctx({ amount: "1600000" }, []));
    const res = await app(sg).request("/v1/splits/propose", { method: "POST", headers, body: JSON.stringify({ tx_id: TX, participants: [{ name: "nam" }, { name: "Hùng" }] }) }, env);
    expect(res.status).toBe(200);
    const data = ((await res.json()) as any).data;
    expect(data.shares).toEqual([
      { contact_id: NAM, name: "Nam", amount: 535000 },
      { contact_id: null, name: "Hùng", amount: 535000 },
    ]);
    expect(data.unresolved).toEqual(["Hùng"]);
    expect(data.owner_amount).toBe("530000");
  });
  it("POST /v1/splits/apply with participants and with a proposal id", async () => {
    const sg = fakeSg(ctx({ amount: "1600000" }, []));
    const a = app(sg);
    expect((await a.request("/v1/splits/apply", { method: "POST", headers, body: JSON.stringify({ tx_id: TX, participants: [{ contact_id: NAM }, { contact_id: LAN }], rounding: 5000 }) }, env)).status).toBe(200);
    expect(sg.apply.mock.calls[0]![1].shares.map((s: any) => s.amount)).toEqual(["535000", "535000"]);
    sg.list.mockResolvedValueOnce([{ id: "app-2", shares: [{ contact_id: NAM, name: "Nam", amount: "100000" }], category_id: FOOD }] as any);
    expect((await a.request("/v1/splits/apply", { method: "POST", headers, body: JSON.stringify({ tx_id: TX, application_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab" }) }, env)).status).toBe(404);
    sg.list.mockResolvedValueOnce([{ id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab", shares: [{ contact_id: NAM, name: "Nam", amount: "100000" }], category_id: FOOD }] as any);
    expect((await a.request("/v1/splits/apply", { method: "POST", headers, body: JSON.stringify({ tx_id: TX, application_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab" }) }, env)).status).toBe(200);
    expect(sg.apply.mock.calls[1]![1]).toMatchObject({ category_id: FOOD, application_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab", shares: [{ contact_id: NAM, amount: "100000" }] });
    expect((await a.request("/v1/splits/apply", { method: "POST", headers, body: JSON.stringify({ tx_id: TX }) }, env)).status).toBe(400);
  });
  it("undo / dismiss / list / analyze / validation", async () => {
    const sg = fakeSg(ctx({ kind: "EXPENSE" }, []));
    const a = app(sg, aiReturning({ category: "Ăn uống", confidence: 0.9 }));
    expect((await a.request(`/v1/splits/${TX}/undo`, { method: "POST", headers }, env)).status).toBe(200);
    expect((await a.request(`/v1/splits/${TX}/dismiss`, { method: "POST", headers }, env)).status).toBe(200);
    expect((await a.request(`/v1/splits?tx_id=${TX}`, { headers }, env)).status).toBe(200);
    expect((await a.request(`/v1/splits?state=BOGUS`, { headers }, env)).status).toBe(400);
    expect((await a.request("/v1/splits/nope/undo", { method: "POST", headers }, env)).status).toBe(400);
    const an = await a.request("/v1/bills/analyze", { method: "POST", headers, body: JSON.stringify({ tx_id: TX, text: "QUAN AN" }) }, env);
    expect(an.status).toBe(200);
    expect(((await an.json()) as any).data.updated.category_id).toBe(FOOD);
  });
});
