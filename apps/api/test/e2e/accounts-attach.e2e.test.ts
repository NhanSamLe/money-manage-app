import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { resetSepayCache } from "../../src/modules/bank/sepay";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Migration 011 (ACCOUNT_UPDATE: institution, last4, balance) and attaching a SePay bank account to an EXISTING
// MoMa account, against the real API code, PostgREST and Postgres. SePay and OneSignal are faked.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";
const EXT = "11111111-aaaa-4aaa-8aaa-111111111111";
const NUMBER = "0451000123456";
const KEY = "webhook-shared-key";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
const env = {} as never;
let bankBalance = 5_000_000;

const fakeSepay: typeof fetch = async (input) => {
  if (String(input).includes("/bank-accounts")) {
    return new Response(
      JSON.stringify({ status: "success", data: [{ id: EXT, account_holder_name: "LE DAO A", account_number: NUMBER, accumulated: bankBalance, active: 1, bank_short_name: "Vietcombank", label: "VCB", connection_type: "api" }] }),
      { status: 200 },
    );
  }
  return new Response(JSON.stringify({ status: "success", data: [] }), { status: 200 });
};
const fakePush: typeof fetch = async () => new Response(JSON.stringify({ id: "n" }), { status: 200 });

async function call(method: string, path: string, opts: { body?: unknown; headers?: Record<string, string>; auth?: boolean } = {}) {
  const headers: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, ...opts.headers };
  if (opts.auth !== false) headers["authorization"] = `Bearer ${jwt}`;
  const res = await app.request(path, { method, headers, body: opts.body === undefined ? null : JSON.stringify(opts.body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string }; success?: boolean } };
}
async function command(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  return call("POST", "/v1/commands", { body: { command_id: id, command_type: type, schema_version: 1, payload }, headers: { "idempotency-key": id } });
}
const account = async (id: string) => ((await call("GET", "/v1/accounts")).json.data as any[]).find((a) => a.id === id);

beforeAll(async () => {
  h = await startHarness();
  const cfg = {
    supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000,
    sepayToken: "sepay-token", sepayWebhookKey: KEY, onesignalRestKey: "push-key",
  } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg), sepayFetch: fakeSepay, pushFetch: fakePush }));
  expect((await call("POST", "/v1/setup/start", { auth: false, body: { email: "owner@example.test" } })).status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { body: { display_name: "Sâm" } })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { body: { device_id: DEVICE, label: "E2E" } })).status).toBe(200);
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("ACCOUNT_UPDATE: institution, last4 and balance (migration 011)", () => {
  let wallet = "";
  let food = "";

  it("edits the bank / wallet name and the last 4 digits; bad last4 is refused", async () => {
    const c = await command("ACCOUNT_CREATE", { kind: "WALLET", institution: "MoMo", name: "MoMo" });
    wallet = c.json.data.account_id;
    food = ((await call("GET", "/v1/categories")).json.data as any[]).find((x) => x.name === "Ăn uống").id;
    const a = await account(wallet);
    expect(a.balance).toBeNull();
    const u = await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: a.version, name: "Ví MoMo", institution: "MoMo", last4: "1234" });
    expect(u.status).toBe(200);
    expect(await account(wallet)).toMatchObject({ name: "Ví MoMo", institution: "MoMo", last4: "1234" });
    const bad = await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: a.version + 1, last4: "12a4" });
    expect(bad.status).toBe(400);
    const clear = await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: a.version + 1, last4: "" });
    expect(clear.status).toBe(200);
    expect((await account(wallet)).last4).toBeNull();
  });

  it("unknown baseline: balance sets the opening just before the first transaction", async () => {
    await command("TX_CREATE", { kind: "EXPENSE", account_id: wallet, amount: "120000", effective_at: "2026-11-20T05:00:00Z", category_id: food });
    const a = await account(wallet);
    expect(a.balance).toBeNull();
    const r = await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: a.version, balance: "880000" });
    expect(r.status).toBe(200);
    expect((await account(wallet)).balance).toBe("880000");
    const opening = (await h.db.query("select amount::bigint as amount, effective_at from pf_tx where account_id = $1 and kind = 'OPENING'", [wallet])).rows[0];
    expect(Number(opening.amount)).toBe(1_000_000); // 880.000 + the 120.000 already spent
    expect(new Date(opening.effective_at).toISOString()).toBe("2026-11-20T04:59:59.000Z");
  });

  it("known baseline: a different balance posts an ADJUSTMENT outside income / expense; same balance posts nothing", async () => {
    const summary = async () => (await call("GET", "/v1/reports/summary?month=2026-11")).json.data;
    const before = await summary();
    const a = await account(wallet);
    const r = await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: a.version, balance: "800000" });
    expect(r.status).toBe(200);
    expect((await account(wallet)).balance).toBe("800000");
    const adj = (await h.db.query("select amount::bigint as amount from pf_tx where account_id = $1 and kind = 'ADJUSTMENT'", [wallet])).rows;
    expect(adj.map((x: any) => Number(x.amount))).toEqual([80_000]);
    const after = await summary();
    expect(after.expense).toBe(before.expense);
    expect(after.income).toBe(before.income);
    const b = await account(wallet);
    await command("ACCOUNT_UPDATE", { account_id: wallet, expected_version: b.version, balance: "800000" });
    expect((await h.db.query("select count(*)::int as n from pf_tx where account_id = $1 and kind = 'ADJUSTMENT'", [wallet])).rows[0].n).toBe(1);
    const ledger = await h.db.query("select coalesce(sum(signed_amount::numeric),0) as s from pf_entry");
    expect(Number(ledger.rows[0].s)).toBe(0);
  });
});

describe("SePay: attach to an existing MoMa account", () => {
  let vcb = "";
  beforeEach(() => resetSepayCache());

  it("keeps the account's history, sets the unknown opening from the bank, then the webhook posts on it", async () => {
    vcb = (await command("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "Vietcombank" })).json.data.account_id;
    const food = ((await call("GET", "/v1/categories")).json.data as any[]).find((x) => x.name === "Ăn uống").id;
    const vn = (min: number) => new Date(Date.now() + 7 * 3_600_000 + min * 60_000).toISOString().slice(0, 19).replace("T", " ");
    await command("TX_CREATE", { kind: "EXPENSE", account_id: vcb, amount: "50000", effective_at: new Date(Date.now() - 3_600_000).toISOString(), category_id: food, source: "NOTIFICATION" });
    const txBefore = (await h.db.query("select count(*)::int as n from pf_tx where account_id = $1 and kind <> 'OPENING'", [vcb])).rows[0].n;

    const list = await call("GET", "/v1/banks/sepay/accounts");
    expect(list.json.data[0]).toMatchObject({ number: NUMBER, linked: false });
    const link = await call("POST", "/v1/banks/sepay/link", { body: { external_id: EXT, account_id: vcb } });
    expect(link.status).toBe(200);
    expect(link.json.data).toMatchObject({ account_id: vcb, attached: true });
    const again = await call("POST", "/v1/banks/sepay/link", { body: { external_id: EXT, account_id: vcb } });
    expect(again.status).toBe(200);
    expect(again.json.data.account_id).toBe(vcb);

    const accounts = (await call("GET", "/v1/accounts")).json.data as any[];
    expect(accounts.filter((a) => a.institution === "Vietcombank").length).toBe(1); // no second account
    expect(accounts.find((a) => a.id === vcb)).toMatchObject({ balance: "5000000", last4: "3456" });
    expect((await h.db.query("select count(*)::int as n from pf_tx where account_id = $1 and kind <> 'OPENING'", [vcb])).rows[0].n).toBe(txBefore);
    const links = (await call("GET", "/v1/banks/links")).json.data as any[];
    expect(links[0]).toMatchObject({ account_id: vcb, number: NUMBER, bank_balance: "5000000", ledger_balance: "5000000" });

    const hook = await call("POST", "/v1/webhooks/sepay", {
      auth: false,
      headers: { authorization: `Apikey ${KEY}` },
      body: { id: 777, gateway: "Vietcombank", transactionDate: vn(1), accountNumber: NUMBER, content: "CAFE", transferType: "out", transferAmount: 45000, accumulated: 4955000, referenceCode: "FT-ATTACH-1" },
    });
    expect(hook.json.success).toBe(true);
    expect((await account(vcb)).balance).toBe("4955000");
    const last = (await h.db.query("select source from pf_tx where account_id = $1 order by created_at desc limit 1", [vcb])).rows[0];
    expect(last.source).toBe("BANK");
  });

  it("a second MoMa account cannot take the same bank account", async () => {
    const other = (await command("ACCOUNT_CREATE", { kind: "BANK", institution: "VCB", name: "VCB 2", opening_amount: "100", baseline_at: "2026-11-01T00:00:00Z" })).json.data.account_id;
    const r = await call("POST", "/v1/banks/sepay/link", { body: { external_id: EXT, account_id: other } });
    expect(r.status).toBe(409);
    expect(r.json.error?.code).toBe("BANK_ALREADY_LINKED");
    expect((await account(other)).balance).toBe("100"); // untouched
  });
});

describe("SePay: attach keeps a known balance", () => {
  beforeEach(() => resetSepayCache());
  it("an account with a known balance keeps it; the bank balance is reported next to it", async () => {
    await h.db.query("delete from pf_account_link");
    bankBalance = 7_000_000;
    const acc = (await command("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "VCB cũ", last4: "3456", opening_amount: "6900000", baseline_at: "2026-11-01T00:00:00Z" })).json.data.account_id;
    const r = await call("POST", "/v1/banks/sepay/link", { body: { external_id: EXT, account_id: acc } });
    expect(r.status).toBe(200);
    expect((await account(acc)).balance).toBe("6900000");
    const l = ((await call("GET", "/v1/banks/links")).json.data as any[]).find((x) => x.account_id === acc);
    expect(l).toMatchObject({ bank_balance: "7000000", ledger_balance: "6900000" });
  });
});
