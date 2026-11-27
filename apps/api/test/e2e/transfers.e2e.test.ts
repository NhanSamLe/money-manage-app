import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runTransferSweep } from "../../src/entrypoints/routes-transfers";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { hmacHex } from "../../src/modules/bank/sepay";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Own-account transfer pairing (migration 010) against the real API code, PostgREST and Postgres:
// a SePay webhook (bank leg) and a captured notification (wallet leg) become one transfer.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";
const KEY = "webhook-shared-key";
const TOKEN = "sepay-token";
const NUM_TP = "0123451234";
const NUM_VCB = "1017588888";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
const env = {} as never;
const acc: Record<string, string> = {};
const expected: Record<string, number> = {};

async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const all: Record<string, string> = { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, ...headers };
  const res = await app.request(path, { method, headers: all, body: body === undefined ? null : JSON.stringify(body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string }; success?: boolean } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const r = await call("POST", "/v1/commands", { command_id: id, command_type: type, schema_version: 1, payload }, { "idempotency-key": id });
  expect(r.status).toBe(200);
  return r.json.data;
}
// SePay sends Vietnam local time.
const vn = (d: Date) => new Date(d.getTime() + 7 * 3_600_000).toISOString().slice(0, 19).replace("T", " ");
let refN = 0;
async function hook(number: string, type: "in" | "out", amount: number, at: Date, content: string, reference?: string) {
  refN++;
  const r = await call(
    "POST",
    "/v1/webhooks/sepay",
    { id: 50000 + refN, gateway: "Bank", transactionDate: vn(at), accountNumber: number, content, transferType: type, transferAmount: amount, accumulated: 0, referenceCode: reference ?? `FT-PAIR-${refN}` },
    { authorization: `Apikey ${KEY}` },
  );
  expect(r.json.success).toBe(true);
}
async function notification(account: string, kind: "UNKNOWN_CREDIT" | "UNKNOWN_DEBIT", amount: number, at: Date, note?: string) {
  return (await cmd("TX_CREATE", { kind, account_id: account, amount: String(amount), effective_at: at.toISOString(), source: "NOTIFICATION", ...(note ? { note } : {}) })).tx_id as string;
}
async function txs(): Promise<any[]> {
  return (await call("GET", "/v1/transactions?limit=100")).json.data;
}
async function expectBalances() {
  const accounts = (await call("GET", "/v1/accounts")).json.data as any[];
  for (const [name, id] of Object.entries(acc)) expect([name, Number(accounts.find((a) => a.id === id).balance)]).toEqual([name, expected[name]]);
  const ledger = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(ledger.rows[0].s).toBe("0");
}
async function summary() {
  const s = (await call("GET", "/v1/reports/summary")).json.data;
  return { income: s.income, expense: s.expense };
}
const at = (minutes: number) => new Date(Math.floor(Date.now() / 60_000) * 60_000 - 3 * 3_600_000 + minutes * 60_000);

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000, sepayToken: TOKEN, sepayWebhookKey: KEY } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Lê Đào Nhân Sâm" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  const baseline = new Date(Date.now() - 2 * 86_400_000).toISOString();
  for (const [name, kind, institution, opening, last4] of [
    ["TPBank", "BANK", "TPBank", 10_000_000, "1234"],
    ["MoMo", "WALLET", "MoMo", 200_000, undefined],
    ["VCB", "BANK", "Vietcombank", 5_000_000, "8888"],
  ] as const) {
    acc[name] = (await cmd("ACCOUNT_CREATE", { kind, institution, name, opening_amount: String(opening), baseline_at: baseline, ...(last4 ? { last4 } : {}) })).account_id;
    expected[name] = opening;
  }
  // SePay links written directly (the link flow itself is covered by flow.e2e): number hash keyed by the SePay token.
  for (const [name, num, bank] of [["TPBank", NUM_TP, "TPBank"], ["VCB", NUM_VCB, "Vietcombank"]] as const) {
    await h.db.query("select pf_link_account($1, $2, 'SEPAY', $3, $4, $5, 'LE DAO NHAN SAM', $6, 0)", [owner, acc[name], `ext-${name}`, await hmacHex(TOKEN, num), num.slice(-4), bank]);
  }
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("own-account transfers", () => {
  let pairId = "";
  let transferId = "";

  it("a SePay money-out and a notification money-in become one transfer", async () => {
    const before = await summary();
    await hook(NUM_TP, "out", 500_000, at(0), "NAP TIEN VI MOMO 0909");
    expect((await txs()).filter((t) => t.status === "POSTED" && t.kind === "EXPENSE")).toHaveLength(1); // nothing to pair yet
    const inTx = await notification(acc.MoMo!, "UNKNOWN_CREDIT", 500_000, new Date(at(0).getTime() + 40_000), "Nhận tiền từ TPBank");
    const list = await txs();
    expect(list.find((t) => t.id === inTx).status).toBe("VOID");
    const transfers = list.filter((t) => t.kind === "TRANSFER" && t.status === "POSTED");
    expect(transfers).toHaveLength(1);
    const tr = transfers[0];
    expect(tr).toMatchObject({ account_id: acc.TPBank, to_account_id: acc.MoMo, amount: "500000", source: "BANK", note: "NAP TIEN VI MOMO 0909 / Nhận tiền từ TPBank" });
    expect(Date.parse(tr.effective_at)).toBe(at(0).getTime());
    expect(list.filter((t) => t.kind !== "OPENING" && t.status === "POSTED")).toHaveLength(1); // only the transfer counts
    expected.TPBank! -= 500_000;
    expected.MoMo! += 500_000;
    await expectBalances();
    expect(await summary()).toEqual(before); // no income, no expense
    const pair = (await call("GET", `/v1/transfers/by-tx/${tr.id}`)).json.data;
    expect(pair).toMatchObject({ state: "AUTO", can_undo: true, out: { account_name: "TPBank" }, in: { account_name: "MoMo" } });
    expect(pair.hints).toEqual(expect.arrayContaining(["keyword", "account"]));
    pairId = pair.id;
    transferId = tr.id;
    expect((await call("GET", "/v1/transfers/suggestions")).json.data).toEqual([]);
  });

  it("undo restores the two original transactions and they are not paired again", async () => {
    const r = await call("POST", `/v1/transfers/${pairId}/undo`);
    expect(r.status).toBe(200);
    expect(r.json.data).toMatchObject({ state: "REJECTED", voided_transfer_tx_id: transferId });
    const list = await txs();
    expect(list.find((t) => t.id === transferId).status).toBe("VOID");
    expect(list.find((t) => t.id === r.json.data.out_tx_id)).toMatchObject({ kind: "EXPENSE", status: "POSTED", source: "BANK", account_id: acc.TPBank, amount: "500000" });
    expect(list.find((t) => t.id === r.json.data.in_tx_id)).toMatchObject({ kind: "UNKNOWN_CREDIT", status: "POSTED", source: "NOTIFICATION", account_id: acc.MoMo });
    await expectBalances(); // balances do not move: same money, now booked as out + in
    expect((await call("POST", `/v1/transfers/${pairId}/undo`)).status).toBe(422);
    expect((await call("GET", `/v1/transfers/by-tx/${transferId}`)).json.data).toMatchObject({ state: "REJECTED", can_undo: false });
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 0, suggested: 0, failed: 0 });
    expect((await call("GET", "/v1/transfers/suggestions")).json.data).toEqual([]);
  });

  it("two possible counterparts -> suggestions only; accepting one books the transfer", async () => {
    const momoIn = await notification(acc.MoMo!, "UNKNOWN_CREDIT", 300_000, at(30));
    await hook(NUM_VCB, "in", 300_000, new Date(at(30).getTime() + 20_000), "CK DEN");
    await hook(NUM_TP, "out", 300_000, new Date(at(30).getTime() + 10_000), "CK DI");
    expected.MoMo! += 300_000;
    expected.VCB! += 300_000;
    expected.TPBank! -= 300_000;
    await expectBalances();
    const s = (await call("GET", "/v1/transfers/suggestions")).json.data as any[];
    expect(s).toHaveLength(2);
    expect(s.map((x) => x.in.account_name).sort()).toEqual(["MoMo", "VCB"]);
    expect(s[0]).toMatchObject({ state: "SUGGESTED", out: { account_name: "TPBank", amount: "300000", source: "BANK" } });
    expect((await txs()).filter((t) => t.kind === "TRANSFER" && t.status === "POSTED")).toHaveLength(0); // ledger untouched
    const vcb = s.find((x) => x.in.account_name === "VCB");
    const ok = await call("POST", `/v1/transfers/suggestions/${vcb.id}`, { accept: true });
    expect(ok.json.data.state).toBe("CONFIRMED");
    const tr = (await txs()).find((t) => t.id === ok.json.data.transfer_tx_id);
    expect(tr).toMatchObject({ kind: "TRANSFER", status: "POSTED", account_id: acc.TPBank, to_account_id: acc.VCB, amount: "300000" });
    await expectBalances(); // same money, now one transfer TPBank -> VCB: balances unchanged by the decision
    expect((await call("GET", "/v1/transfers/suggestions")).json.data).toEqual([]); // the MoMo option is gone (its out leg is booked)
    expect((await txs()).find((t) => t.id === momoIn).status).toBe("POSTED");
    expect((await call("POST", `/v1/transfers/suggestions/${vcb.id}`, { accept: true })).status).toBe(422);
  });

  it("a weak match (8 minutes, no hint) is only suggested; rejecting it keeps both and never asks again", async () => {
    await hook(NUM_TP, "out", 123_000, at(60), "THANH TOAN");
    const inTx = await notification(acc.MoMo!, "UNKNOWN_CREDIT", 123_000, at(68));
    expected.TPBank! -= 123_000;
    expected.MoMo! += 123_000;
    const s = (await call("GET", "/v1/transfers/suggestions")).json.data as any[];
    expect(s).toHaveLength(1);
    expect(s[0]).toMatchObject({ score: 10, hints: [], in: { tx_id: inTx } });
    const no = await call("POST", `/v1/transfers/suggestions/${s[0].id}`, { accept: false });
    expect(no.json.data.state).toBe("REJECTED");
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 0, suggested: 0 });
    expect((await call("GET", "/v1/transfers/suggestions")).json.data).toEqual([]);
    expect((await txs()).find((t) => t.id === inTx).status).toBe("POSTED");
    await expectBalances();
  });

  it("the sweep pairs legs whose hook did not run (bank leg recorded after the notification)", async () => {
    // A notification money-out from MoMo, then the bank money-in arrives through the webhook (bank hook pairs it).
    await notification(acc.MoMo!, "UNKNOWN_DEBIT", 80_000, at(90), "Chuyen tien den VCB");
    await hook(NUM_VCB, "in", 80_000, new Date(at(90).getTime() + 60_000), "LE DAO NHAN SAM CHUYEN TIEN");
    const tr = (await txs()).find((t) => t.kind === "TRANSFER" && t.status === "POSTED" && t.amount === "80000");
    expect(tr).toMatchObject({ account_id: acc.MoMo, to_account_id: acc.VCB, source: "NOTIFICATION" });
    expected.MoMo! -= 80_000;
    expected.VCB! += 80_000;
    await expectBalances();
    // Legs recorded without a hook (manual + a notification inserted while pairing was down) are caught by the sweep.
    await h.db.query("select pf_execute_command($1::uuid, $2::uuid, $3::uuid, $4::uuid, md5($4::text), jsonb_build_object('command_id', $4::text, 'command_type', 'TX_CREATE', 'schema_version', 1, 'payload', $5::jsonb))", [
      owner, SESSION, DEVICE, crypto.randomUUID(),
      JSON.stringify({ kind: "UNKNOWN_CREDIT", account_id: acc.MoMo, amount: "45000", effective_at: at(120).toISOString(), source: "NOTIFICATION", note: "Nhan tien tu Vietcombank" }),
    ]);
    await h.db.query("select pf_execute_command($1::uuid, $2::uuid, $3::uuid, $4::uuid, md5($4::text), jsonb_build_object('command_id', $4::text, 'command_type', 'TX_CREATE', 'schema_version', 1, 'payload', $5::jsonb))", [
      owner, SESSION, DEVICE, crypto.randomUUID(),
      JSON.stringify({ kind: "UNKNOWN_DEBIT", account_id: acc.VCB, amount: "45000", effective_at: new Date(at(120).getTime() + 90_000).toISOString() }),
    ]);
    expect((await txs()).filter((t) => t.status === "POSTED" && t.amount === "45000")).toHaveLength(2);
    expected.MoMo! += 45_000;
    expected.VCB! -= 45_000;
    await expectBalances();
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 1, failed: 0 });
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 0, suggested: 0 }); // idempotent
    const swept = (await txs()).filter((t) => t.status === "POSTED" && t.amount === "45000");
    expect(swept).toHaveLength(1);
    expect(swept[0]).toMatchObject({ kind: "TRANSFER", account_id: acc.VCB, to_account_id: acc.MoMo });
    await expectBalances();
  });

  it("the same bank reference on both legs pairs them even 3 hours apart (real MoMo text)", async () => {
    await hook(NUM_TP, "out", 2_500_000, at(-60), "THANH TOAN HD", "FT26332327719412");
    expected.TPBank! -= 2_500_000;
    const inTx = await notification(acc.MoMo!, "UNKNOWN_CREDIT", 2_500_000, at(120), "LE DAO NHAN SAM chuyen FT26332327719412");
    expected.MoMo! += 2_500_000;
    const list = await txs();
    expect(list.find((t) => t.id === inTx).status).toBe("VOID");
    const tr = list.find((t) => t.kind === "TRANSFER" && t.status === "POSTED" && t.amount === "2500000");
    expect(tr).toMatchObject({ account_id: acc.TPBank, to_account_id: acc.MoMo, source: "BANK" });
    expect(Date.parse(tr.effective_at)).toBe(at(-60).getTime());
    const pair = (await call("GET", `/v1/transfers/by-tx/${tr.id}`)).json.data;
    expect(pair).toMatchObject({ state: "AUTO", score: 100 });
    expect(pair.hints).toContain("reference");
    await expectBalances();
  });

  it("money into VCB from the owner's MoMo (MoMo never notifies money out) becomes a transfer after the window; undo works", async () => {
    const text = "+4,000 VND ... Ref 159036437923-LE DAO NHAN SAM chuyen tien qua MoMo-CHUYEN TIEN-...";
    const inTx = await notification(acc.VCB!, "UNKNOWN_CREDIT", 4_000, at(150), text);
    expected.VCB! += 4_000;
    expect((await txs()).find((t) => t.id === inTx).status).toBe("POSTED"); // no out-leg yet: the hook leaves it
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 1, failed: 0 });
    expected.MoMo! -= 4_000; // the MoMo side is synthesized
    const list = await txs();
    expect(list.find((t) => t.id === inTx).status).toBe("VOID");
    const tr = list.find((t) => t.kind === "TRANSFER" && t.status === "POSTED" && t.amount === "4000");
    expect(tr).toMatchObject({ account_id: acc.MoMo, to_account_id: acc.VCB, source: "NOTIFICATION", note: text });
    await expectBalances();
    const pair = (await call("GET", `/v1/transfers/by-tx/${tr.id}`)).json.data;
    expect(pair).toMatchObject({ state: "AUTO", out: null, in: { tx_id: inTx }, synth_account: { account_name: "MoMo" }, can_undo: true });
    const undo = await call("POST", `/v1/transfers/${pair.id}/undo`);
    expect(undo.json.data).toMatchObject({ state: "REJECTED", out_tx_id: null });
    expected.MoMo! += 4_000;
    expect((await txs()).find((t) => t.id === undo.json.data.in_tx_id)).toMatchObject({ kind: "UNKNOWN_CREDIT", status: "POSTED", note: text });
    await expectBalances();
    expect(await runTransferSweep({ cfg }, owner)).toMatchObject({ auto: 0, failed: 0 }); // stays an income after undo
  });
});
