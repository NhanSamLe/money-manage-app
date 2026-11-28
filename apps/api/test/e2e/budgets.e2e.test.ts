import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SupabaseBudgetGateway, applyBudgets } from "../../src/entrypoints/routes-budgets";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { CommandContext } from "../../src/modules/ledger/ports";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Self-adjusting budgets (migration 020) against the real API code, PostgREST and Postgres.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
const env = {} as never;

async function call(method: string, path: string, body?: unknown, extra: Record<string, string> = {}) {
  const res = await app.request(
    path,
    { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, ...extra }, body: body === undefined ? null : JSON.stringify(body) },
    env,
  );
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const r = await call("POST", "/v1/commands", { command_id: id, command_type: type, schema_version: 1, payload }, { "idempotency-key": id });
  expect(r.status, JSON.stringify(r.json)).toBe(200);
  return r.json.data;
}
const vnDay = (offset: number) => new Date(Date.now() + 7 * 3_600_000 + offset * 86_400_000).toISOString().slice(0, 10);
const at = (offset: number) => new Date(`${vnDay(offset)}T05:00:00Z`).toISOString(); // 12:00 local

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
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("self-adjusting budgets", () => {
  let food = "";
  let account = "";
  const ids: string[] = [];

  it("history: one row per expense tx and category with the posted amount; reversed txs net out", async () => {
    account = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Ví", opening_amount: "50000000", baseline_at: new Date(Date.now() - 40 * 86_400_000).toISOString() })).account_id;
    const cats = (await call("GET", "/v1/categories")).json.data as any[];
    food = cats.find((c) => c.type === "EXPENSE").id;
    for (let i = 1; i <= 20; i++) {
      ids.push((await cmd("TX_CREATE", { kind: "EXPENSE", account_id: account, amount: "100000", category_id: food, effective_at: at(-i) })).tx_id);
    }
    // A mistaken expense, cancelled: must not count.
    const wrong = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: account, amount: "9000000", category_id: food, effective_at: at(-3) })).tx_id;
    const txs = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
    await cmd("TX_REVERSE", { tx_id: wrong, reason: "nhầm", expected_version: txs.find((t) => t.id === wrong).version });

    const rows = await new SupabaseBudgetGateway(cfg).history(owner, vnDay(-30), vnDay(-1));
    expect(rows).toHaveLength(20);
    expect(rows.every((r) => r.category_id === food && r.amount === 100_000 && r.recurring === false)).toBe(true);
    expect(rows.map((r) => r.tx_id)).not.toContain(wrong);
    expect(rows[0]!.day).toBe(vnDay(-20));
    // Range validation
    await expect(new SupabaseBudgetGateway(cfg).history(owner, vnDay(0), vnDay(-1))).rejects.toThrow();
  });

  it("proposals from real history, one-tap apply writes the budget, pacing reads it", async () => {
    const month = vnDay(0).slice(0, 7);
    const prop = await call("GET", `/v1/budgets/proposals?month=${month}`);
    expect(prop.status).toBe(200);
    const item = (prop.json.data.items as any[]).find((i) => i.category_id === food);
    // 100.000/day over 20 days -> days-in-month * 100.000 * 1.05, rounded up to 50.000
    expect(item.reason).toBe("new");
    expect(item.proposed % 50_000).toBe(0);
    expect(item.proposed).toBeGreaterThanOrEqual(2_900_000);

    const apply = await call("POST", "/v1/budgets/proposals/apply", { month, items: [{ category_id: food, limit: String(item.proposed) }] });
    expect(apply.status).toBe(200);
    expect(apply.json.data.applied).toBe(1);
    const budgets = (await call("GET", "/v1/budgets")).json.data as any[];
    expect(budgets.find((b) => b.category_id === food).limit_amount).toBe(String(item.proposed));
    // Same apply again: nothing written.
    expect((await call("POST", "/v1/budgets/proposals/apply", { month, items: [{ category_id: food, limit: String(item.proposed) }] })).json.data.applied).toBe(0);

    const pace = await call("GET", "/v1/budgets/pacing");
    expect(pace.status).toBe(200);
    expect(pace.json.data.items[0]).toMatchObject({ category_id: food, limit: item.proposed });
    expect(pace.json.data.items[0].daily_allowance).toBeGreaterThan(0);
  });

  it("server-initiated apply (cron, no device / session) goes through pf_execute_command", async () => {
    const next = new Date(Date.parse(`${vnDay(0).slice(0, 7)}-01T00:00:00Z`) + 40 * 86_400_000).toISOString().slice(0, 7);
    const ctx = { ownerId: owner, sessionId: null, deviceId: null } as unknown as CommandContext;
    const d = { cfg, gw: new SupabaseFinanceGateway(cfg) };
    expect(await applyBudgets(d, ctx, next, [{ category_id: food, limit: 3_000_000, carryover: true }], "auto")).toBe(1);
    // Idempotent: replay with the same seed writes nothing new.
    expect(await applyBudgets(d, ctx, next, [{ category_id: food, limit: 3_000_000, carryover: true }], "auto")).toBe(0);
    const row = (await h.db.query("select limit_amount::text as l, carryover from pf_budget where owner_id = $1 and month = $2", [owner, `${next}-01`])).rows[0];
    expect(row).toEqual({ l: "3000000", carryover: true });
    const ledger = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
    expect(ledger.rows[0].s).toBe("0");
  });
});
