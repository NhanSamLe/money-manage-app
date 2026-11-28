import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { hmacHex } from "../../src/modules/bank/sepay";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// One payment seen twice (migration 018) against the real API code, PostgREST and Postgres: a VCB debit (SePay
// webhook) + the MoMo "thanh toán thành công" notification for the same purchase become ONE expense.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";
const KEY = "webhook-shared-key";
const TOKEN = "sepay-token";
const NUM_VCB = "1017588888";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
let food = "";
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
const vn = (d: Date) => new Date(d.getTime() + 7 * 3_600_000).toISOString().slice(0, 19).replace("T", " ");
let refN = 0;
async function vcbOut(amount: number, at: Date, content: string) {
  refN++;
  const r = await call(
    "POST",
    "/v1/webhooks/sepay",
    { id: 70000 + refN, gateway: "Vietcombank", transactionDate: vn(at), accountNumber: NUM_VCB, content, transferType: "out", transferAmount: amount, accumulated: 0, referenceCode: `FT2633${String(refN).padStart(8, "0")}` },
    { authorization: `Apikey ${KEY}` },
  );
  expect(r.json.success).toBe(true);
}
async function notify(account: string, kind: string, amount: number, at: Date, extra: Record<string, unknown> = {}) {
  return (await cmd("TX_CREATE", { kind, account_id: account, amount: String(amount), effective_at: at.toISOString(), source: "NOTIFICATION", ...extra })).tx_id as string;
}
async function txs(): Promise<any[]> {
  return (await call("GET", "/v1/transactions?limit=100")).json.data;
}
async function expectBalances() {
  const accounts = (await call("GET", "/v1/accounts")).json.data as any[];
  if (process.env.SP_DEBUG) console.log(JSON.stringify((await txs()).map((t) => [t.kind, t.status, t.amount, t.account_id === acc.VCB ? "VCB" : t.account_id === acc.MoMo ? "MoMo" : t.account_id, t.to_account_id === acc.MoMo ? "->MoMo" : "", (t.note ?? "").slice(0, 30)])));
  for (const [name, id] of Object.entries(acc)) expect([name, Number(accounts.find((a) => a.id === id).balance)]).toEqual([name, expected[name]]);
  const ledger = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(ledger.rows[0].s).toBe("0");
}
let base = Math.floor(Date.now() / 60_000) * 60_000 - 6 * 3_600_000;
const slot = () => {
  base += 30 * 60_000; // each scenario in its own half hour so they never see each other
  return (m: number) => new Date(base + m * 60_000);
};

beforeAll(async () => {
  h = await startHarness();
  const cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000, sepayToken: TOKEN, sepayWebhookKey: KEY } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Lê Đào Nhân Sâm" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  const baseline = new Date(Date.now() - 2 * 86_400_000).toISOString();
  for (const [name, kind, institution, opening, last4] of [
    ["VCB", "BANK", "Vietcombank", 5_000_000, "8888"],
    ["MoMo", "WALLET", "MoMo", 300_000, undefined],
  ] as const) {
    acc[name] = (await cmd("ACCOUNT_CREATE", { kind, institution, name, opening_amount: String(opening), baseline_at: baseline, ...(last4 ? { last4 } : {}) })).account_id;
    expected[name] = opening;
  }
  await h.db.query("select pf_link_account($1, $2, 'SEPAY', $3, $4, $5, 'LE DAO NHAN SAM', $6, 0)", [owner, acc.VCB, "ext-VCB", await hmacHex(TOKEN, NUM_VCB), NUM_VCB.slice(-4), "Vietcombank"]);
  food = ((await call("GET", "/v1/categories")).json.data as any[]).find((c) => c.type === "EXPENSE" && c.name === "Ăn uống").id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("one payment seen twice", () => {
  let mergedId = "";
  let momoTx = "";
  let keepBefore: any = {};

  it("MoMo paid with VCB: the bank debit and the MoMo notification become ONE expense on VCB", async () => {
    const at = slot();
    await vcbOut(45_000, at(0), "MBVCB.1234567.MOMO.1234567890.THANH TOAN");
    momoTx = await notify(acc.MoMo!, "EXPENSE", 45_000, at(1), { category_id: food, merchant: "Highlands Coffee", note: "Thanh toán thành công cho Highlands Coffee" });
    const list = await txs();
    expect(list.find((t) => t.id === momoTx).status).toBe("VOID");
    const kept = list.filter((t) => t.status === "POSTED" && t.account_id === acc.VCB && t.amount === "45000");
    expect(kept).toHaveLength(1);
    expect(kept[0]).toMatchObject({ kind: "EXPENSE", category_id: food, merchant: "Highlands Coffee" });
    expect(kept[0].note).toContain("Highlands Coffee");
    expected.VCB! -= 45_000; // the wallet balance is unchanged: it never paid
    await expectBalances();
    const same = (await call("GET", `/v1/transactions/${kept[0].id}/duplicate`)).json.data;
    expect(same).toMatchObject({ state: "AUTO", can_undo: true });
    expect(same.hints).toEqual(expect.arrayContaining(["wallet", "intermediary"]));
    expect(same.dup.tx_id).toBe(momoTx);
    mergedId = same.id;
    keepBefore = (await h.db.query("select keep_before from pf_same_payment where id = $1", [mergedId])).rows[0].keep_before;
    // the kept side carries the classification over (migration 015)
    const cls = await h.db.query("select status from pf_tx_classification where tx_id = $1", [kept[0].id]);
    expect(cls.rows[0]?.status).toBe("APPLIED");
  });

  it("undo splits the merge back and the same two are never merged again", async () => {
    const r = await call("POST", `/v1/duplicates/${mergedId}/undo`);
    expect(r.status).toBe(200);
    const list = await txs();
    const keep = list.find((t) => t.id === r.json.data.keep_tx_id);
    // back to exactly what it was before the merge (unclassified or the classifier's own guess), raw bank merchant
    expect(keep.status).toBe("POSTED");
    expect([keepBefore.kind, keepBefore.category_id ?? null]).toEqual([keep.kind, keep.category_id ?? null]);
    expect(keep.merchant ?? null).toBe(keepBefore.merchant ?? null);
    expect(keep.note).not.toContain("Highlands");
    expect(list.find((t) => t.id === r.json.data.restored_tx_id)).toMatchObject({ status: "POSTED", kind: "EXPENSE", account_id: acc.MoMo });
    expected.MoMo! -= 45_000;
    await expectBalances();
    // the sweep does not re-merge the restored copy
    await h.db.query("select pf_transfer_sweep($1, 48)", [owner]);
    expect((await txs()).find((t) => t.id === r.json.data.restored_tx_id).status).toBe("POSTED");
    expect((await call("GET", "/v1/duplicates/suggestions")).json.data).toEqual([]);
  });

  it("a top-up then a payment is a transfer + an expense, never a merge", async () => {
    const at = slot();
    await vcbOut(200_000, at(0), "NAP TIEN VI MOMO 0909123456");
    const pay = await notify(acc.MoMo!, "EXPENSE", 200_000, at(1), { category_id: food, merchant: "Lẩu Hội An" });
    await notify(acc.MoMo!, "UNKNOWN_CREDIT", 200_000, at(1), { note: "Nạp tiền thành công từ Vietcombank" });
    const list = await txs();
    expect(list.find((t) => t.id === pay).status).toBe("POSTED");
    expect(list.filter((t) => t.kind === "TRANSFER" && t.status === "POSTED" && t.amount === "200000")).toHaveLength(1);
    expected.VCB! -= 200_000;
    await expectBalances(); // MoMo: +200.000 top-up - 200.000 payment
    expect((await call("GET", `/v1/transactions/${pay}/duplicate`)).json.data).toBeNull();
  });

  it("two genuine payments of the same amount with different references are both kept", async () => {
    const at = slot();
    await vcbOut(30_000, at(0), "MBVCB.7654321.THANH TOAN QR GRAB 55667788990");
    const momo = await notify(acc.MoMo!, "EXPENSE", 30_000, at(1), { category_id: food, note: "Thanh toán thành công. Mã giao dịch 99887766554" });
    const list = await txs();
    expect(list.find((t) => t.id === momo).status).toBe("POSTED");
    expect(list.filter((t) => t.status === "POSTED" && t.account_id === acc.VCB && t.amount === "30000")).toHaveLength(1);
    expected.VCB! -= 30_000;
    expected.MoMo! -= 30_000;
    await expectBalances();
  });

  it("a notification re-posted on the same account is merged automatically", async () => {
    const at = slot();
    const note = "Thanh toán thành công 25.000đ cho Phúc Long lúc 08:01";
    const a = await notify(acc.MoMo!, "EXPENSE", 25_000, at(0), { category_id: food, note });
    const b = await notify(acc.MoMo!, "EXPENSE", 25_000, new Date(at(0).getTime() + 40_000), { category_id: food, note: note.replace("08:01", "08:02") });
    const list = await txs();
    const live = [a, b].filter((id) => list.find((t) => t.id === id).status === "POSTED");
    expect(live).toHaveLength(1);
    expected.MoMo! -= 25_000;
    await expectBalances();
  });

  it("a typed entry and a captured one on the same account are only suggested, then merged on accept", async () => {
    const at = slot();
    const typed = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: acc.VCB, amount: "120000", effective_at: at(0).toISOString(), category_id: food, note: "Ăn tối" })).tx_id as string;
    await vcbOut(120_000, at(2), "MBVCB.99887.CT DEN QUAN NHAU");
    const sugg = (await call("GET", "/v1/duplicates/suggestions")).json.data as any[];
    expect(sugg).toHaveLength(1);
    expect(sugg[0].hints).toContain("typed_and_captured");
    expect(sugg[0].keep.source).toBe("BANK");
    expected.VCB! -= 240_000; // both still counted until the owner decides
    await expectBalances();
    const d = await call("POST", `/v1/duplicates/${sugg[0].id}/decide`, { accept: true });
    expect(d.json.data.state).toBe("CONFIRMED");
    const list = await txs();
    expect(list.find((t) => t.id === typed).status).toBe("VOID");
    const kept = list.find((t) => t.id === sugg[0].keep.tx_id);
    expect(kept).toMatchObject({ status: "POSTED", kind: "EXPENSE", category_id: food });
    expect(kept.note).toContain("Ăn tối");
    expected.VCB! += 120_000;
    await expectBalances();
  });
});
