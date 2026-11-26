import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

const BOOTSTRAP = "b".repeat(40);
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";

const env = {} as never;
const uuid = () => crypto.randomUUID();

async function call(method: string, path: string, opts: { body?: unknown; headers?: Record<string, string>; auth?: boolean } = {}) {
  const headers: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, ...opts.headers };
  if (opts.auth !== false) headers["authorization"] = `Bearer ${jwt}`;
  const res = await app.request(path, { method, headers, body: opts.body === undefined ? null : JSON.stringify(opts.body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}

async function command(type: string, payload: unknown, id = uuid()) {
  return call("POST", "/v1/commands", { body: { command_id: id, command_type: type, schema_version: 1, payload }, headers: { "idempotency-key": id } });
}

beforeAll(async () => {
  h = await startHarness();
  const cfg: Config = {
    supabaseUrl: h.baseUrl,
    publishableKey: "pk",
    serviceRoleKey: "sb_secret_e2e",
    bootstrapSecret: BOOTSTRAP,
    ownerEmail: "owner@example.test",
    dbTimeoutMs: 10_000,
  };
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("setup and auth", () => {
  it("reports UNINITIALIZED before setup", async () => {
    const r = await call("GET", "/v1/auth/config", { auth: false });
    expect(r.status).toBe(200);
    expect(r.json.data.setup_state).toBe("UNINITIALIZED");
  });

  it("refuses setup/start without the deployment secret", async () => {
    expect((await call("POST", "/v1/setup/start", { auth: false, headers: { "x-bootstrap-secret": "wrong" }, body: {} })).status).toBe(401);
  });

  it("runs the owner bootstrap: invite -> claim -> device", async () => {
    const start = await call("POST", "/v1/setup/start", { auth: false, headers: { "x-bootstrap-secret": BOOTSTRAP }, body: {} });
    expect(start.status).toBe(200);
    const row = await h.db.query("select id from auth.users where email = 'owner@example.test'");
    owner = row.rows[0].id;
    jwt = await h.mintUserJwt(owner, SESSION);

    const claim = await call("POST", "/v1/setup/claim", { body: { display_name: "Sâm" } });
    expect(claim.status).toBe(200);
    expect(claim.json.data.display_name).toBe("Sâm");
    const again = await call("POST", "/v1/setup/claim", { body: { display_name: "Sâm" } });
    expect(again.json.data.replayed).toBe(true);

    const dev = await call("POST", "/v1/devices/register", { body: { device_id: DEVICE, label: "E2E phone" } });
    expect(dev.status).toBe(200);
  });

  it("locks setup once bound and rejects other users", async () => {
    expect((await call("GET", "/v1/auth/config", { auth: false })).json.data.setup_state).toBe("BOUND");
    expect((await call("POST", "/v1/setup/start", { auth: false, headers: { "x-bootstrap-secret": BOOTSTRAP }, body: {} })).status).toBe(409);
    const intruder = await h.db.query("insert into auth.users(email, email_confirmed_at) values ('x@example.test', now()) returning id");
    const intruderJwt = await h.mintUserJwt(intruder.rows[0].id, SESSION);
    const r = await app.request("/v1/accounts", { headers: { authorization: `Bearer ${intruderJwt}`, "x-device-id": DEVICE } }, env);
    expect(r.status).toBe(403);
    expect((await call("GET", "/v1/accounts", { auth: false })).status).toBe(401);
  });
});

describe("money flows through the real API, PostgREST and database", () => {
  let bank = "";
  let cash = "";
  let food = "";
  let salary = "";
  let expenseTx = { id: "", version: 0 };

  it("creates accounts with opening balances", async () => {
    const a = await command("ACCOUNT_CREATE", { kind: "BANK", institution: "VCB", name: "Vietcombank", opening_amount: "10000000", baseline_at: "2026-11-01T00:00:00Z" });
    expect(a.status).toBe(200);
    bank = a.json.data.account_id;
    const b = await command("ACCOUNT_CREATE", { kind: "CASH", institution: "Ví", name: "Tiền mặt", opening_amount: "0", baseline_at: "2026-11-01T00:00:00Z" });
    cash = b.json.data.account_id;
    const list = await call("GET", "/v1/accounts");
    expect(list.json.data.find((x: any) => x.id === bank).balance).toBe("10000000");
    const cats = await call("GET", "/v1/categories");
    food = cats.json.data.find((c: any) => c.name === "Ăn uống").id;
    salary = cats.json.data.find((c: any) => c.name === "Lương").id;
  });

  it("posts income, expense and transfer with fee; replays safely", async () => {
    await command("TX_CREATE", { kind: "INCOME", account_id: bank, amount: "20000000", effective_at: "2026-11-05T02:00:00Z", category_id: salary });
    const id = uuid();
    const body = { kind: "EXPENSE", account_id: bank, amount: "65000", effective_at: "2026-11-06T05:00:00Z", category_id: food, merchant: "Cơm trưa" };
    const first = await command("TX_CREATE", body, id);
    const replay = await command("TX_CREATE", body, id);
    expect(first.json.data.status).toBe("COMMITTED");
    expect(replay.json.data.status).toBe("REPLAYED");
    expect(replay.json.data.tx_id).toBe(first.json.data.tx_id);
    const conflict = await command("TX_CREATE", { ...body, amount: "66000" }, id);
    expect(conflict.status).toBe(409);
    expect(conflict.json.error?.code).toBe("DUPLICATE_KEY_MISMATCH");

    const t = await command("TX_CREATE", { kind: "TRANSFER", account_id: bank, to_account_id: cash, amount: "1000000", fee: "3300", effective_at: "2026-11-07T02:00:00Z" });
    expect(t.status).toBe(200);

    const accounts = (await call("GET", "/v1/accounts")).json.data;
    expect(accounts.find((x: any) => x.id === bank).balance).toBe(String(10_000_000 + 20_000_000 - 65_000 - 1_003_300));
    expect(accounts.find((x: any) => x.id === cash).balance).toBe("1000000");

    const txs = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
    const e = txs.find((x) => x.merchant === "Cơm trưa");
    expect(e.amount).toBe("65000");
    expectTx(e);
    expenseTx = { id: e.id, version: e.version };
  });

  it("serves the monthly summary with fee counted as expense", async () => {
    const s = (await call("GET", "/v1/reports/summary?month=2026-11")).json.data;
    expect(s.income).toBe("20000000");
    expect(s.expense).toBe(String(65_000 + 3_300));
    expect(s.expense_by_category[0].name).toBe("Ăn uống");
    expect((await call("GET", "/v1/reports/summary?month=2026-13")).status).toBe(400);
  });

  it("reverses a transaction and keeps history", async () => {
    const r = await command("TX_REVERSE", { tx_id: expenseTx.id, reason: "nhập nhầm", expected_version: expenseTx.version });
    expect(r.status).toBe(200);
    const stale = await command("TX_REVERSE", { tx_id: expenseTx.id, reason: "again", expected_version: expenseTx.version });
    expect(stale.status).toBe(409);
    const txs = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
    expect(txs.find((x) => x.id === expenseTx.id).status).toBe("VOID");
  });

  it("edits: reclassify, correct, rename and archive accounts", async () => {
    const cats = (await call("GET", "/v1/categories")).json.data as any[];
    const transport = cats.find((c) => c.name === "Di chuyển").id;
    const created = await command("TX_CREATE", { kind: "EXPENSE", account_id: bank, amount: "90000", effective_at: "2026-11-08T05:00:00Z", category_id: food });
    const list = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
    const tx = list.find((t) => t.id === created.json.data.tx_id);
    const ann = await command("TX_ANNOTATE", { tx_id: tx.id, expected_version: tx.version, category_id: transport, note: "grab" });
    expect(ann.status).toBe(200);
    const after = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((t) => t.id === tx.id);
    expect(after.category_id).toBe(transport);
    expect(after.note).toBe("grab");

    const corr = await command("TX_CORRECT", {
      tx_id: tx.id,
      expected_version: after.version,
      reason: "sai số tiền",
      replacement: { kind: "EXPENSE", account_id: bank, amount: "95000", effective_at: "2026-11-08T05:00:00Z", category_id: transport },
    });
    expect(corr.status).toBe(200);
    const all = (await call("GET", "/v1/transactions?limit=100")).json.data as any[];
    expect(all.find((t) => t.id === tx.id).status).toBe("VOID");
    expect(all.find((t) => t.id === corr.json.data.tx_id).related_tx_id).toBe(tx.id);

    const accs = (await call("GET", "/v1/accounts")).json.data as any[];
    const c = accs.find((a) => a.id === cash);
    const ren = await command("ACCOUNT_UPDATE", { account_id: cash, expected_version: c.version, name: "Ví tiền mặt" });
    expect(ren.status).toBe(200);
    expect(((await call("GET", "/v1/accounts")).json.data as any[]).find((a) => a.id === cash).name).toBe("Ví tiền mặt");
  });

  it("handles debts end to end", async () => {
    const contact = await command("CONTACT_CREATE", { alias: "Nam" });
    const debt = await command("DEBT_CREATE", { direction: "RECEIVABLE", contact_id: contact.json.data.contact_id, principal: "500000", originated_at: "2026-11-10T02:00:00Z", account_id: bank, due_date: "2026-11-20" });
    expect(debt.status).toBe(200);
    const list = (await call("GET", "/v1/debts")).json.data as any[];
    expect(list[0]).toMatchObject({ contact_alias: "Nam", remaining: "500000", state: "OPEN", overdue: true });
    const repay = await command("DEBT_REPAY", { debt_id: list[0].id, account_id: bank, principal: "500001", effective_at: "2026-11-12T02:00:00Z", expected_version: list[0].version });
    expect(repay.status).toBe(422);
    expect(repay.json.error?.code).toBe("INSUFFICIENT_PRINCIPAL");
    const ok = await command("DEBT_REPAY", { debt_id: list[0].id, account_id: bank, principal: "500000", effective_at: "2026-11-12T02:00:00Z", expected_version: list[0].version });
    expect(ok.json.data.state).toBe("SETTLED");
  });

  it("handles goals, budgets and recurring", async () => {
    const goal = await command("GOAL_CREATE", { name: "Du lịch", target: "5000000" });
    const goals = (await call("GET", "/v1/goals")).json.data;
    await command("GOAL_ALLOCATE", { goal_id: goal.json.data.goal_id, account_id: cash, amount: "300000", expected_version: goals.goals[0].version });
    const after = (await call("GET", "/v1/goals")).json.data;
    expect(after.goals[0].allocated).toBe("300000");
    expect(after.accounts.find((a: any) => a.account_id === cash).available).toBe("700000");

    const month = new Date(Date.now() + 7 * 3_600_000).toISOString().slice(0, 7);
    const b = await command("BUDGET_UPSERT", { month, limit: "1000000", carryover: false, category_id: food });
    expect(b.status).toBe(200);
    expect(((await call("GET", "/v1/budgets")).json.data as any[])[0].limit_amount).toBe("1000000");

    const tomorrow = new Date(Date.now() + 31 * 3_600_000).toISOString().slice(0, 10);
    const rec = await command("RECURRING_UPSERT", { name: "Netflix", kind: "EXPENSE", account_id: bank, amount: "70000", interval: "MONTHLY", next_date: tomorrow, enabled: true, category_id: food });
    expect(rec.status).toBe(200);
    const items = (await call("GET", "/v1/recurring")).json.data as any[];
    expect(items[0].expected.length).toBe(1);
  });

  it("keeps the ledger balanced and rejects unbuilt commands honestly", async () => {
    const r = await h.db.query("select coalesce(sum(signed_amount::numeric),0) as s from pf_entry");
    expect(Number(r.rows[0].s)).toBe(0);
    const nb = await command("SPLIT_BILL_CREATE", {});
    expect(nb.status).toBe(422);
    expect(nb.json.error?.code).toBe("NOT_IMPLEMENTED");
  });
});

function expectTx(t: any) {
  expect(t).toHaveProperty("effective_at");
  expect(t.status).toBe("POSTED");
}
