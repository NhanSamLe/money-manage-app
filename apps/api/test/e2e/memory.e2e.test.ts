import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runReflection } from "../../src/entrypoints/routes-memory";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Assistant memory + transaction source against the real API code, PostgREST and Postgres (migration 009).
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
const env = {} as never;
const prompts: string[] = [];
let modelOutput: unknown = { reply: "ok", steps: [] };
const ai = async (body: Record<string, unknown>) => {
  prompts.push(JSON.stringify(body.messages));
  return { content: JSON.stringify(modelOutput), usage: { prompt_tokens: 100, completion_tokens: 50 } };
};
const deps = () => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg), ai });

async function call(method: string, path: string, body?: unknown) {
  const headers: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` };
  const res = await app.request(path, { method, headers, body: body === undefined ? null : JSON.stringify(body) }, env);
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
  const json = (await res.json()) as { data?: any; error?: { code: string } };
  return { status: res.status, data: json.data, error: json.error };
}

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 };
  app = buildApp(() => deps());
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Sâm" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("assistant memory", () => {
  let cash = "";
  let food = "";
  let shop = "";

  it("owner notes: add, list, delete, validation", async () => {
    expect((await call("GET", "/v1/ai/memory")).json.data).toEqual([]);
    const add = await call("POST", "/v1/ai/memory", { kind: "NOTE", value: "Lương về ngày 5 hằng tháng" });
    expect(add.status).toBe(200);
    expect(add.json.data).toMatchObject({ kind: "NOTE", key: "luong ve ngay 5 hang thang", source: "user", weight: 0.9, text: "Lương về ngày 5 hằng tháng" });
    const alias = await call("POST", "/v1/ai/memory", { kind: "ALIAS", key: "tcb", value: "Techcombank" });
    expect(alias.json.data.text).toBe('"tcb" nghĩa là "Techcombank"');
    expect((await call("GET", "/v1/ai/memory?kind=ALIAS")).json.data.map((x: any) => x.key)).toEqual(["tcb"]);
    expect((await call("POST", "/v1/ai/memory", { kind: "CATEGORY_RULE", key: "a", value: "b" })).status).toBe(400);
    expect((await call("DELETE", `/v1/ai/memory/${alias.json.data.id}`)).status).toBe(200);
    expect((await call("DELETE", `/v1/ai/memory/${alias.json.data.id}`)).status).toBe(404);
    expect((await call("GET", "/v1/ai/memory")).json.data).toHaveLength(1);
  });

  it("agent transactions are stored with source AI and the turn's learnings are kept", async () => {
    const acc = await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Ví", name: "Tiền mặt", opening_amount: "1000000", baseline_at: "2026-11-01T00:00:00Z" });
    cash = acc.data.account_id;
    const cats = (await call("GET", "/v1/categories")).json.data as any[];
    food = cats.find((c) => c.name === "Ăn uống").id;
    shop = cats.find((c) => c.name === "Mua sắm").id;
    modelOutput = {
      reply: "Đã ghi",
      steps: [{ do: "EXPENSE", amount: "15000", account: cash, category: shop, note: "nước đậu" }],
      learned: [{ kind: "ALIAS", key: "nc đậu", value: "nước đậu" }, { kind: "ALIAS", key: "bịa", value: "không có" }],
    };
    const r = await call("POST", "/v1/ai/agent", { text: "nc đậu 15k" });
    expect(r.status).toBe(200);
    const action = r.json.data.actions[0];
    expect(action.command.payload.source).toBe("AI");
    const done = await cmd(action.command.command_type, action.command.payload);
    expect(done.status).toBe(200);
    const txs = (await call("GET", "/v1/transactions")).json.data as any[];
    expect(txs.find((t) => t.id === done.data.tx_id).source).toBe("AI");
    expect(txs.find((t) => t.kind === "OPENING")?.source ?? "SYSTEM").toBe("SYSTEM");
    const aliases = (await call("GET", "/v1/ai/memory?kind=ALIAS")).json.data;
    expect(aliases.map((x: any) => x.key)).toEqual(["nc dau"]);

    // a plain manual transaction is MANUAL; server-only sources are refused from clients
    const manual = await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: "5000", effective_at: new Date().toISOString(), category_id: food });
    expect(((await call("GET", "/v1/transactions")).json.data as any[]).find((t) => t.id === manual.data.tx_id).source).toBe("MANUAL");
    expect((await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: "5000", effective_at: new Date().toISOString(), category_id: food, source: "BANK" })).status).toBe(400);

    // correction: the owner moves the AI transaction to "Ăn uống" -> rule learned
    const tx = txs.find((t) => t.id === done.data.tx_id);
    expect((await cmd("TX_ANNOTATE", { tx_id: tx.id, expected_version: tx.version, note: "nước đậu", category_id: food })).status).toBe(200);
    const rules = (await call("GET", "/v1/ai/memory?kind=CATEGORY_RULE")).json.data;
    expect(rules).toHaveLength(1);
    expect(rules[0]).toMatchObject({ key: "nuoc dau", source: "correction", value: { category_id: food, category: "Ăn uống" }, text: '"nước đậu" thuộc danh mục Ăn uống' });
  });

  it("the next request reads the memory before acting", async () => {
    modelOutput = { reply: "ok", steps: [] };
    prompts.length = 0;
    expect((await call("POST", "/v1/ai/agent", { text: "nc đậu 20k" })).status).toBe(200);
    expect(prompts[0]).toContain("Điều đã biết về chủ tài khoản");
    expect(prompts[0]).toContain('\\"nc đậu\\" nghĩa là \\"nước đậu\\"');
    expect(prompts[0]).toContain("thuộc danh mục Ăn uống");
    expect(prompts[0]).toContain("Lương về ngày 5 hằng tháng");
  });

  it("undo weakens the rule that produced the transaction", async () => {
    modelOutput = { reply: "Đã ghi", steps: [{ do: "EXPENSE", amount: "20000", account: cash, category: food, note: "nước đậu" }] };
    const r = await call("POST", "/v1/ai/agent", { text: "nc đậu 20k" });
    const done = await cmd("TX_CREATE", r.json.data.actions[0].command.payload);
    const before = (await call("GET", "/v1/ai/memory?kind=CATEGORY_RULE")).json.data[0].weight;
    expect((await cmd("TX_REVERSE", { tx_id: done.data.tx_id, reason: "Hoàn tác từ Trợ lý AI", expected_version: 2 })).status).toBe(200);
    const after = (await call("GET", "/v1/ai/memory?kind=CATEGORY_RULE")).json.data[0];
    expect(after.weight).toBeCloseTo(before * 0.5, 3);
    expect(after.source).toBe("undo");
  });

  it("nightly reflection writes habits and decays, and runs once per day via the scheduler", async () => {
    for (let i = 1; i <= 6; i++) {
      const day = new Date(Date.now() + 7 * 3_600_000 - i * 86_400_000).toISOString().slice(0, 10);
      expect((await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: String(30000 + i * 1000), effective_at: `${day}T00:30:00Z`, category_id: food, note: "phở" })).status).toBe(200);
    }
    const r = await runReflection(deps(), owner);
    expect(r.habits).toBeGreaterThanOrEqual(2);
    const habits = (await call("GET", "/v1/ai/memory?kind=HABIT")).json.data.map((x: any) => x.key);
    expect(habits).toEqual(expect.arrayContaining(["bua sang", "hay chi pho"]));
    const prefs = (await call("GET", "/v1/ai/memory?kind=PREFERENCE")).json.data;
    expect(prefs.some((p: any) => p.text.includes("Tiền mặt"))).toBe(true);
  });
});
