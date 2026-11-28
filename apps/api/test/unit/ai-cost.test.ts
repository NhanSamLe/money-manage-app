import { afterEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { classifyInput, type LoadedContext } from "../../src/entrypoints/routes-classify";
import { PRICES, actualMicro, buildMessages, buildRequestBody, estimateMicro, isPeak } from "../../src/modules/ai/assistant";
import { buildAgentMessages, type AgentContext } from "../../src/modules/ai/agent";
import { buildClassifyMessages, buildHistory } from "../../src/modules/ai/classify";
import { buildInsightMessages } from "../../src/modules/insights/analysis";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

// AI is the only paid part of MoMa (owner: free tiers for everything else). These tests pin the cost rules:
// thinking off, cacheable prompt prefixes, accurate peak/off-peak/cache pricing, deterministic layers first.

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const OWNER = U(99);

afterEach(() => vi.unstubAllGlobals());

describe("request body", () => {
  it("turns DeepSeek thinking mode off for every structured call and keeps tight output caps", () => {
    const b = buildRequestBody([{ role: "user", content: "x" }], 120);
    expect(b.thinking).toEqual({ type: "disabled" });
    expect(b.max_tokens).toBe(120);
    expect(b.response_format).toEqual({ type: "json_object" });
    expect(b.stream).toBe(false);
  });
});

describe("pricing", () => {
  it("peak = 01-04 and 06-10 UTC Monday-Friday; weekends are off-peak", () => {
    expect(isPeak(new Date("2026-12-01T02:30:00Z"))).toBe(true); // Tue
    expect(isPeak(new Date("2026-12-01T07:00:00Z"))).toBe(true);
    expect(isPeak(new Date("2026-12-01T05:00:00Z"))).toBe(false);
    expect(isPeak(new Date("2026-12-01T13:00:00Z"))).toBe(false); // 20:00 Vietnam
    expect(isPeak(new Date("2026-12-05T02:30:00Z"))).toBe(false); // Saturday
  });

  it("actual cost splits cache hits / misses / output at the price of the call time", () => {
    const u = { prompt_tokens: 10_000, completion_tokens: 200, cache_hit_tokens: 8_000 };
    const off = actualMicro(u, new Date("2026-12-01T13:00:00Z"));
    const peak = actualMicro(u, new Date("2026-12-01T02:00:00Z"));
    expect(off).toBe(Math.ceil(8000 * PRICES.offPeak.hit + 2000 * PRICES.offPeak.miss + 200 * PRICES.offPeak.out));
    expect(peak).toBe(Math.ceil(8000 * PRICES.peak.hit + 2000 * PRICES.peak.miss + 200 * PRICES.peak.out));
    expect(peak).toBeGreaterThan(off);
    // unknown cache info is billed as all-miss (never under-estimated)
    expect(actualMicro({ prompt_tokens: 1000, completion_tokens: 0 }, new Date("2026-12-01T13:00:00Z"))).toBe(150);
    // the reservation is always the worst case
    expect(estimateMicro(10_000, 200)).toBeGreaterThanOrEqual(actualMicro({ prompt_tokens: 10_000, completion_tokens: 200 }, new Date("2026-12-01T02:00:00Z")));
  });
});

/** Longest common prefix of two strings. */
const lcp = (a: string, b: string) => {
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return i;
};

describe("prompt prefixes stay cacheable (stable part first, request data last)", () => {
  const ctx: AgentContext = {
    today: "2026-12-01",
    nowIso: "2026-12-01T05:00:00Z",
    accounts: [{ id: U(1), name: "Tiền mặt", kind: "CASH" }, { id: U(2), name: "VCB", kind: "BANK" }],
    categories: Array.from({ length: 12 }, (_, i) => ({ id: U(10 + i), name: `Danh mục ${i}`, type: "EXPENSE" })),
    contacts: [{ id: U(40), alias: "Nam" }],
    debts: [],
    goals: [],
  };

  it("agent: two different requests on different days share the system prompt and the owner's data", () => {
    const a = buildAgentMessages("ăn trưa 65k", [], ctx).messages;
    const b = buildAgentMessages("grab 30k hôm qua", [{ role: "user", text: "x" }], { ...ctx, today: "2026-12-02" }).messages;
    expect(a[0]!.content).toBe(b[0]!.content); // the whole system prompt (persona + tool catalog) is identical
    const ua = a[1]!.content;
    const ub = b[1]!.content;
    const shared = lcp(ua, ub);
    // everything up to the per-request part is shared: categories, accounts, contacts come before "today"
    expect(ua.slice(0, shared)).toContain(U(21));
    expect(ua.slice(0, shared)).toContain(U(2));
    expect(ua.slice(0, shared)).toContain(U(40));
    expect(ua.indexOf('"today"')).toBeGreaterThan(ua.indexOf('"contacts"'));
    expect(ua.indexOf('"text"')).toBeGreaterThan(ua.indexOf('"today"'));
  });

  it("classifier: items of one sweep share categories + examples; only the item differs", () => {
    const cctx = { categories: ctx.categories.map((c) => ({ id: c.id, name: c.name, type: c.type })), rules: [], history: buildHistory([]) };
    const examples = [{ category_id: U(10), merchant: "Highlands", note: null }] as never;
    const a = buildClassifyMessages({ text: "MOMO 123 THANH TOAN", direction: "out", amount: 45000 }, cctx, examples);
    const b = buildClassifyMessages({ text: "VCB CT DEN 98765", direction: "out", amount: 200000 }, cctx, examples);
    expect(a[0]!.content).toBe(b[0]!.content);
    const shared = lcp(a[1]!.content, b[1]!.content);
    expect(a[1]!.content.slice(0, shared)).toContain('"examples"');
    expect(a[1]!.content.indexOf('"text"')).toBeGreaterThan(a[1]!.content.indexOf('"examples"'));
  });

  it("legacy assistant parser: accounts/categories before today and text", () => {
    const { messages } = buildMessages("cf 30k", "2026-12-01", ctx.accounts, ctx.categories);
    const u = messages[1]!.content;
    expect(u.indexOf('"today"')).toBeGreaterThan(u.indexOf('"categories"'));
  });

  it("no timestamps or per-request values inside any system prompt", () => {
    const sys = [
      buildAgentMessages("x", [], ctx).messages[0]!.content,
      buildMessages("x", "2026-12-01", ctx.accounts, ctx.categories).messages[0]!.content,
      buildInsightMessages(
        { period: "DAY", start: "2026-12-01", end: "2026-12-01", asOf: "2026-12-01", prevStart: "2026-11-30", prevEnd: "2026-11-30", histStart: "2026-11-01", histEnd: "2026-11-30", inProgress: true } as never,
        { income: "0", expense: "0", net: "0", prev_expense: "0", change_pct: null, daily_avg: "0", forecast_expense: null, suggested_limit: null, by_category: [] } as never,
        "2026-12-01",
        [],
      ).messages[0]!.content,
    ];
    for (const s of sys) {
      expect(s).not.toMatch(/2026-12-0\d/);
      expect(s).not.toMatch(/\d{2}:\d{2}:\d{2}/);
    }
  });
});

describe("deterministic layers first, AI only when needed (and once per identical item)", () => {
  const categories = [
    { id: U(10), name: "Di chuyển", type: "EXPENSE" },
    { id: U(11), name: "Ăn uống", type: "EXPENSE" },
    { id: U(12), name: "Khác", type: "EXPENSE" },
  ];
  const baseCtx = (): LoadedContext => ({ categories, rules: [], history: buildHistory([]), examples: [] });
  function deps(answer: string) {
    const ai = vi.fn(async () => ({ content: answer, usage: { prompt_tokens: 900, completion_tokens: 30, cache_hit_tokens: 700 } }));
    const gw = {
      aiReserve: vi.fn(async () => ({ id: "r1" })),
      aiSettle: vi.fn(async () => ({})),
      aiMarkUnknown: vi.fn(async () => ({})),
    } as unknown as FinanceGateway;
    return { d: { cfg: {} as Config, gw, ai }, ai, gw };
  }

  it("a dictionary hit (Grab) never calls the model", async () => {
    const { d, ai } = deps("{}");
    const r = await classifyInput(d as never, OWNER, { text: "GRAB 2611 THANH TOAN GRABBIKE", direction: "out", amount: 30000 }, baseCtx(), true);
    expect(r?.method).toBe("DICTIONARY");
    expect(r?.categoryId).toBe(U(10));
    expect(ai).not.toHaveBeenCalled();
  });

  it("the same opaque content twice in one sweep costs one call; the reservation is tagged with its feature", async () => {
    const { d, ai, gw } = deps(JSON.stringify({ category: U(11), merchant: "Quán Bà Ba", confidence: 0.82 }));
    const ctx = baseCtx();
    const input = { text: "CT DEN 0123456789 QUAN BA BA", direction: "out" as const, amount: 85000 };
    const a = await classifyInput(d as never, OWNER, input, ctx, true);
    const b = await classifyInput(d as never, OWNER, { ...input, amount: 90000 }, ctx, true);
    expect(ai).toHaveBeenCalledTimes(1);
    expect(a?.categoryId).toBe(U(11));
    expect(b?.categoryId).toBe(U(11));
    expect((gw.aiReserve as any).mock.calls[0][5]).toBe("classify");
    // the model was called with thinking off
    expect((ai.mock.calls[0] as any)[0].thinking).toEqual({ type: "disabled" });
  });

  it("allowAi=false (bank webhook path) never calls the model", async () => {
    const { d, ai } = deps("{}");
    await classifyInput(d as never, OWNER, { text: "CT DEN 0123 QUAN LA", direction: "out", amount: 85000 }, baseCtx(), false);
    expect(ai).not.toHaveBeenCalled();
  });
});

describe("feature tagging is backward compatible", () => {
  it("falls back to the untagged reserve when migration 022 is not applied yet", async () => {
    const calls: Record<string, unknown>[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_u: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body));
        calls.push(body);
        if ("p_feature" in body) return new Response(JSON.stringify({ code: "PGRST202", message: "not found" }), { status: 404 });
        return new Response(JSON.stringify({ id: "r1" }), { status: 200 });
      }),
    );
    const g = new SupabaseFinanceGateway({ supabaseUrl: "https://db.test", serviceRoleKey: "sk", dbTimeoutMs: 1000 } as Config);
    expect(await g.aiReserve(OWNER, 10, 100, "deepseek", "deepseek-flash", "agent")).toEqual({ id: "r1" });
    expect(calls).toHaveLength(2);
    expect(calls[1]).not.toHaveProperty("p_feature");
  });
});
