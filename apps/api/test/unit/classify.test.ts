import { afterEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import {
  classifyAfterCommand,
  classifyInput,
  learnKey,
  notifyUnclear,
  runClassifySweep,
  suggestionsFor,
  unclearMessage,
  type ClassifyDeps,
  type LoadedContext,
} from "../../src/entrypoints/routes-classify";
import {
  APPLY_THRESHOLD,
  buildHistory,
  classifyDeterministic,
  contentSignature,
  dictionaryMatch,
  parseClassifyOutput,
  shouldApply,
  type ClassifyCategory,
} from "../../src/modules/ai/classify";
import type { ClassifyCandidate, ClassifyGateway, ClassifyRecord } from "../../src/modules/ai/classify-gateway";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { RemindersGateway } from "../../src/modules/reminders/gateway";

const OWNER = "11111111-1111-4111-8111-111111111111";
const cfg: Config = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@t", dbTimeoutMs: 1000, onesignalAppId: "app", onesignalRestKey: "rk" };
const CATS: ClassifyCategory[] = [
  { id: "c-food", name: "Ăn uống", type: "EXPENSE" },
  { id: "c-move", name: "Di chuyển", type: "EXPENSE" },
  { id: "c-shop", name: "Mua sắm", type: "EXPENSE" },
  { id: "c-bill", name: "Hóa đơn", type: "EXPENSE" },
  { id: "c-other", name: "Khác", type: "EXPENSE" },
  { id: "c-salary", name: "Lương", type: "INCOME" },
  { id: "c-in-other", name: "Thu nhập khác", type: "INCOME" },
];
const ctxOf = (over: Partial<LoadedContext> = {}): LoadedContext => ({ categories: CATS, rules: [], history: new Map(), examples: [], ...over });
const aiReply = (content: object) => vi.fn(async () => ({ content: JSON.stringify(content), usage: { prompt_tokens: 100, completion_tokens: 20 } }));

function gwFake() {
  return {
    readCategories: vi.fn(async () => CATS),
    aiReserve: vi.fn(async () => ({ id: "res" })),
    aiSettle: vi.fn(async () => ({})),
    aiMarkUnknown: vi.fn(async () => ({})),
    getOwnerId: vi.fn(async () => OWNER),
  } as unknown as FinanceGateway & Record<string, ReturnType<typeof vi.fn>>;
}
function mgFake(rules: { key: string; value: Record<string, unknown>; weight: number }[] = []) {
  return { list: vi.fn(async () => rules), upsert: vi.fn(async () => null) } as unknown as MemoryGateway & { upsert: ReturnType<typeof vi.fn> };
}
function cgFake(cands: ClassifyCandidate[] = [], pending: unknown[] = []) {
  const records: ClassifyRecord[] = [];
  const cg = {
    records,
    candidates: vi.fn(async (_o: string, _l: number, tx?: string) => (tx ? cands.filter((c) => c.id === tx) : cands)),
    examples: vi.fn(async () => []),
    record: vi.fn(async (_o: string, r: ClassifyRecord) => (records.push(r), { status: r.apply ? "APPLIED" : "SUGGESTED" })),
    txFacts: vi.fn(),
    pending: vi.fn(async () => ({ total: pending.length, items: pending })),
    markNotified: vi.fn(async (_o: string, ids: string[]) => ids.length),
  };
  return cg as unknown as ClassifyGateway & typeof cg;
}
const cand = (id: string, note: string, kind = "UNKNOWN_DEBIT"): ClassifyCandidate => ({
  id, kind, amount: "200000", effective_at: "2026-11-28T05:30:00Z", note, merchant: null, source: "NOTIFICATION", version: 2,
  category_id: null, institution: "Vietcombank", account_name: "VCB", account_kind: "BANK",
});

afterEach(() => vi.restoreAllMocks());

describe("text helpers and dictionary", () => {
  it("signature drops bank noise, codes and digits", () => {
    expect(contentSignature("MBVCB.1234567.012345.GRAB*FOOD 89K thanh toan")).toBe("grab food");
    expect(contentSignature("IBFT 0123 CT tu 1026746096 toi 99887766")).toBeNull();
    expect(contentSignature("Highlands Coffee Ba Trieu")).toBe("highlands coffee ba trieu");
  });
  it("longest dictionary phrase wins and type must match", () => {
    expect(dictionaryMatch("GRAB FOOD 123", "out")?.merchant).toBe("GrabFood");
    expect(dictionaryMatch("GRAB*RIDE 5566", "out")?.merchant).toBe("Grab");
    expect(dictionaryMatch("Thanh toan hoa don EVNHCMC", "out")?.category).toBe("Hóa đơn");
    expect(dictionaryMatch("CTY ABC TRA LUONG THANG 11", "in")?.category).toBe("Lương");
    expect(dictionaryMatch("CTY ABC TRA LUONG THANG 11", "out")).toBeNull();
  });
  it("person names are not keywords (Thương, Lương, Trương, chuyển tiền cho)", () => {
    expect(dictionaryMatch("NGUYEN THI THUONG chuyen tien", "in")).toBeNull();
    expect(dictionaryMatch("LUONG VAN A chuyen khoan", "in")).toBeNull();
    expect(dictionaryMatch("chuyen tien cho TRUONG VAN B", "out")).toBeNull();
  });
});

describe("deterministic layers", () => {
  it("1. learned rule beats everything", () => {
    const r = classifyDeterministic(
      { text: "MBVCB.123.GRAB thanh toan", direction: "out" },
      ctxOf({ rules: [{ key: "grab", value: { phrase: "Grab", category_id: "c-food" }, weight: 0.9 }] }),
    );
    expect(r).toMatchObject({ categoryId: "c-food", method: "MEMORY" });
    expect(r!.confidence).toBeGreaterThanOrEqual(APPLY_THRESHOLD);
  });
  it("2. own history: same signature twice -> same category", () => {
    const history = buildHistory([
      { kind: "EXPENSE", category_id: "c-shop", note: "Thanh toan WINMART 123", merchant: null },
      { kind: "EXPENSE", category_id: "c-shop", note: "winmart", merchant: null },
      { kind: "EXPENSE", category_id: "c-food", note: "bun cha ba hai", merchant: null },
    ]);
    const r = classifyDeterministic({ text: "WINMART 99 thanh toan", direction: "out" }, ctxOf({ history }));
    expect(r).toMatchObject({ categoryId: "c-shop", method: "HISTORY" });
  });
  it("3. dictionary maps onto the owner's own category and never invents one", () => {
    expect(classifyDeterministic({ text: "GRAB*RIDE", direction: "out" }, ctxOf())).toMatchObject({ categoryId: "c-move", merchant: "Grab", method: "DICTIONARY" });
    const noMove = ctxOf({ categories: CATS.filter((c) => c.id !== "c-move") });
    expect(classifyDeterministic({ text: "GRAB*RIDE", direction: "out" }, noMove)).toBeNull();
  });
  it("opaque bank text stays unclassified", () => {
    expect(classifyDeterministic({ text: "IBFT 0123 CT tu 1026746096", direction: "out" }, ctxOf())).toBeNull();
  });
  it("fallback categories are never applied automatically", () => {
    expect(shouldApply({ categoryId: "c-other", merchant: null, confidence: 0.99, method: "AI", reason: "" }, CATS)).toBe(false);
    expect(shouldApply({ categoryId: "c-food", merchant: null, confidence: 0.74, method: "AI", reason: "" }, CATS)).toBe(false);
    expect(shouldApply({ categoryId: "c-food", merchant: null, confidence: 0.8, method: "AI", reason: "" }, CATS)).toBe(true);
  });
});

describe("AI layer", () => {
  it("parses the model's choice, caps confidence and rejects unknown ids", () => {
    const input = { text: "x", direction: "out" as const };
    expect(parseClassifyOutput({ category: "c-food", merchant: "Bún chả", confidence: 0.99 }, input, ctxOf())).toMatchObject({ categoryId: "c-food", confidence: 0.88, method: "AI" });
    expect(parseClassifyOutput({ category: "c-other", confidence: 0.9 }, input, ctxOf())!.confidence).toBe(0.5);
    expect(parseClassifyOutput({ category: "made-up", confidence: 0.9 }, input, ctxOf())).toBeNull();
    expect(parseClassifyOutput({ category: "c-salary", confidence: 0.9 }, input, ctxOf())).toBeNull(); // wrong type
  });
  it("calls the model only when the deterministic layers are not sure, and records usage", async () => {
    const gw = gwFake();
    const ai = aiReply({ category: "c-food", merchant: "Quán bún", confidence: 0.82 });
    const d: ClassifyDeps = { cfg, gw, ai };
    const sure = await classifyInput(d, OWNER, { text: "Highlands coffee", direction: "out" }, ctxOf(), true);
    expect(sure?.method).toBe("DICTIONARY");
    expect(ai).not.toHaveBeenCalled();
    const r = await classifyInput(d, OWNER, { text: "quan co ba hai phong", direction: "out" }, ctxOf(), true);
    expect(r).toMatchObject({ categoryId: "c-food", method: "AI", merchant: "Quán bún" });
    expect(gw.aiReserve).toHaveBeenCalledTimes(1);
    expect(gw.aiSettle).toHaveBeenCalledTimes(1);
  });
  it("a provider failure falls back to the deterministic guess and marks the charge unknown", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    const gw = gwFake();
    const ai = vi.fn(async () => {
      throw new Error("down");
    });
    const r = await classifyInput({ cfg, gw, ai }, OWNER, { text: "an trua quan quen", direction: "out" }, ctxOf(), true);
    expect(r).toMatchObject({ categoryId: "c-food", method: "DICTIONARY" }); // "an trua" keyword, 0.72
    expect(gw.aiMarkUnknown).toHaveBeenCalledTimes(1);
  });
});

describe("apply, suggest, learn, notify", () => {
  it("sweep applies confident results and stores the rest as suggestions", async () => {
    const cg = cgFake([cand("t1", "GRAB*RIDE 123"), cand("t2", "IBFT 0123 CT tu 1026746096")]);
    const rg = { pushClaim: vi.fn(async () => true) } as unknown as RemindersGateway;
    const pushFetch = vi.fn(async () => new Response("{}"));
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}")); // inbox save
    const ai = aiReply({ category: "c-other", confidence: 0.3 });
    const r = await runClassifySweep({ cfg, gw: gwFake(), ai, mg: mgFake(), cg, rg, pushFetch }, OWNER, 8, new Date("2026-11-28T05:00:00Z"));
    expect(r).toEqual({ checked: 2, applied: 1, suggested: 1 });
    expect(cg.records[0]).toMatchObject({ tx: "t1", categoryId: "c-move", apply: true, method: "DICTIONARY" });
    expect(cg.records[1]).toMatchObject({ tx: "t2", apply: false });
  });

  it("TX_CREATE of captured unknown money is classified; other commands are not", async () => {
    const cg = cgFake([cand("t9", "GRAB*RIDE")]);
    const d: ClassifyDeps = { cfg, gw: gwFake(), mg: mgFake(), cg };
    await classifyAfterCommand(null, d, OWNER, { command_type: "TX_CREATE", payload: { kind: "EXPENSE" } }, { status: "COMMITTED", tx_id: "t9" });
    expect(cg.record).not.toHaveBeenCalled();
    await classifyAfterCommand(null, d, OWNER, { command_type: "TX_CREATE", payload: { kind: "UNKNOWN_DEBIT" } }, { status: "REPLAYED", tx_id: "t9" });
    expect(cg.record).not.toHaveBeenCalled();
    await classifyAfterCommand(null, d, OWNER, { command_type: "TX_CREATE", payload: { kind: "UNKNOWN_DEBIT" } }, { status: "COMMITTED", tx_id: "t9" });
    expect(cg.records[0]).toMatchObject({ tx: "t9", categoryId: "c-move", apply: true });
  });

  it("the owner's pick teaches a rule keyed by merchant or description signature", async () => {
    const mg = mgFake();
    const cg = cgFake();
    cg.txFacts.mockResolvedValue({ id: "t1", kind: "EXPENSE", note: "MBVCB.55.QUAN BUN CHA HUONG LIEN.CT", merchant: null, source: "NOTIFICATION", category_id: "c-food", category: "Ăn uống", category_type: "EXPENSE", previous: null });
    await classifyAfterCommand(null, { cfg, gw: gwFake(), mg, cg }, OWNER, { command_type: "TX_ANNOTATE", payload: { tx_id: "t1", category_id: "c-food" } }, { status: "COMMITTED" });
    expect(mg.upsert).toHaveBeenCalledWith(OWNER, expect.objectContaining({ kind: "CATEGORY_RULE", key: "quan bun cha huong", source: "correction", value: expect.objectContaining({ category_id: "c-food" }) }));
    expect(learnKey("GRAB*RIDE 22", null, "EXPENSE")).toEqual({ key: "grab", phrase: "Grab" });
    expect(learnKey("IBFT 0123", null, "EXPENSE")).toBeNull();
    // assistant-created rows already teach through migration 009
    cg.txFacts.mockResolvedValue({ id: "t2", kind: "EXPENSE", note: "bun", merchant: "Bún", source: "AI", category_id: "c-food", category: "Ăn uống", category_type: "EXPENSE", previous: null });
    mg.upsert.mockClear();
    await classifyAfterCommand(null, { cfg, gw: gwFake(), mg, cg }, OWNER, { command_type: "TX_ANNOTATE", payload: { tx_id: "t2", category_id: "c-food" } }, { status: "COMMITTED" });
    expect(mg.upsert).not.toHaveBeenCalled();
  });

  it("unclear push: one message for several items, claimed per window, quiet at night", async () => {
    const items = [
      { id: "a", kind: "UNKNOWN_DEBIT", amount: "200000", effective_at: "2026-11-28T05:30:00Z", account_name: "VCB", institution: "Vietcombank" },
      { id: "b", kind: "UNKNOWN_DEBIT", amount: "50000", effective_at: "2026-11-28T05:20:00Z", account_name: "VCB", institution: "Vietcombank" },
    ];
    expect(unclearMessage([items[0]!]).title).toBe("Khoản -200.000đ ở Vietcombank lúc 12:30 chưa rõ loại");
    expect(unclearMessage(items).title).toBe("2 khoản chưa rõ loại");
    const cg = cgFake([], items);
    const claims = new Set<string>();
    const rg = { pushClaim: vi.fn(async (_o: string, k: string) => (claims.has(k) ? false : (claims.add(k), true))) } as unknown as RemindersGateway;
    const pushFetch = vi.fn(async () => new Response("{}"));
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}"));
    const d: ClassifyDeps = { cfg, gw: gwFake(), cg, rg, pushFetch };
    const noon = new Date("2026-11-28T05:31:00Z"); // 12:31 Vietnam
    expect(await notifyUnclear(d, OWNER, noon, "live")).toBe(2);
    expect(pushFetch).toHaveBeenCalledTimes(1);
    const body = JSON.parse(String((pushFetch.mock.calls[0] as unknown[])[1] && ((pushFetch.mock.calls[0] as unknown[])[1] as RequestInit).body));
    expect(body.data).toMatchObject({ type: "classify", route: "/classify", count: 2 });
    expect(cg.markNotified).toHaveBeenCalledWith(OWNER, ["a", "b"]);
    expect(await notifyUnclear(d, OWNER, new Date(noon.getTime() + 60_000), "live")).toBe(0); // same 10-minute window
    expect(await notifyUnclear(d, OWNER, new Date("2026-11-28T17:00:00Z"), "cron")).toBe(0); // 00:00 Vietnam
    expect(pushFetch).toHaveBeenCalledTimes(1);
  });

  it("suggestions: classifier's pick first, then guesses and most used, never Khác, max 4", () => {
    const ctx = ctxOf({ examples: [{ kind: "EXPENSE", category_id: "c-bill", note: "x", merchant: null }, { kind: "EXPENSE", category_id: "c-bill", note: "y", merchant: null }] });
    const s = suggestionsFor({ kind: "UNKNOWN_DEBIT", note: "GRAB*RIDE", merchant: null, amount: "1", suggested_category_id: "c-food", confidence: 0.6, reason: "AI" }, ctx);
    expect(s.map((x) => x.category_id)).toEqual(["c-food", "c-move", "c-bill", "c-shop"]);
    expect(s.some((x) => x.category_id === "c-other")).toBe(false);
  });
});

describe("routes", () => {
  const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };
  function app(ai?: ReturnType<typeof aiReply>) {
    const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "s" })) } as unknown as SessionVerifier;
    const pending = [{ ...cand("p1", "GRAB*RIDE"), account_id: "acc", suggested_category_id: null, confidence: 0, reason: null, suggested_merchant: null, notified_at: null }];
    const deps = { cfg, gw: gwFake(), verifier, mg: mgFake(), cg: cgFake([], pending), ...(ai ? { ai } : {}) };
    return buildApp(() => deps as never);
  }
  it("suggest: dictionary hit without the model; null when nothing fits and AI is off", async () => {
    const a = app();
    const r = (await (await a.request("/v1/ai/classify/suggest", { method: "POST", headers, body: JSON.stringify({ text: "grab di lam" }) }, {} as never)).json()) as any;
    expect(r.data).toMatchObject({ category_id: "c-move", method: "DICTIONARY" });
    const none = (await (await a.request("/v1/ai/classify/suggest", { method: "POST", headers, body: JSON.stringify({ text: "zzzz qqq" }) }, {} as never)).json()) as any;
    expect(none.data).toBeNull();
    expect((await a.request("/v1/ai/classify/suggest", { method: "POST", headers, body: JSON.stringify({ text: "" }) }, {} as never)).status).toBe(400);
  });
  it("pending lists unclear items with chips", async () => {
    const r = (await (await app().request("/v1/ai/classify/pending", { headers }, {} as never)).json()) as any;
    expect(r.data.total).toBe(1);
    expect(r.data.items[0].suggestions[0]).toMatchObject({ category_id: "c-move", name: "Di chuyển" });
  });
});
