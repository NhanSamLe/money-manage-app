import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Debt fixes (migration 014) against the real API code, PostgREST and Postgres: edit, undo one repayment, cancel.
// After every step the cash balance, the remaining principal and the ledger must look as if the mistake never happened.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
let cash = "";
let nam = "";
let lan = "";
const env = {} as never;

async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const all: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, ...headers };
  const res = await app.request(path, { method, headers: all, body: body === undefined ? null : JSON.stringify(body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function send(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  return call("POST", "/v1/commands", { command_id: id, command_type: type, schema_version: 1, payload }, { "idempotency-key": id });
}
async function cmd(type: string, payload: unknown) {
  const r = await send(type, payload);
  expect(r.status, `${type} ${JSON.stringify(r.json.error)}`).toBe(200);
  return r.json.data;
}
async function debts(): Promise<any[]> {
  return (await call("GET", "/v1/debts")).json.data;
}
async function debt(id: string) {
  return (await debts()).find((d) => d.id === id);
}
async function cashBalance() {
  const accounts = (await call("GET", "/v1/accounts")).json.data as any[];
  return Number(accounts.find((a) => a.id === cash).balance);
}
async function txs(): Promise<any[]> {
  return (await call("GET", "/v1/transactions?limit=100")).json.data;
}
async function ledgerBalanced() {
  const all = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(all.rows[0].s).toBe("0");
}
async function debtLedgerTotal(id: string) {
  const r = await h.db.query(
    "select coalesce(sum(e.signed_amount::numeric), 0)::text as s from pf_entry e join pf_journal j on j.id = e.journal_id and j.posted join pf_debt d on d.ledger_account_id = e.ledger_account_id where d.id = $1",
    [id],
  );
  return r.rows[0].s as string;
}
const at = (hoursAgo: number) => new Date(Date.now() - hoursAgo * 3_600_000).toISOString();

beforeAll(async () => {
  h = await startHarness();
  const cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  cash = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Tiền mặt", opening_amount: "1000000", baseline_at: at(72) })).account_id;
  nam = (await cmd("CONTACT_CREATE", { alias: "Nam" })).contact_id;
  lan = (await cmd("CONTACT_CREATE", { alias: "Lan" })).contact_id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("debt fixes", () => {
  let lent = "";

  it("undoing a repayment restores the principal, the cash and the state", async () => {
    lent = (await cmd("DEBT_CREATE", { direction: "RECEIVABLE", contact_id: nam, principal: "300000", originated_at: at(48), account_id: cash })).debt_id;
    expect(await cashBalance()).toBe(700_000);
    await cmd("DEBT_REPAY", { debt_id: lent, account_id: cash, principal: "100000", effective_at: at(24), expected_version: 1 });
    let d = await debt(lent);
    expect(d).toMatchObject({ remaining: "200000", state: "PARTIAL" });
    expect(await cashBalance()).toBe(800_000);
    expect(d.payments).toHaveLength(1);
    const pay = d.payments[0];
    expect(pay).toMatchObject({ kind: "REPAYMENT", principal: "100000", reversed: false, account_id: cash });

    await cmd("DEBT_PAYMENT_REVERSE", { debt_id: lent, payment_id: pay.id, expected_version: d.version });
    d = await debt(lent);
    expect(d).toMatchObject({ remaining: "300000", state: "OPEN" });
    expect(d.payments[0].reversed).toBe(true);
    expect(await cashBalance()).toBe(700_000);
    expect((await txs()).find((t) => t.id === pay.tx_id)).toMatchObject({ status: "VOID", debt_id: lent });
    await ledgerBalanced();

    // Already undone: not found, nothing moves.
    const again = await send("DEBT_PAYMENT_REVERSE", { debt_id: lent, payment_id: pay.id, expected_version: d.version });
    expect(again.status).toBe(404);
    expect(await cashBalance()).toBe(700_000);
  });

  it("edits person, due date and note; the amount only while nothing was repaid", async () => {
    let d = await debt(lent);
    await cmd("DEBT_UPDATE", { debt_id: lent, expected_version: d.version, contact_id: lan, due_date: "2026-12-31", note: "Mượn mua laptop" });
    d = await debt(lent);
    expect(d).toMatchObject({ contact_id: lan, contact_alias: "Lan", due_date: "2026-12-31", note: "Mượn mua laptop", remaining: "300000" });
    const origin = (await txs()).find((t) => t.id === d.origin_tx_id);
    expect(origin).toMatchObject({ contact_id: lan, note: "Mượn mua laptop", debt_id: lent });

    // Clearing the due date.
    await cmd("DEBT_UPDATE", { debt_id: lent, expected_version: d.version, due_date: null });
    d = await debt(lent);
    expect(d.due_date).toBeNull();

    // New amount: the origin journal is reversed and replaced, cash follows.
    await cmd("DEBT_UPDATE", { debt_id: lent, expected_version: d.version, principal: "250000" });
    d = await debt(lent);
    expect(d).toMatchObject({ principal: "250000", remaining: "250000", state: "OPEN" });
    expect(await cashBalance()).toBe(750_000);
    expect((await txs()).find((t) => t.id === d.origin_tx_id)).toMatchObject({ amount: "250000", status: "POSTED" });
    expect(await debtLedgerTotal(lent)).toBe("250000");

    // With a repayment in effect the amount is locked (clear Vietnamese error), other fields still editable.
    await cmd("DEBT_REPAY", { debt_id: lent, account_id: cash, principal: "50000", effective_at: at(2), expected_version: d.version });
    d = await debt(lent);
    const locked = await send("DEBT_UPDATE", { debt_id: lent, expected_version: d.version, principal: "400000" });
    expect(locked.status).toBe(422);
    expect(locked.json.error?.code).toBe("DEBT_HAS_PAYMENTS");
    expect(await cashBalance()).toBe(800_000);
    const stale = await send("DEBT_UPDATE", { debt_id: lent, expected_version: d.version - 1, note: "x" });
    expect(stale.status).toBe(409);
    await ledgerBalanced();
  });

  it("cancelling a debt reverses every payment and the origin: as if it never happened", async () => {
    let d = await debt(lent);
    // A partial write-off too, so cancel has a repayment and a write-off to undo.
    await cmd("DEBT_WRITE_OFF", { debt_id: lent, amount: "20000", reason: "Bớt cho bạn", effective_at: at(1), expected_version: d.version });
    d = await debt(lent);
    expect(d).toMatchObject({ remaining: "180000", state: "PARTIAL" });
    const before = (await call("GET", "/v1/reports/summary")).json.data;

    const res = await cmd("DEBT_CANCEL", { debt_id: lent, expected_version: d.version, reason: "Nhập nhầm" });
    expect(res).toMatchObject({ state: "CANCELLED", payments_reversed: 2 });
    expect(await debt(lent)).toBeUndefined();
    expect(await cashBalance()).toBe(1_000_000);
    expect(await debtLedgerTotal(lent)).toBe("0");
    const list = await txs();
    for (const t of list.filter((x) => x.debt_id === lent)) expect(t.status, t.kind).toBe("VOID");
    // The bad-debt expense of the write-off is gone from the month too.
    const after = (await call("GET", "/v1/reports/summary")).json.data;
    expect(Number(after.expense)).toBe(Number(before.expense) - 20_000);
    expect((await send("DEBT_CANCEL", { debt_id: lent, expected_version: d.version + 1 })).status).toBe(422);
    await ledgerBalanced();
  });

  it("cancelling a borrowed debt with interest paid restores cash and expenses", async () => {
    const before = await cashBalance();
    const summaryBefore = (await call("GET", "/v1/reports/summary")).json.data;
    const borrowed = (await cmd("DEBT_CREATE", { direction: "PAYABLE", contact_id: nam, principal: "400000", originated_at: at(30), account_id: cash })).debt_id;
    await cmd("DEBT_REPAY", { debt_id: borrowed, account_id: cash, principal: "100000", interest: "10000", effective_at: at(3), expected_version: 1 });
    expect(await cashBalance()).toBe(before + 400_000 - 110_000);
    const d = await debt(borrowed);
    expect(d).toMatchObject({ direction: "PAYABLE", remaining: "300000" });
    await cmd("DEBT_CANCEL", { debt_id: borrowed, expected_version: d.version });
    expect(await cashBalance()).toBe(before);
    const summaryAfter = (await call("GET", "/v1/reports/summary")).json.data;
    expect(summaryAfter.expense).toBe(summaryBefore.expense);
    expect(await debts()).toEqual([]);
    await ledgerBalanced();
  });

  it("a settled debt can have its last repayment undone (back to PARTIAL/OPEN)", async () => {
    const id = (await cmd("DEBT_CREATE", { direction: "RECEIVABLE", contact_id: lan, principal: "60000", originated_at: at(10), account_id: cash })).debt_id;
    await cmd("DEBT_REPAY", { debt_id: id, account_id: cash, principal: "60000", effective_at: at(1), expected_version: 1 });
    let d = await debt(id);
    expect(d.state).toBe("SETTLED");
    await cmd("DEBT_PAYMENT_REVERSE", { debt_id: id, payment_id: d.payments[0].id, expected_version: d.version });
    d = await debt(id);
    expect(d).toMatchObject({ state: "OPEN", remaining: "60000" });
    await ledgerBalanced();
  });
});
