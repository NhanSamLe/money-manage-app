import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { notifyUnclear, runClassifySweep } from "../../src/entrypoints/routes-classify";
import { SupabaseMemoryGateway } from "../../src/modules/ai/memory-gateway";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Automatic categorization (migration 015) against the real API code, PostgREST and Postgres; DeepSeek is faked.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
let cash = "";
const cats: Record<string, string> = {};
const env = {} as never;
// The fake model: whatever it is told for the next call.
let modelReply: Record<string, unknown> = { category: "", confidence: 0 };
const ai = vi.fn(async () => ({ content: JSON.stringify(modelReply), usage: { prompt_tokens: 50, completion_tokens: 10 } }));

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(
    path,
    { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` }, body: body === undefined ? null : JSON.stringify(body) },
    env,
  );
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const res = await app.request(
    "/v1/commands",
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, "idempotency-key": id },
      body: JSON.stringify({ command_id: id, command_type: type, schema_version: 1, payload }),
    },
    env,
  );
  const j = (await res.json()) as any;
  return { status: res.status, data: j.data, error: j.error };
}
async function tx(id: string) {
  const list = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
  return list.find((t) => t.id === id);
}
async function captured(note: string, amount = 200000) {
  const r = await cmd("TX_CREATE", { kind: "UNKNOWN_DEBIT", account_id: cash, amount: String(amount), effective_at: new Date().toISOString(), note, source: "NOTIFICATION" });
  expect(r.status).toBe(200);
  return r.data.tx_id as string;
}
async function ledgerOk() {
  const s = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(s.rows[0].s).toBe("0");
  const acc = ((await call("GET", "/v1/accounts")).json.data as any[]).find((a) => a.id === cash);
  return Number(acc.balance);
}

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg), ai }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  cash = (await cmd("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "VCB", opening_amount: "5000000", baseline_at: new Date(Date.now() - 86_400_000).toISOString() })).data.account_id;
  for (const c of (await call("GET", "/v1/categories")).json.data as any[]) cats[c.name] = c.id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("automatic categorization", () => {
  it("a captured Grab payment is classified in place: same id, EXPENSE, ledger balanced", async () => {
    const id = await captured("MBVCB.123.456.GRAB*RIDE thanh toan", 45000);
    const t = await tx(id);
    expect(t).toMatchObject({ id, kind: "EXPENSE", category_id: cats["Di chuyển"], merchant: "Grab" });
    expect(t.ai).toMatchObject({ status: "APPLIED", method: "DICTIONARY", category_id: cats["Di chuyển"] });
    expect(await ledgerOk()).toBe(5_000_000 - 45_000);
    expect(ai).not.toHaveBeenCalled();
  });

  it("the model decides when rules can't; low confidence stays a one-tap suggestion", async () => {
    modelReply = { category: cats["Ăn uống"], merchant: "Quán cô Ba", confidence: 0.84 };
    const sure = await captured("QUAN CO BA HAI PHONG", 60000);
    expect(await tx(sure)).toMatchObject({ kind: "EXPENSE", category_id: cats["Ăn uống"], ai: { status: "APPLIED", method: "AI" } });

    modelReply = { category: cats["Mua sắm"], merchant: "", confidence: 0.4 };
    const unsure = await captured("IBFT 0123 CT tu 1026746096 toi 998877", 200000);
    const u = await tx(unsure);
    expect(u).toMatchObject({ kind: "UNKNOWN_DEBIT", category_id: null, ai: { status: "SUGGESTED", category_id: cats["Mua sắm"] } });

    const pending = (await call("GET", "/v1/ai/classify/pending")).json.data;
    expect(pending.total).toBe(1);
    expect(pending.items[0]).toMatchObject({ id: unsure, account_name: "VCB" });
    expect(pending.items[0].suggestions[0]).toMatchObject({ category_id: cats["Mua sắm"] });
    expect(pending.items[0].suggestions.length).toBeGreaterThanOrEqual(3);
    // The batched push (stored in the inbox; delivery is off here). Driven at a daytime clock: nights are quiet.
    const deps = { cfg, gw: new SupabaseFinanceGateway(cfg) };
    expect(await notifyUnclear(deps, owner, new Date("2030-01-02T05:00:00Z"), "cron")).toBe(1);
    expect(await notifyUnclear(deps, owner, new Date("2030-01-02T06:00:00Z"), "cron")).toBe(0); // already notified
    const inbox = (await call("GET", "/v1/notifications")).json.data;
    expect(inbox.items.some((n: any) => n.type === "classify" && n.data.route === "/classify")).toBe(true);
    await ledgerOk();
  });

  it("one tap (TX_ANNOTATE on an unknown row) classifies in place, clears it from pending and teaches a rule", async () => {
    const pending = (await call("GET", "/v1/ai/classify/pending")).json.data;
    const item = pending.items[0];
    const before = await ledgerOk();
    const r = await cmd("TX_ANNOTATE", { tx_id: item.id, expected_version: item.version, category_id: cats["Hóa đơn"], note: "Tiền điện tháng 11" });
    expect(r.status).toBe(200);
    expect(r.data.reclassified).toBe(true);
    const t = await tx(item.id);
    expect(t).toMatchObject({ id: item.id, kind: "EXPENSE", category_id: cats["Hóa đơn"], note: "Tiền điện tháng 11", ai: { status: "CORRECTED" } });
    expect(await ledgerOk()).toBe(before);
    expect((await call("GET", "/v1/ai/classify/pending")).json.data.total).toBe(0);
    const rules = await new SupabaseMemoryGateway(cfg).list(owner, "CATEGORY_RULE", 50);
    expect(rules.some((m) => m.value.category_id === cats["Hóa đơn"])).toBe(true);
  });

  it("a learned rule classifies the next one without the model", async () => {
    // Teach "quan bun cha huong" -> Ăn uống through a pick, then capture the same place again.
    modelReply = { category: cats["Khác"], confidence: 0.3 };
    const first = await captured("MBVCB.77.QUAN BUN CHA HUONG LIEN.CT", 50000);
    const f = await tx(first);
    expect(f.kind).toBe("UNKNOWN_DEBIT");
    expect((await cmd("TX_ANNOTATE", { tx_id: first, expected_version: f.version, category_id: cats["Ăn uống"] })).status).toBe(200);
    ai.mockClear();
    const again = await captured("MBVCB.99.QUAN BUN CHA HUONG LIEN.CT", 55000);
    expect(await tx(again)).toMatchObject({ kind: "EXPENSE", category_id: cats["Ăn uống"], ai: { status: "APPLIED", method: "MEMORY" } });
    expect(ai).not.toHaveBeenCalled();
    await ledgerOk();
  });

  it("wrong-type categories are refused; the sweep never touches what the owner decided", async () => {
    const id = await captured("zzz opaque", 1000);
    const t = await tx(id);
    const bad = await cmd("TX_ANNOTATE", { tx_id: id, expected_version: t.version, category_id: cats["Lương"] });
    expect(bad.status).toBe(422);
    expect(bad.error.code).toBe("CATEGORY_MISMATCH");
    const before = await h.db.query("select count(*)::int as n from pf_tx_classification");
    const r = await runClassifySweep({ cfg, gw: new SupabaseFinanceGateway(cfg), ai }, owner, 20, new Date(), false);
    expect(r?.checked).toBe(0); // everything is already classified or decided
    const after = await h.db.query("select count(*)::int as n from pf_tx_classification");
    expect(after.rows[0].n).toBe(before.rows[0].n);
    await ledgerOk();
  });
});
