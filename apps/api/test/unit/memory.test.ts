import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { ownerMemoryWrite, runReflection, turnLearnings } from "../../src/entrypoints/routes-memory";
import { buildAgentMessages, resolveAgentOutput, type AgentContext } from "../../src/modules/ai/agent";
import {
  MEMORY_HEADER,
  clean,
  describeMemory,
  heavyWeekdays,
  memorySection,
  normalizeKey,
  parseLearned,
  parseReflectionNotes,
  reflectionEntries,
  requestTerms,
  type MemoryEntry,
  type ReflectStats,
} from "../../src/modules/ai/memory";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import { implementedCommand } from "../../src/modules/ledger/command-schemas";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

describe("normalisation", () => {
  it("matches the SQL rules (lowercase, no diacritics, single spaces)", () => {
    expect(normalizeKey("  Nước ĐẬU, 15k!! ")).toBe("nuoc dau 15k");
    expect(normalizeKey("Cà phê sữa đá")).toBe("ca phe sua da");
    expect(normalizeKey("Phở bò".normalize("NFD"))).toBe("pho bo");
    expect(normalizeKey("ỳýỵỷỹ ƯỚC")).toBe("yyyyy uoc");
    expect(normalizeKey("!!!")).toBe("");
  });
  it("request terms are distinct and bounded", () => {
    expect(requestTerms("nc đậu 15k nc đậu")).toEqual(["nc", "dau", "15k"]);
    expect(requestTerms(Array.from({ length: 300 }, (_, i) => `w${i}`).join(" "))).toHaveLength(120);
  });
  it("clean removes control characters and line separators", () => {
    expect(clean("a\nb\u2028c\td")).toBe("a b c d");
    expect(clean("x".repeat(200), 10)).toHaveLength(10);
  });
});

const entry = (kind: MemoryEntry["kind"], key: string, value: Record<string, unknown>, weight = 0.8) => ({ kind, key, value, weight });

describe("prompt section", () => {
  it("describes each kind in Vietnamese", () => {
    expect(describeMemory(entry("ALIAS", "nc dau", { from: "nc đậu", to: "nước đậu" }))).toBe('"nc đậu" nghĩa là "nước đậu"');
    expect(describeMemory(entry("CATEGORY_RULE", "nuoc dau", { phrase: "nước đậu", category: "Ăn uống" }))).toBe('"nước đậu" thuộc danh mục Ăn uống');
    expect(describeMemory(entry("PERSON", "nam", { name: "Nam" }))).toBe("Người quen: Nam");
    expect(describeMemory(entry("NOTE", "x", { text: "Luôn trả tiền mặt" }))).toBe("Luôn trả tiền mặt");
  });
  it("is empty without useful entries, skips weak ones and marks uncertain ones", () => {
    expect(memorySection([])).toBe("");
    expect(memorySection([entry("NOTE", "a", { text: "yếu" }, 0.1)])).toBe("");
    const s = memorySection([entry("NOTE", "a", { text: "chắc chắn" }, 0.9), entry("NOTE", "b", { text: "hơi chắc" }, 0.3)]);
    expect(s.startsWith(MEMORY_HEADER)).toBe(true);
    expect(s).toContain("- chắc chắn\n");
    expect(s).toContain("- hơi chắc (chưa chắc)");
  });
  it("never exceeds 1500 characters and drops duplicates", () => {
    const many = Array.from({ length: 100 }, (_, i) => entry("NOTE", `k${i}`, { text: `Ghi nhớ số ${i} ${"x".repeat(80)}` }));
    const s = memorySection([...many, ...many]);
    expect(s.length).toBeLessThanOrEqual(1500);
    expect(s.split("\n").length).toBeGreaterThan(5);
    expect(new Set(s.split("\n")).size).toBe(s.split("\n").length);
  });
  it("is appended to the agent prompt after DATA", () => {
    const ctx: AgentContext = { today: "2026-11-27", nowIso: "2026-11-27T03:00:00.000Z", accounts: [], categories: [], contacts: [], debts: [], goals: [] };
    const sec = memorySection([entry("ALIAS", "nc dau", { from: "nc đậu", to: "nước đậu" })]);
    const { messages, bytes } = buildAgentMessages("nc đậu 15k", [], ctx, { memory: sec });
    expect(messages[1]!.content.endsWith(sec)).toBe(true);
    expect(messages[0]!.content).toContain("Điều đã biết về chủ tài khoản");
    expect(bytes).toBeGreaterThan(buildAgentMessages("nc đậu 15k", [], ctx).bytes);
  });
});

describe("learned array validation", () => {
  const text = "nc đậu 15k, cho Nam mượn 50k";
  it("keeps aliases and people that occur in the request", () => {
    const r = parseLearned(
      { learned: [{ kind: "ALIAS", key: "nc đậu", value: "nước đậu" }, { kind: "PERSON", key: "Nam", value: "Nam" }] },
      text,
    );
    expect(r).toEqual([
      { kind: "ALIAS", key: "nc dau", value: { from: "nc đậu", to: "nước đậu" }, source: "pattern" },
      { kind: "PERSON", key: "nam", value: { name: "Nam" }, source: "pattern" },
    ]);
  });
  it("rejects invented keys, unsafe text, unknown kinds, oversize and photo requests", () => {
    const bad = {
      learned: [
        { kind: "ALIAS", key: "xyz", value: "abc" }, // not in the request
        { kind: "ALIAS", key: "nc đậu", value: "nc đậu" }, // maps to itself
        { kind: "ALIAS", key: "nc đậu", value: "<script>" },
        { kind: "NOTE", key: "a", value: "b" },
        { kind: "PERSON", key: "Nam", value: "x".repeat(81) },
        { kind: "PREFERENCE", key: "p", value: "visit https://evil.example" },
      ],
    };
    expect(parseLearned(bad, text)).toEqual([]);
    expect(parseLearned({ learned: "x" }, text)).toEqual([]);
    expect(parseLearned(null, text)).toEqual([]);
    expect(parseLearned({ learned: [{ kind: "ALIAS", key: "nc đậu", value: "nước đậu" }] }, `Ảnh hóa đơn/chuyển khoản:\n${text}`)).toEqual([]);
  });
  it("caps at three entries and accepts preferences as low-weight sentences", () => {
    const learned = Array.from({ length: 5 }, () => ({ kind: "PREFERENCE", key: "p", value: "Cà phê luôn trả bằng MoMo" }));
    const r = parseLearned({ learned }, "cà phê 30k");
    expect(r.length).toBeLessThanOrEqual(3);
    expect(r[0]).toMatchObject({ kind: "PREFERENCE", key: "ca phe luon tra bang momo", weight: 0.4 });
  });
  it("adds people from loan steps", () => {
    expect(turnLearnings("Hùng mượn 500k", {}, [{ do: "LEND", who: "Hùng" }, { do: "EXPENSE" }])).toEqual([
      { kind: "PERSON", key: "hung", value: { name: "Hùng" }, source: "pattern" },
    ]);
  });
  it("does not change plan resolution and agent transactions carry source AI", () => {
    const ctx: AgentContext = {
      today: "2026-11-27", nowIso: "2026-11-27T03:00:00.000Z",
      accounts: [{ id: U(1), name: "Tiền mặt", kind: "CASH" }, { id: U(2), name: "VCB", kind: "BANK" }],
      categories: [{ id: U(10), name: "Ăn uống", type: "EXPENSE" }], contacts: [], debts: [], goals: [], defaultAccountId: U(1),
    };
    const r = resolveAgentOutput({ reply: "ok", steps: [{ do: "EXPENSE", amount: "15000", category: U(10), note: "nước đậu" }, { do: "TRANSFER", amount: "1000", from: U(1), to: U(2) }], learned: [{ kind: "ALIAS", key: "a", value: "b" }] }, ctx);
    expect(r.actions.map((a) => a.type)).toEqual(["COMMAND", "COMMAND"]);
    for (const a of r.actions) {
      if (a.type !== "COMMAND") continue;
      expect(a.command.payload["source"]).toBe("AI");
      expect(implementedCommand.safeParse({ command_id: U(99), command_type: a.command.command_type, schema_version: 1, payload: a.command.payload }).success).toBe(true);
    }
  });
});

describe("TX_CREATE source", () => {
  const base = { command_id: U(99), command_type: "TX_CREATE", schema_version: 1 };
  const payload = { kind: "EXPENSE", account_id: U(1), amount: "1000", effective_at: "2026-11-27T03:00:00Z", category_id: U(10) };
  it("accepts client sources only", () => {
    for (const source of ["MANUAL", "AI", "NOTIFICATION", "IMPORT"]) expect(implementedCommand.safeParse({ ...base, payload: { ...payload, source } }).success).toBe(true);
    for (const source of ["BANK", "RECURRING", "SYSTEM", "x"]) expect(implementedCommand.safeParse({ ...base, payload: { ...payload, source } }).success).toBe(false);
    expect(implementedCommand.safeParse({ ...base, payload }).success).toBe(true);
  });
});

describe("owner-added memory", () => {
  it("builds keys from the alias or the text", () => {
    expect(ownerMemoryWrite({ kind: "ALIAS", key: "TCB", value: "Techcombank" })).toEqual({ kind: "ALIAS", key: "tcb", value: { from: "TCB", to: "Techcombank" }, source: "user" });
    expect(ownerMemoryWrite({ kind: "NOTE", value: "Lương về ngày 5" })).toEqual({ kind: "NOTE", key: "luong ve ngay 5", value: { text: "Lương về ngày 5" }, source: "user" });
    expect(ownerMemoryWrite({ kind: "ALIAS", key: "abc", value: "ABC" })).toBeNull();
    expect(ownerMemoryWrite({ kind: "NOTE", value: "!!" })).toBeNull();
  });
});

const stats: ReflectStats = {
  days: 30,
  meals: [
    { meal: "breakfast", days: 18, count: 20, median: "34600", category_id: U(10), category: "Ăn uống", account_id: U(1), account: "Tiền mặt" },
    { meal: "dinner", days: 2, count: 2, median: "120000", category_id: U(10), category: "Ăn uống", account_id: U(1), account: "Tiền mặt" },
  ],
  keywords: [
    { key: "grab", phrase: "Grab", count: 9, median: "42500", category_id: U(11), category: "Di chuyển" },
    { key: "pho", phrase: "phở", count: 2, median: "40000", category_id: U(10), category: "Ăn uống" },
  ],
  weekdays: [1, 2, 3, 4, 5, 6, 7].map((weekday) => ({ weekday, days: weekday <= 2 ? 5 : 4, total: weekday === 6 ? "2000000" : "400000" })),
  preferences: [
    { category_id: U(10), category: "Ăn uống", daypart: "noon", account_id: U(1), account: "Tiền mặt", count: 8, total: 10 },
    { category_id: U(11), category: "Di chuyển", daypart: "evening", account_id: U(2), account: "VCB", count: 3, total: 6 },
  ],
};

describe("reflection math", () => {
  it("turns 30 days into habits and preferences with thresholds", () => {
    const { habits, preferences } = reflectionEntries(stats);
    const keys = habits.map((h) => h.key);
    expect(keys).toContain("bua sang");
    expect(keys).not.toContain("bua toi"); // 2 of 30 days is not a habit
    expect(habits.find((h) => h.key === "bua sang")!.value.text).toBe("Ăn sáng thường khoảng 35.000 ₫, danh mục Ăn uống, trả bằng Tiền mặt (18/30 ngày)");
    expect(keys).toContain("hay chi grab");
    expect(keys).not.toContain("hay chi pho");
    expect(habits.find((h) => h.key === "ngay chi nhieu")!.value.text).toContain("Thứ Bảy");
    expect(preferences).toHaveLength(1); // 3/6 = 50% is not a preference
    expect(preferences[0]).toMatchObject({ key: "tai khoan an uong noon", value: { text: "Chi Ăn uống buổi trưa thường trả bằng Tiền mặt", account_id: U(1) } });
  });
  it("heavy weekdays need two weeks and a clear peak", () => {
    expect(heavyWeekdays(stats.weekdays)).toEqual({ days: [6], avg: 500000, mean: 147000 });
    expect(heavyWeekdays(stats.weekdays.map((w) => ({ ...w, total: "100000" })))).toBeNull();
    expect(heavyWeekdays([{ weekday: 1, days: 1, total: "1000" }])).toBeNull();
  });
  it("AI notes: at most 10 short distinct lines, no invented numbers", () => {
    const facts = ["Ăn sáng thường khoảng 35.000 ₫ (18/30 ngày)"];
    const r = parseReflectionNotes(
      { notes: ["Ăn sáng gần như mỗi ngày, khoảng 35.000 ₫", "Ăn sáng gần như mỗi ngày, khoảng 35.000 ₫", "Chi 99.000 ₫ cho cà phê", "ngắn", 5, ...Array(20).fill(0).map((_, i) => `Ghi chú hợp lệ thứ ${["một", "hai", "ba", "bốn", "năm", "sáu", "bảy", "tám", "chín", "mười", "mười một", "mười hai"][i % 12]}`)] },
      facts,
    )!;
    expect(r[0]!.value.text).toBe("Ăn sáng gần như mỗi ngày, khoảng 35.000 ₫");
    expect(r.some((n) => String(n.value.text).includes("99.000"))).toBe(false);
    expect(r.length).toBeLessThanOrEqual(10);
    expect(new Set(r.map((n) => n.key)).size).toBe(r.length);
    expect(parseReflectionNotes({ notes: "x" }, facts)).toBeNull();
  });
});

const cfg: Config = { supabaseUrl: "https://x.supabase.co", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@example.test", dbTimeoutMs: 1000 };
const OWNER = "11111111-1111-1111-1111-111111111111";

function fakeMg() {
  const rows: MemoryEntry[] = [];
  const mg = {
    list: vi.fn(async (_o: string, kind: string | null) => rows.filter((r) => !kind || r.kind === kind)),
    relevant: vi.fn(async () => rows),
    upsert: vi.fn(async (_o: string, w: any) => {
      const m = { id: U(rows.length + 1), ...w, weight: 0.9, hits: 1, last_seen_at: "x", created_at: "x" } as MemoryEntry;
      rows.push(m);
      return m;
    }),
    upsertMany: vi.fn(async (_o: string, items: unknown[]) => items.length),
    replace: vi.fn(async (_o: string, _k: string, _s: string, items: unknown[]) => items.length),
    remove: vi.fn(async () => ({ deleted: true })),
    decay: vi.fn(async () => ({ decayed: 1, dropped: 2 })),
    observe: vi.fn(async () => ({ learned: "correction" })),
    confirmRecent: vi.fn(async () => 3),
    reflectStats: vi.fn(async () => stats),
  };
  return { mg: mg as unknown as MemoryGateway & typeof mg, rows };
}

function makeApp(ai?: (body: Record<string, unknown>) => Promise<{ content: string; usage: { prompt_tokens: number; completion_tokens: number } }>) {
  const { mg, rows } = fakeMg();
  const gw = {
    getOwnerId: vi.fn(async () => OWNER),
    executeCommand: vi.fn(async () => ({ tx_id: U(5), status: "COMMITTED" })),
    readAccounts: vi.fn(async () => [{ id: U(1), name: "Tiền mặt", kind: "CASH" }]),
    readCategories: vi.fn(async () => [{ id: U(10), name: "Ăn uống", type: "EXPENSE" }]),
    readContacts: vi.fn(async () => []),
    readDebts: vi.fn(async () => []),
    readGoals: vi.fn(async () => ({ goals: [] })),
    readTransactions: vi.fn(async () => []),
    aiReserve: vi.fn(async () => ({ id: "r" })),
    aiSettle: vi.fn(async () => ({})),
    aiMarkUnknown: vi.fn(async () => ({})),
  } as unknown as FinanceGateway;
  const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "33333333-3333-3333-3333-333333333333" })) } as unknown as SessionVerifier;
  const app = buildApp(() => ({ cfg, gw, verifier, mg, ...(ai ? { ai } : {}) }));
  return { app, mg, gw, rows };
}
const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };
const env = {} as never;

describe("memory routes and hooks", () => {
  it("list / add / delete with validation", async () => {
    const { app, mg } = makeApp();
    const add = await app.request("/v1/ai/memory", { method: "POST", headers, body: JSON.stringify({ kind: "ALIAS", key: "nc đậu", value: "nước đậu" }) }, env);
    expect(add.status).toBe(200);
    expect(((await add.json()) as any).data).toMatchObject({ kind: "ALIAS", key: "nc dau", text: '"nc đậu" nghĩa là "nước đậu"' });
    const list = (await (await app.request("/v1/ai/memory?kind=ALIAS", { headers }, env)).json()) as any;
    expect(list.data).toHaveLength(1);
    expect((await app.request("/v1/ai/memory?kind=SECRET", { headers }, env)).status).toBe(400);
    expect((await app.request("/v1/ai/memory", { method: "POST", headers, body: JSON.stringify({ kind: "HABIT", key: "a", value: "b" }) }, env)).status).toBe(400);
    expect((await app.request("/v1/ai/memory", { method: "POST", headers, body: JSON.stringify({ kind: "NOTE", value: "x".repeat(161) }) }, env)).status).toBe(400);
    expect((await app.request(`/v1/ai/memory/${U(1)}`, { method: "DELETE", headers }, env)).status).toBe(200);
    expect(mg.remove).toHaveBeenCalledWith(OWNER, U(1));
    expect((await app.request("/v1/ai/memory/nope", { method: "DELETE", headers }, env)).status).toBe(400);
  });

  it("the agent reads memory before acting and stores what it learned", async () => {
    let prompt = "";
    const ai = vi.fn(async (body: Record<string, unknown>) => {
      prompt = JSON.stringify(body.messages);
      return { content: JSON.stringify({ reply: "Đã ghi", steps: [{ do: "EXPENSE", amount: "15000", category: U(10), note: "nước đậu" }], learned: [{ kind: "ALIAS", key: "nc đậu", value: "nước đậu" }] }), usage: { prompt_tokens: 1, completion_tokens: 1 } };
    });
    const { app, mg, rows } = makeApp(ai);
    rows.push({ id: U(7), kind: "CATEGORY_RULE", key: "nuoc dau", value: { phrase: "nước đậu", category: "Ăn uống" }, weight: 0.9, hits: 1, last_seen_at: "x", source: "correction", created_at: "x" });
    const res = await app.request("/v1/ai/agent", { method: "POST", headers, body: JSON.stringify({ text: "nc đậu 15k" }) }, env);
    expect(res.status).toBe(200);
    expect(mg.relevant).toHaveBeenCalledWith(OWNER, ["nc", "dau", "15k"], 24);
    expect(prompt).toContain("thuộc danh mục Ăn uống");
    expect(mg.upsertMany).toHaveBeenCalledWith(OWNER, [{ kind: "ALIAS", key: "nc dau", value: { from: "nc đậu", to: "nước đậu" }, source: "pattern" }]);
    const data = ((await res.json()) as any).data;
    expect(data.actions[0].command.payload.source).toBe("AI");
  });

  it("the agent still works when memory is unavailable", async () => {
    const ai = vi.fn(async () => ({ content: JSON.stringify({ reply: "ok", steps: [] }), usage: { prompt_tokens: 1, completion_tokens: 1 } }));
    const { app, mg } = makeApp(ai);
    vi.mocked(mg.relevant).mockRejectedValueOnce(new Error("down"));
    expect((await app.request("/v1/ai/agent", { method: "POST", headers, body: JSON.stringify({ text: "hi" }) }, env)).status).toBe(200);
  });

  it("commands report edits and reversals, not plain creates; failures never break the command", async () => {
    const { app, mg } = makeApp();
    const send = (type: string, payload: unknown) => {
      const id = crypto.randomUUID();
      return app.request("/v1/commands", { method: "POST", headers: { ...headers, "idempotency-key": id }, body: JSON.stringify({ command_id: id, command_type: type, schema_version: 1, payload }) }, env);
    };
    expect((await send("TX_CREATE", { kind: "EXPENSE", account_id: U(1), amount: "1000", effective_at: "2026-11-27T03:00:00Z", category_id: U(10), source: "AI" })).status).toBe(200);
    expect(mg.observe).not.toHaveBeenCalled();
    expect((await send("TX_ANNOTATE", { tx_id: U(5), expected_version: 2, note: "x" })).status).toBe(200);
    expect(mg.observe).not.toHaveBeenCalled(); // no category change
    vi.mocked(mg.observe).mockRejectedValueOnce(new Error("down"));
    expect((await send("TX_ANNOTATE", { tx_id: U(5), expected_version: 2, category_id: U(10) })).status).toBe(200);
    expect((await send("TX_REVERSE", { tx_id: U(5), reason: "Hoàn tác từ Trợ lý AI", expected_version: 2 })).status).toBe(200);
    expect(vi.mocked(mg.observe).mock.calls.map((c) => (c as unknown[])[1])).toEqual(["TX_ANNOTATE", "TX_REVERSE"]);
  });

  it("nightly reflection: confirm, habits, preferences, optional AI notes, decay", async () => {
    const { mg } = fakeMg();
    const gw = { aiReserve: vi.fn(async () => ({ id: "r" })), aiSettle: vi.fn(async () => ({})), aiMarkUnknown: vi.fn(async () => ({})) } as unknown as FinanceGateway;
    const ai = vi.fn(async () => ({ content: JSON.stringify({ notes: ["Ăn sáng gần như mỗi ngày, khoảng 35.000 ₫"] }), usage: { prompt_tokens: 1, completion_tokens: 1 } }));
    const r = await runReflection({ cfg, gw, mg, ai }, OWNER);
    expect(r).toEqual({ confirmed: 3, habits: 3, preferences: 1, notes: 1, dropped: 2 });
    expect(vi.mocked(mg.replace).mock.calls.map((c) => [c[1], c[2]])).toEqual([["HABIT", "reflection"], ["PREFERENCE", "reflection"], ["NOTE", "reflection"]]);
    const noAi = await runReflection({ cfg, gw, mg }, OWNER);
    expect(noAi.notes).toBe(0);
  });
});
