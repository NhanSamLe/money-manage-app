import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { splitHabitsFrom, splitLearnings, filterTxs, undoCommand } from "../../src/entrypoints/routes-agent";
import { resolveAgentOutput, type AgentContext, type AgentTx } from "../../src/modules/ai/agent";
import { PHOTO_PREFIX, type MemoryEntry } from "../../src/modules/ai/memory";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import { COMMAND_TOOLS, payloadHint, riskOf, toolCatalogText } from "../../src/modules/ai/tools";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import { IMPLEMENTED_TYPES } from "../../src/modules/ledger/command-schemas";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const OWNER = U(900);
const NOW = "2026-11-28T12:40:00.000Z"; // 19:40 in Vietnam

const tx = (n: number, amount: string, over: Partial<AgentTx> = {}): AgentTx => ({
  id: U(n), kind: "EXPENSE", status: "POSTED", amount, effective_at: "2026-11-28T05:00:00.000Z", account_id: U(2), category_id: U(10), note: null, merchant: null, version: 2, ...over,
});

function makeCtx(over: Partial<AgentContext> = {}): AgentContext {
  return {
    today: "2026-11-28",
    nowIso: NOW,
    accounts: [
      { id: U(1), name: "Tiền mặt", kind: "CASH", balance: "500000", version: 1 },
      { id: U(2), name: "Vietcombank", kind: "BANK", balance: "9000000", version: 3 },
    ],
    categories: [
      { id: U(10), name: "Ăn uống", type: "EXPENSE", version: 1 },
      { id: U(11), name: "Lương", type: "INCOME", version: 1 },
      { id: U(12), name: "Giải trí", type: "EXPENSE", version: 1 },
    ],
    contacts: [
      { id: U(20), alias: "Nam", version: 1 },
      { id: U(21), alias: "Lan", version: 1 },
    ],
    debts: [{ id: U(30), direction: "RECEIVABLE", contact_alias: "Nam", remaining: "500000", state: "OPEN", version: 2, payments: [{ id: U(31), tx_id: U(32) }] }],
    goals: [{ id: U(40), name: "Laptop", target: "30000000", allocated: "0", version: 1 }],
    txs: [tx(50, "35000", { note: "cà phê sáng", effective_at: "2026-11-27T01:00:00.000Z" }), tx(51, "120000", { note: "grab", category_id: U(12) })],
    budgets: [{ id: U(60), month: "2026-11", category_id: U(10), limit: "3000000", carryover: false, version: 1 }],
    recurring: [{ id: U(70), name: "Tiền nhà", version: 1, occurrences: [{ id: U(71), version: 1 }] }],
    defaultAccountId: U(1),
    lastTx: { id: U(50), version: 2 },
    ...over,
  };
}

/** One valid payload per implemented command. A new command without a sample fails the coverage test below. */
const SAMPLES: Record<string, Record<string, unknown>> = {
  ACCOUNT_CREATE: { kind: "WALLET", institution: "MoMo", name: "MoMo" },
  ACCOUNT_UPDATE: { account_id: U(2), expected_version: 3, name: "VCB chính" },
  TX_CREATE: { kind: "EXPENSE", account_id: U(1), amount: "30000", effective_at: NOW, category_id: U(10) },
  TX_ANNOTATE: { tx_id: U(50), expected_version: 2, category_id: U(12) },
  TX_CORRECT: { tx_id: U(50), reason: "Sửa số tiền", expected_version: 2, replacement: { kind: "EXPENSE", account_id: U(1), amount: "40000", effective_at: NOW, category_id: U(10) } },
  TX_REVERSE: { tx_id: U(50), reason: "Nhập nhầm", expected_version: 2 },
  CONTACT_CREATE: { alias: "Huy" },
  CONTACT_UPDATE: { contact_id: U(20), expected_version: 1, alias: "Nam béo" },
  DEBT_CREATE: { direction: "RECEIVABLE", contact_id: U(20), principal: "200000", originated_at: NOW, account_id: U(1) },
  DEBT_REPAY: { debt_id: U(30), account_id: U(1), principal: "100000", effective_at: NOW, expected_version: 2 },
  DEBT_WRITE_OFF: { debt_id: U(30), amount: "100000", reason: "Khó đòi", effective_at: NOW, expected_version: 2 },
  DEBT_UPDATE: { debt_id: U(30), expected_version: 2, note: "Hẹn cuối tháng" },
  DEBT_PAYMENT_REVERSE: { debt_id: U(30), payment_id: U(31), expected_version: 2 },
  DEBT_CANCEL: { debt_id: U(30), expected_version: 2 },
  GOAL_CREATE: { name: "Du lịch", target: "10000000" },
  GOAL_ALLOCATE: { goal_id: U(40), account_id: U(2), amount: "1000000", expected_version: 1 },
  GOAL_RELEASE: { goal_id: U(40), account_id: U(2), amount: "1000000", expected_version: 1 },
  BUDGET_UPSERT: { month: "2026-11", limit: "4000000", carryover: false, category_id: U(10), expected_version: 1 },
  CATEGORY_UPSERT: { name: "Thú cưng", type: "EXPENSE" },
  RECURRING_UPSERT: { name: "Netflix", kind: "EXPENSE", account_id: U(2), amount: "260000", interval: "MONTHLY", next_date: "2026-12-05", enabled: true, category_id: U(12) },
  OCCURRENCE_MATCH: { occurrence_id: U(71), tx_id: U(51), expected_version: 1 },
  PROFILE_UPDATE: { expected_version: 1, display_name: "Sâm" },
  RECURRING_SPLIT_UPSERT: { name: "Tiền nhà", account_id: U(2), amount: "1600000", category_id: U(10), next_date: "2026-12-05", enabled: true, window_start: 5, window_end: 10, participants: [{ contact_id: U(20), mode: "EQUAL" }] },
  SPLIT_APPLY: { tx_id: U(51), shares: [{ contact_id: U(20), amount: "40000" }, { name: "Huy", amount: "40000" }] },
  SPLIT_UNDO: { application_id: U(51) },
  SPLIT_DISMISS: { application_id: U(51) },
};

describe("tool catalogue covers 100% of the finance commands", () => {
  it("every implemented command has a tier, a Vietnamese description, a payload hint and a catalogue line", () => {
    const text = toolCatalogText();
    for (const t of IMPLEMENTED_TYPES) {
      expect(COMMAND_TOOLS[t], `missing tool for ${t}`).toBeDefined();
      expect(COMMAND_TOOLS[t]!.vi.length, t).toBeGreaterThan(5);
      expect(payloadHint(t), t).not.toBe("");
      expect(text).toContain(`- ${t} [`);
    }
    expect(Object.keys(COMMAND_TOOLS).every((t) => IMPLEMENTED_TYPES.has(t))).toBe(true);
  });

  it("every implemented command is reachable through a CMD step with real ids", () => {
    const ctx = makeCtx();
    for (const t of IMPLEMENTED_TYPES) {
      expect(SAMPLES[t], `add a sample payload for ${t}`).toBeDefined();
      const r = resolveAgentOutput({ steps: [{ do: "CMD", type: t, payload: SAMPLES[t] }] }, ctx);
      const a = r.actions[0]!;
      expect(a.type, `${t}: ${JSON.stringify(a)}`).toBe("COMMAND");
      if (a.type === "COMMAND") expect(a.command.command_type).toBe(t);
    }
  });

  it("payload hints are generated from the schemas", () => {
    expect(payloadHint("TX_REVERSE")).toBe("tx_id:id,reason:chữ,expected_version:số");
    expect(payloadHint("BUDGET_UPSERT")).toContain("month:YYYY-MM");
    expect(payloadHint("TX_CREATE")).toContain("amount:VND");
  });
});

describe("CMD safety", () => {
  it("ids the agent was never shown, refs to later steps and malformed payloads become questions", () => {
    const ctx = makeCtx();
    const r = resolveAgentOutput(
      {
        steps: [
          { do: "CMD", type: "TX_REVERSE", payload: { tx_id: U(999), reason: "x", expected_version: 1 } },
          { do: "CMD", type: "TX_ANNOTATE", payload: { tx_id: "$s3.tx_id", expected_version: 1, note: "x" } },
          { do: "CMD", type: "TX_CREATE", payload: { kind: "EXPENSE", account_id: U(1), amount: "-5", effective_at: NOW, category_id: U(10) } },
          { do: "CMD", type: "DEVICE_REVOKE", payload: {} },
        ],
      },
      ctx,
    );
    expect(r.actions.map((a) => a.type)).toEqual(["ASK", "ASK", "ASK", "ASK"]);
  });

  it("chains: a later step may use an earlier step's result; TX_CREATE is always attributed to the AI", () => {
    const r = resolveAgentOutput(
      {
        steps: [
          { do: "CMD", type: "CONTACT_CREATE", payload: { alias: "Huy" } },
          { do: "CMD", type: "DEBT_CREATE", payload: { direction: "RECEIVABLE", contact_id: "$s1.contact_id", principal: "100000", originated_at: NOW, account_id: U(1) } },
          { do: "CMD", type: "TX_CREATE", payload: { kind: "EXPENSE", account_id: U(1), amount: "10000", effective_at: NOW, category_id: U(10), source: "MANUAL" } },
        ],
      },
      makeCtx(),
    );
    expect(r.actions.map((a) => a.type)).toEqual(["COMMAND", "COMMAND", "COMMAND"]);
    const [, debt, created] = r.actions;
    if (debt?.type === "COMMAND") expect(debt.command.payload.contact_id).toBe("$s1.contact_id");
    if (created?.type === "COMMAND") expect(created.command.payload.source).toBe("AI");
  });

  it("tiers: destructive or large needs one tap, everyday writes run by themselves, bulk is confirmed", () => {
    expect(riskOf("TX_REVERSE", {})).toBe("high");
    expect(riskOf("DEBT_CANCEL", {})).toBe("high");
    expect(riskOf("ACCOUNT_UPDATE", { archived: true })).toBe("high");
    expect(riskOf("TX_CREATE", { amount: "25000000" })).toBe("high");
    expect(riskOf("TX_CREATE", { amount: "25000" })).toBe("low");
    expect(riskOf("DEBT_UPDATE", { principal: "1000" })).toBe("high");
    const many = Array.from({ length: 7 }, () => ({ do: "CMD", type: "CONTACT_CREATE", payload: { alias: "A" } }));
    const r = resolveAgentOutput({ steps: many }, makeCtx());
    expect(r.actions.every((a) => a.type === "COMMAND" && a.risk === "high")).toBe(true);
  });

  it("every executed step carries an undo: creates reverse, debts cancel, annotations restore the old values", () => {
    const r = resolveAgentOutput(
      {
        steps: [
          { do: "EXPENSE", amount: "30000", account: U(1), category: U(10) },
          { do: "CMD", type: "TX_ANNOTATE", payload: { tx_id: U(51), expected_version: 2, category_id: U(10), note: "grab đi làm" } },
          { do: "CMD", type: "GOAL_ALLOCATE", payload: SAMPLES.GOAL_ALLOCATE },
          { do: "CMD", type: "BUDGET_UPSERT", payload: SAMPLES.BUDGET_UPSERT },
        ],
      },
      makeCtx(),
    );
    const undo = r.actions.map((a) => (a.type === "COMMAND" ? a.undo?.ops : undefined));
    expect(undo[0]).toEqual([{ op: "REVERSE_TX", tx_id: "$result.tx_id" }]);
    expect(undo[1]).toEqual([{ op: "RESTORE_TX", tx_id: U(51), fields: { category_id: U(12), note: "grab" } }]);
    expect(undo[2]).toEqual([{ op: "GOAL_MOVE", command_type: "GOAL_RELEASE", goal_id: U(40), account_id: U(2), amount: "1000000" }]);
    expect(undo[3]).toEqual([{ op: "RESTORE_BUDGET", month: "2026-11", category_id: U(10), limit: "3000000", carryover: false }]);
  });
});

describe("lookups", () => {
  it("filters by text (accent-insensitive), amount, account and Vietnam-local dates", () => {
    const txs = [tx(1, "35000", { note: "Cà phê sáng", effective_at: "2026-11-27T01:00:00Z" }), tx(2, "120000", { merchant: "Grab", effective_at: "2026-11-26T16:30:00Z" }), tx(3, "50000", { status: "VOID", note: "ca phe" })];
    expect(filterTxs(txs, { what: "TRANSACTIONS", q: "ca phe" }).map((t) => t.id)).toEqual([U(1)]);
    expect(filterTxs(txs, { what: "TRANSACTIONS", min: 100000 }).map((t) => t.id)).toEqual([U(2)]);
    // 16:30 UTC on the 26th is 23:30 on the 26th in Vietnam.
    expect(filterTxs(txs, { what: "TRANSACTIONS", since: "2026-11-27" }).map((t) => t.id)).toEqual([U(1)]);
    expect(filterTxs(txs, { what: "TRANSACTIONS", until: "2026-11-26" }).map((t) => t.id)).toEqual([U(2)]);
  });
});

describe("habits", () => {
  const mem = (kind: MemoryEntry["kind"], key: string, value: Record<string, unknown>, weight = 0.8) => ({ id: key, kind, key, value, weight, hits: 1 }) as unknown as MemoryEntry;
  it("reads groups, rounding and 'không chia' bill types from memory (weak entries ignored)", () => {
    const h = splitHabitsFrom([
      mem("HABIT", "chia bill lan nam", { names: ["Nam", "Lan"] }, 0.9),
      mem("HABIT", "chia bill huy", { names: ["Huy"] }, 0.1),
      mem("HABIT", "khong chia personal", { purpose: "PERSONAL" }, 0.7),
      mem("PREFERENCE", "lam tron phan chia", { rounding: 1000 }),
    ]);
    expect(h.groups).toEqual([{ names: ["Nam", "Lan"], weight: 0.9 }]);
    expect([...h.noSplit]).toEqual(["PERSONAL"]);
    expect(h.rounding).toBe(1000);
  });

  it("learns the group the owner named, an explicit rounding, and 'không chia' for a pending bill type", () => {
    const named = splitLearnings("chia Nam với Lan, làm tròn 1000", [{ do: "SPLIT", people: ["Nam", "Lan", "tôi"], rounding: 1000 }], undefined);
    expect(named.map((m) => m.key)).toEqual(["chia bill lan nam", "lam tron phan chia"]);
    const no = splitLearnings("không chia đâu", [{ do: "EXPENSE", amount: "849000" }], { steps: [{ do: "SPLIT_PENDING", data: { purpose: "EATOUT" } }] });
    expect(no).toEqual([expect.objectContaining({ kind: "HABIT", key: "khong chia eatout", value: expect.objectContaining({ purpose: "EATOUT" }) })]);
  });
});

// ---------------------------------------------------------------- the HTTP flow with a faked model
const cfg: Config = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000 };
const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };
const env = {} as never;

function fakeMg(rows: MemoryEntry[] = []) {
  return {
    list: vi.fn(async () => rows),
    relevant: vi.fn(async () => []),
    upsert: vi.fn(async () => null),
    upsertMany: vi.fn(async () => 0),
  } as unknown as MemoryGateway & { upsert: ReturnType<typeof vi.fn>; upsertMany: ReturnType<typeof vi.fn> };
}

function makeApp(replies: unknown[], opts: { txs?: AgentTx[]; mg?: ReturnType<typeof fakeMg>; debts?: unknown[] } = {}) {
  const ctx = makeCtx();
  const txs = opts.txs ?? ctx.txs!;
  const gw = {
    getOwnerId: vi.fn(async () => OWNER),
    readAccounts: vi.fn(async () => ctx.accounts),
    readCategories: vi.fn(async () => ctx.categories),
    readContacts: vi.fn(async () => ctx.contacts),
    readDebts: vi.fn(async () => opts.debts ?? ctx.debts),
    readGoals: vi.fn(async () => ({ goals: ctx.goals })),
    readTransactions: vi.fn(async () => txs),
    readBudgets: vi.fn(async () => []),
    readRecurring: vi.fn(async () => []),
    readDashboard: vi.fn(async () => ({})),
    executeCommand: vi.fn(async () => ({ status: "COMMITTED" })),
    aiReserve: vi.fn(async () => ({ id: "r" })),
    aiSettle: vi.fn(async () => ({})),
    aiMarkUnknown: vi.fn(async () => ({})),
  } as unknown as FinanceGateway & { executeCommand: ReturnType<typeof vi.fn> };
  const mg = opts.mg ?? fakeMg();
  let n = 0;
  const ai = vi.fn(async (_body: Record<string, unknown>) => ({ content: JSON.stringify(replies[Math.min(n++, replies.length - 1)]), usage: { prompt_tokens: 10, completion_tokens: 10 } }));
  const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "33333333-3333-3333-3333-333333333333" })) } as unknown as SessionVerifier;
  const app = buildApp(() => ({ cfg, gw, verifier, mg, ai }) as never);
  return { app, gw, mg, ai };
}
const agent = async (app: ReturnType<typeof makeApp>["app"], body: Record<string, unknown>) => {
  const res = await app.request("/v1/ai/agent", { method: "POST", headers, body: JSON.stringify(body) }, env);
  expect(res.status).toBe(200);
  return ((await res.json()) as { data: any }).data;
};

const HOTPOT = `${PHOTO_PREFIX}\nQUÁN LẨU THÁI TOMYUM\nSố khách: 3\nLẩu thái 1 389.000\nBia Tiger 6 150.000\nTổng cộng 849.000`;

describe("agent turn (HTTP, model faked)", () => {
  it("LOOKUP first, then acts on what it found (two model rounds)", async () => {
    const { app, ai } = makeApp([
      { reply: "", steps: [{ do: "LOOKUP", what: "TRANSACTIONS", q: "cà phê", since: "2026-11-27" }] },
      { reply: "Mình hủy khoản cà phê hôm qua nhé.", steps: [{ do: "CMD", type: "TX_REVERSE", payload: { tx_id: U(50), reason: "Theo yêu cầu", expected_version: 2 } }] },
    ]);
    const data = await agent(app, { text: "hủy khoản cà phê hôm qua" });
    expect(ai).toHaveBeenCalledTimes(2);
    const second = JSON.stringify((ai.mock.calls[1]![0] as any).messages);
    expect(second).toContain("lookup_results");
    expect(second).toContain(U(50));
    expect(data.actions).toEqual([expect.objectContaining({ type: "COMMAND", risk: "high", command: { command_type: "TX_REVERSE", payload: expect.objectContaining({ tx_id: U(50) }) } })]);
  });

  it("bill photo for a group: no full record yet, asks to split with the learned group pre-selected", async () => {
    const mg = fakeMg([{ id: "m1", kind: "HABIT", key: "chia bill lan nam", value: { names: ["Nam", "Lan"] }, weight: 0.9, hits: 3 } as unknown as MemoryEntry]);
    const { app } = makeApp([{ reply: "Mình đọc được hóa đơn lẩu 849.000đ.", steps: [{ do: "EXPENSE", amount: "849000", account: U(2), category: U(10), note: "Lẩu Thái Tomyum" }] }], { mg, txs: [] });
    const data = await agent(app, { text: HOTPOT });
    expect(data.actions).toHaveLength(1);
    const q = data.actions[0];
    expect(q.type).toBe("CHOICES");
    expect(q.question).toContain("849.000");
    expect(q.question).toContain("~3");
    expect(q.reason).toContain("3 khách");
    expect(q.options[0]).toEqual({ label: "Chia 3 với Nam, Lan", text: "Chia hóa đơn với Nam, Lan" });
    expect(q.options.map((o: any) => o.label)).toContain("Không chia");
    expect(data.plan).toContainEqual(expect.objectContaining({ do: "SPLIT_PENDING", amount: "849000", purpose: "EATOUT", account: U(2) }));
  });

  it("answering with names: one expense + SPLIT_APPLY shares (photo attached), the group is learned, undo weakens it", async () => {
    const mg = fakeMg();
    const { app } = makeApp([{ reply: "Đã chia.", steps: [{ do: "SPLIT", amount: "849000", people: ["Nam", "Lan"], include_me: true, account: U(2), category: U(10), note: "Lẩu Thái Tomyum", tx: null }] }], { mg, txs: [] });
    const previous = { steps: [{ do: "SPLIT_PENDING", status: "ASKED", data: { amount: "849000", purpose: "EATOUT" } }] };
    const data = await agent(app, { text: "chia Nam với Lan", previous });
    const [rec, split] = data.actions;
    expect(rec.command.command_type).toBe("TX_CREATE");
    expect(rec.command.payload.amount).toBe("849000");
    expect(rec.attach_photo).toBe(true);
    expect(split.command.command_type).toBe("SPLIT_APPLY");
    expect(split.command.payload.tx_id).toBe("$s1.tx_id");
    // 849.000 / 3 -> others 285.000 (rounded up to 5.000), owner 279.000.
    expect(split.command.payload.shares).toEqual([
      { contact_id: U(20), amount: "285000" },
      { contact_id: U(21), amount: "285000" },
    ]);
    expect(split.lines).toContain("Phần của bạn 279.000 ₫");
    expect(split.risk).toBe("low");
    expect(split.undo).toEqual({ ops: [{ op: "SPLIT_UNDO", application_id: "$result.application_id" }], habit: { kind: "HABIT", key: "chia bill lan nam" } });
    expect(mg.upsertMany).toHaveBeenCalledWith(OWNER, [expect.objectContaining({ kind: "HABIT", key: "chia bill lan nam" })]);
  });

  it("bill photo matching a bank-captured payment fills that transaction instead of recording twice", async () => {
    const captured = tx(80, "275000", { kind: "UNKNOWN_DEBIT", category_id: null, effective_at: "2026-11-28T12:20:00.000Z" });
    const solo = `${PHOTO_PREFIX}\nHIGHLANDS COFFEE\nPhin sữa đá 1 39.000\nBánh mì que 1 25.000\nTổng cộng 275.000`;
    const { app } = makeApp([{ reply: "", steps: [{ do: "EXPENSE", amount: "275000", account: U(1), category: U(10), note: "Highlands", tx: U(80) }] }], { txs: [captured] });
    const data = await agent(app, { text: solo });
    expect(data.actions).toHaveLength(1);
    const a = data.actions[0];
    expect(a.command.command_type).toBe("TX_ANNOTATE");
    expect(a.command.payload).toEqual(expect.objectContaining({ tx_id: U(80), category_id: U(10), expected_version: 2 }));
    expect(a.attach_photo).toBe(true);
  });

  it("two equally likely recorded payments: one-tap choice (each option is the ready action)", async () => {
    const a1 = tx(81, "64000", { kind: "UNKNOWN_DEBIT", category_id: null, effective_at: "2026-11-28T11:00:00.000Z" });
    const a2 = tx(82, "64000", { kind: "UNKNOWN_DEBIT", category_id: null, account_id: U(1), effective_at: "2026-11-28T12:00:00.000Z" });
    const bill = `${PHOTO_PREFIX}\nHIGHLANDS COFFEE\nPhin sữa đá 1 39.000\nBánh mì que 1 25.000\nTổng cộng 64.000`;
    const { app } = makeApp([{ reply: "", steps: [{ do: "EXPENSE", amount: "64000", account: U(1), category: U(10), note: "Highlands" }] }], { txs: [a1, a2] });
    const data = await agent(app, { text: bill });
    const c = data.actions[0];
    expect(c.type).toBe("CHOICES");
    expect(c.options).toHaveLength(3);
    expect(c.options.slice(0, 2).map((o: any) => o.action.command.payload.tx_id).sort()).toEqual([U(81), U(82)]);
    expect(c.options[2]).toEqual(expect.objectContaining({ label: "Khoản mới", action: expect.objectContaining({ attach_photo: true }) }));
  });

  it("'quên cái đó đi' deletes the matching memory entries", async () => {
    const mg = fakeMg([{ id: U(500), kind: "NOTE", key: "luon tra tien mat", value: { text: "Luôn trả tiền mặt" }, weight: 0.9, hits: 1 } as unknown as MemoryEntry]);
    const { app } = makeApp([{ reply: "Mình quên rồi nhé.", steps: [{ do: "FORGET", text: "luôn trả tiền mặt" }] }], { mg });
    const data = await agent(app, { text: "quên chuyện tôi luôn trả tiền mặt đi" });
    expect(data.actions).toEqual([expect.objectContaining({ type: "CALL", call: { method: "DELETE", path: `/ai/memory/${U(500)}` } })]);
  });
});

describe("undo endpoint", () => {
  it("reverses with the current version, replays safely, and weakens the habit", async () => {
    const mg = fakeMg();
    const { app, gw } = makeApp([{ steps: [] }], { mg, txs: [tx(90, "30000", { version: 3 })] });
    const body = { step_command_id: U(777), ops: [{ op: "REVERSE_TX", tx_id: U(90) }], habit: { kind: "HABIT", key: "chia bill lan nam" } };
    const res = await app.request("/v1/ai/undo", { method: "POST", headers, body: JSON.stringify(body) }, env);
    expect(res.status).toBe(200);
    const call = (gw.executeCommand.mock.calls[0] as unknown[])[3] as { command_type: string; payload: Record<string, unknown>; command_id: string };
    expect(call.command_type).toBe("TX_REVERSE");
    expect(call.payload).toEqual(expect.objectContaining({ tx_id: U(90), expected_version: 3 }));
    // Same step -> same command id (a double tap replays instead of undoing twice).
    await app.request("/v1/ai/undo", { method: "POST", headers, body: JSON.stringify(body) }, env);
    const again = (gw.executeCommand.mock.calls[1] as unknown[])[3] as { command_id: string };
    expect(again.command_id).toBe(call.command_id);
    expect(mg.upsert).toHaveBeenCalledWith(OWNER, { kind: "HABIT", key: "chia bill lan nam", value: {}, source: "undo" });
  });

  it("resolves debt payment undo by its transaction and skips what is already undone", async () => {
    const debts = [{ id: U(30), version: 4, state: "PARTIAL", payments: [{ id: U(31), tx_id: U(32), reversed: false }] }];
    const gw = { readDebts: vi.fn(async () => debts), readTransactions: vi.fn(async () => [tx(33, "1000", { status: "VOID" })]) } as unknown as FinanceGateway;
    expect(await undoCommand(gw, OWNER, { op: "REVERSE_DEBT_PAYMENT", debt_id: U(30), tx_id: U(32) }, "2026-11-28")).toEqual({
      command_type: "DEBT_PAYMENT_REVERSE",
      payload: { debt_id: U(30), payment_id: U(31), expected_version: 4 },
    });
    expect(await undoCommand(gw, OWNER, { op: "REVERSE_TX", tx_id: U(33) }, "2026-11-28")).toBeNull();
  });

  it("rejects malformed undo requests", async () => {
    const { app } = makeApp([{ steps: [] }]);
    const res = await app.request("/v1/ai/undo", { method: "POST", headers, body: JSON.stringify({ step_command_id: "x", ops: [] }) }, env);
    expect(res.status).toBe(400);
  });
});
