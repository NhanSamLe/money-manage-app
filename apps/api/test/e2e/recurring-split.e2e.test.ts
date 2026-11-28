import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Recurring rules with bill splitting (migration 016) against the real API code, PostgREST and Postgres:
// rent 1.600.000 paid on day 6 -> category + occurrence + Nam and Lan owe 535.000 each; undo restores everything.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
const env = {} as never;
let vcb = "";
let cash = "";
let nam = "";
let lan = "";
let rent = "";
let other = "";
let ruleId = "";

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(
    path,
    { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` }, body: body === undefined ? null : JSON.stringify(body) },
    env,
  );
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown, expectStatus = 200) {
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
  const json = (await res.json()) as any;
  expect([res.status, json.error?.code]).toEqual([expectStatus, expectStatus === 200 ? undefined : json.error?.code]);
  return expectStatus === 200 ? json.data : json.error;
}

// Previous month in Vietnam: its day `d` at 10:00 local.
const prev = (() => {
  const vn = new Date(Date.now() + 7 * 3_600_000);
  const y = vn.getUTCMonth() === 0 ? vn.getUTCFullYear() - 1 : vn.getUTCFullYear();
  const m = vn.getUTCMonth() === 0 ? 12 : vn.getUTCMonth();
  return { y, m, ym: `${y}-${String(m).padStart(2, "0")}` };
})();
const at = (day: number) => new Date(Date.UTC(prev.y, prev.m - 1, day, 3, 0, 0)).toISOString();

async function ledgerSum() {
  return (await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry")).rows[0].s;
}
async function balance(id: string) {
  return Number(((await call("GET", "/v1/accounts")).json.data as any[]).find((a) => a.id === id).balance);
}
async function expenseOfPrevMonth() {
  return Number((await call("GET", `/v1/reports/summary?month=${prev.ym}`)).json.data.expense);
}
async function openDebts() {
  return ((await call("GET", "/v1/debts")).json.data as any[]).map((d) => ({ name: d.contact_alias, remaining: Number(d.remaining), direction: d.direction }));
}
async function debit(account: string, amount: number, day: number, note: string) {
  return (await cmd("TX_CREATE", { kind: "UNKNOWN_DEBIT", account_id: account, amount: String(amount), effective_at: at(day), note, source: "NOTIFICATION" })).tx_id as string;
}
async function splitsOf(tx: string) {
  return (await call("GET", `/v1/splits?tx_id=${tx}`)).json.data as any[];
}

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
  const baseline = new Date(Date.UTC(prev.y, prev.m - 2, 1)).toISOString();
  vcb = (await cmd("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "VCB", opening_amount: "10000000", baseline_at: baseline })).account_id;
  cash = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Tiền mặt", opening_amount: "5000000", baseline_at: baseline })).account_id;
  nam = (await cmd("CONTACT_CREATE", { alias: "Nam" })).contact_id;
  lan = (await cmd("CONTACT_CREATE", { alias: "Lan" })).contact_id;
  const cats = ((await call("GET", "/v1/categories")).json.data as any[]).filter((c) => c.type === "EXPENSE");
  rent = (cats.find((c) => /nhà/i.test(c.name)) ?? cats[0]).id;
  other = cats.find((c) => c.id !== rent).id;
  ruleId = (
    await cmd("RECURRING_SPLIT_UPSERT", {
      name: "Tiền nhà",
      account_id: vcb,
      amount: "1600000",
      category_id: rent,
      next_date: `${prev.ym}-05`,
      enabled: true,
      window_start: 5,
      window_end: 10,
      rounding: 5000,
      payee_keywords: ["CO HOA"],
      participants: [
        { contact_id: nam, mode: "EQUAL" },
        { contact_id: lan, mode: "EQUAL" },
      ],
    })
  ).recurring_id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("recurring rule with a split", () => {
  it("the rule is listed with its split settings", async () => {
    const r = ((await call("GET", "/v1/recurring")).json.data as any[]).find((x) => x.id === ruleId);
    expect(r.split).toMatchObject({ window_start: 5, window_end: 10, rounding: 5000, owner_share: true, auto_apply: true });
    expect(r.split.participants.map((p: any) => p.name)).toEqual(["Nam", "Lan"]);
    expect(r.expected.length).toBeGreaterThan(0);
  });

  it("outside the window or a different amount: no match", async () => {
    const late = await debit(vcb, 1_600_000, 25, "CK TIEN NHA");
    const wrong = await debit(vcb, 2_000_000, 7, "CK TIEN NHA");
    expect(await splitsOf(late)).toEqual([]);
    expect(await splitsOf(wrong)).toEqual([]);
    // Clean up so the month's numbers below only contain the rent.
    for (const id of [late, wrong]) {
      const t = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === id);
      await cmd("TX_REVERSE", { tx_id: id, reason: "test", expected_version: t.version });
    }
  });

  let txId = "";
  let appId = "";
  it("rent paid on day 6: category, occurrence and two debts of 535.000 at once", async () => {
    const before = await balance(vcb);
    txId = await debit(vcb, 1_600_000, 6, "CHUYEN TIEN NHA THANG");
    const [s] = await splitsOf(txId);
    expect(s).toMatchObject({ state: "APPLIED", source: "RECURRING", recurring_id: ruleId, owner_amount: "530000", can_undo: true });
    appId = s.id;
    expect(s.shares.map((x: any) => [x.name, x.amount])).toEqual([
      ["Nam", "535000"],
      ["Lan", "535000"],
    ]);
    const t = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === txId);
    expect([t.kind, t.category_id, t.merchant]).toEqual(["EXPENSE", rent, "Tiền nhà"]);
    expect(await openDebts()).toEqual(
      expect.arrayContaining([
        { name: "Nam", remaining: 535000, direction: "RECEIVABLE" },
        { name: "Lan", remaining: 535000, direction: "RECEIVABLE" },
      ]),
    );
    // Cash left once (1.600.000); the owner's expense is only their part.
    expect(await balance(vcb)).toBe(before - 1_600_000);
    expect(await expenseOfPrevMonth()).toBe(530_000);
    expect(await ledgerSum()).toBe("0");
    const occ = (await h.db.query("select state from pf_occurrence where matched_tx_id = $1", [txId])).rows;
    expect(occ).toEqual([{ state: "MATCHED" }]);
    // The inbox got the summary.
    const inbox = (await call("GET", "/v1/notifications")).json.data.items as any[];
    expect(inbox.some((n) => n.title === "Đã ghi Tiền nhà 1.600.000đ" && n.body.startsWith("Nam nợ 535.000đ, Lan nợ 535.000đ"))).toBe(true);
  });

  it("a split bill cannot be cancelled or re-categorized underneath its debts", async () => {
    const t = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === txId);
    expect((await cmd("TX_REVERSE", { tx_id: txId, reason: "x", expected_version: t.version }, 422)).code).toBe("SPLIT_LINKED");
    expect((await cmd("TX_ANNOTATE", { tx_id: txId, expected_version: t.version, category_id: other }, 422)).code).toBe("SPLIT_LINKED");
    expect((await call("POST", "/v1/splits/apply", { tx_id: txId, shares: [{ name: "Hùng", amount: "1000" }] })).json.error?.code).toBe("SPLIT_EXISTS");
  });

  it("undo: debts cancelled, expense back to 1.600.000, occurrence expected again, ledger balanced", async () => {
    const before = await balance(vcb);
    const r = await call("POST", `/v1/splits/${appId}/undo`);
    expect(r.json.data).toMatchObject({ state: "UNDONE", debts_cancelled: 2 });
    expect((await openDebts()).filter((d) => ["Nam", "Lan"].includes(d.name))).toEqual([]);
    expect(await expenseOfPrevMonth()).toBe(1_600_000);
    expect(await balance(vcb)).toBe(before);
    expect(await ledgerSum()).toBe("0");
    expect((await h.db.query("select state from pf_occurrence where recurring_id = $1 and due_date = $2", [ruleId, `${prev.ym}-05`])).rows).toEqual([{ state: "EXPECTED" }]);
    expect((await call("POST", `/v1/splits/${appId}/undo`)).status).toBe(422);
  });

  it("weaker match (other account, a bit more): proposal, confirmed with one tap", async () => {
    // The undone rent still holds nothing now; cancel it so this payment is the month's candidate.
    const t = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === txId);
    await cmd("TX_REVERSE", { tx_id: txId, reason: "test", expected_version: t.version });
    const tx2 = await debit(cash, 1_650_000, 8, "tra tien");
    const [p] = await splitsOf(tx2);
    expect(p).toMatchObject({ state: "PROPOSED", recurring_id: ruleId, owner_amount: "550000" });
    expect(p.shares.map((x: any) => x.amount)).toEqual(["550000", "550000"]);
    const ok = await call("POST", "/v1/splits/apply", { tx_id: tx2, application_id: p.id });
    expect(ok.status).toBe(200);
    const [s] = await splitsOf(tx2);
    expect(s).toMatchObject({ id: p.id, state: "APPLIED" });
    expect(await expenseOfPrevMonth()).toBe(550_000);
    expect(await ledgerSum()).toBe("0");
  });

  it("manual split of any expense (names create contacts), and dismiss of a proposal", async () => {
    const t = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: cash, amount: "1240000", category_id: other, effective_at: at(20), note: "Lẩu" })).tx_id;
    const prop = await call("POST", "/v1/splits/propose", { tx_id: t, participants: [{ name: "nam" }, { name: "Hùng" }] });
    expect(prop.json.data.shares.map((s: any) => [s.name, s.amount])).toEqual([
      ["Nam", 415000],
      ["Hùng", 415000],
    ]);
    expect(prop.json.data.unresolved).toEqual(["Hùng"]);
    expect((await call("POST", `/v1/splits/${prop.json.data.application_id}/dismiss`)).json.data.state).toBe("DISMISSED");
    const applied = await call("POST", "/v1/splits/apply", { tx_id: t, participants: [{ name: "nam" }, { name: "Hùng" }], rounding: 5000 });
    expect(applied.status).toBe(200);
    const hung = ((await call("GET", "/v1/contacts")).json.data as any[]).filter((c) => c.alias === "Hùng");
    expect(hung).toHaveLength(1);
    expect(await ledgerSum()).toBe("0");
  });

  it("bill photo analysis (AI off): total mismatch reported, money untouched", async () => {
    const t = await debit(vcb, 845_000, 21, "TT HOA DON");
    const r = await call("POST", "/v1/bills/analyze", { tx_id: t, text: "EVN HCMC tien dien thang 11. Tong cong thanh toan: 900.000 d" });
    expect(r.status).toBe(200);
    expect(r.json.data.amount_mismatch).toEqual({ bill_total: "900000", tx_amount: "845000" });
    const tx = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === t);
    expect(tx.amount).toBe("845000");
    expect(await ledgerSum()).toBe("0");
  });

  it("rule suggestions and the cron's missed-window list answer", async () => {
    expect(Array.isArray((await call("GET", "/v1/splits/rule-suggestions")).json.data)).toBe(true);
    const missed = (await h.db.query("select public.pf_split_missed($1, current_date) as m", [owner])).rows[0].m;
    expect(Array.isArray(missed)).toBe(true);
  });
});
