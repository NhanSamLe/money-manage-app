import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { secretEquals, tickSummary } from "../../src/entrypoints/routes-insights";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { RemindersGateway } from "../../src/modules/reminders/gateway";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";

const OWNER = "11111111-1111-1111-1111-111111111111";
const env = {} as never;
const emptyStats = { income: "0", expense: "0", by_category: [], daily: [] };

function makeApp(cronSecret?: string) {
  const claimed = new Set<string>();
  const pushes: unknown[] = [];
  const cfg: Config = {
    supabaseUrl: "https://x.supabase.co", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@example.test", dbTimeoutMs: 1000,
    onesignalRestKey: "rk", ...(cronSecret ? { cronSecret } : {}),
  };
  const gw = { getOwnerId: vi.fn(async () => OWNER), readBudgets: vi.fn(async () => []) } as unknown as FinanceGateway;
  const rg: RemindersGateway = {
    settingsRead: async () => null,
    settingsWrite: async (_o, s) => s,
    dayStatus: async () => ({ date: "x", skipped: [], done: { breakfast: false, lunch: false, dinner: false }, has_accounts: true }),
    skipSet: async () => ({ date: "x", skipped: [], done: { breakfast: false, lunch: false, dinner: false } }),
    pushClaim: async (_o, k) => (claimed.has(k) ? false : (claimed.add(k), true)),
    insightCreate: async (_o, period, start, end, payload) => ({ id: crypto.randomUUID(), period, period_start: start, period_end: end, created_at: new Date().toISOString(), ...(payload as object) }),
    insightList: async () => [],
    insightGet: async () => ({}),
    insightLatest: async () => null,
    periodStats: async () => emptyStats,
  };
  const pushFetch = (async (_u: unknown, init?: RequestInit) => {
    pushes.push(JSON.parse(String(init?.body)));
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
  const verifier = { verify: vi.fn() } as unknown as SessionVerifier;
  const reflectStats = { days: 30, meals: [], keywords: [], weekdays: [], preferences: [] };
  const mg = { confirmRecent: async () => 0, reflectStats: async () => reflectStats, replace: async () => 0, decay: async () => ({ decayed: 0, dropped: 0 }) } as unknown as MemoryGateway;
  const app = buildApp(() => ({ cfg, gw, verifier, rg, pushFetch, mg }) as any);
  const tick = (secret?: string) =>
    app.request("/v1/internal/tick", { method: "POST", headers: secret === undefined ? {} : { "x-cron-secret": secret } }, env);
  return { tick, claimed, pushes };
}

describe("POST /v1/internal/tick", () => {
  it("is 404 when CRON_SECRET is not configured", async () => {
    const { tick } = makeApp();
    expect((await tick("anything")).status).toBe(404);
  });

  it("is 401 without or with a wrong secret, and runs nothing", async () => {
    const { tick, claimed } = makeApp("s3cret-value");
    expect((await tick()).status).toBe(401);
    expect((await tick("")).status).toBe(401);
    expect((await tick("s3cret-valuX")).status).toBe(401);
    expect(claimed.size).toBe(0);
  });

  it("runs the scheduler with the right secret and is idempotent", async () => {
    const { tick, claimed, pushes } = makeApp("s3cret-value");
    const r1 = await tick("s3cret-value");
    expect(r1.status).toBe(200);
    const s1 = ((await r1.json()) as { data: Record<string, number> }).data;
    expect(Object.keys(s1).sort()).toEqual(["budget_alerts", "cash_check", "meals", "processed", "reviews"]);
    expect(s1.processed).toBe(claimed.size);
    const pushed = [...claimed].filter((k) => !k.startsWith("reflect:")).length; // the nightly reflection sends nothing
    expect(pushes.length).toBe(pushed);
    const r2 = await tick("s3cret-value");
    expect(((await r2.json()) as { data: { processed: number } }).data.processed).toBe(0);
    expect(pushes.length).toBe(pushed);
  });
});

describe("helpers", () => {
  it("secretEquals compares exactly", async () => {
    expect(await secretEquals("abc", "abc")).toBe(true);
    expect(await secretEquals("abd", "abc")).toBe(false);
    expect(await secretEquals("abcd", "abc")).toBe(false);
    expect(await secretEquals("", "")).toBe(false);
  });
  it("tickSummary counts by kind only", () => {
    expect(tickSummary(["meal:lunch:2026-11-28", "cash_check:2026-11-28", "review:day:2026-11-28", "budget:b:80:2026-11"])).toEqual({
      processed: 4, meals: 1, cash_check: 1, reviews: 1, budget_alerts: 1,
    });
  });
});
