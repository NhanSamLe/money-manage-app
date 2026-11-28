import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { runCollectSweep } from "../../src/entrypoints/routes-collect";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Debt collection + goals (migration 019) against the real API code, PostgREST and Postgres: money that arrives with a
// debt's memo code / the person's name is booked as a repayment (counted once), weaker matches wait for one tap, undo
// gives the money back as it was; a salary proposes a goal allocation.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let cfg: Config;
let app: ReturnType<typeof buildApp>;
let owner = "";
let jwt = "";
const env = {} as never;
let bank = "";
let catSalary = "";

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
  expect([res.status, j.error?.code]).toEqual([200, undefined]);
  return j.data;
}
const ago = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString();
const dateAgo = (days: number) => new Date(Date.now() + 7 * 3_600_000 - days * 86_400_000).toISOString().slice(0, 10);

async function debt(alias: string, direction: "RECEIVABLE" | "PAYABLE", principal: number, extra: Record<string, unknown> = {}) {
  const contact = (await cmd("CONTACT_CREATE", { alias })).contact_id as string;
  const r = await cmd("DEBT_CREATE", { direction, contact_id: contact, principal: String(principal), originated_at: ago(10), account_id: bank, ...extra });
  return { id: r.debt_id as string, contact };
}
async function debts(): Promise<any[]> {
  return (await call("GET", "/v1/debts")).json.data;
}
async function debtById(id: string) {
  return (await debts()).find((d) => d.id === id);
}
async function money(kind: string, amount: number, note: string, source = "NOTIFICATION", extra: Record<string, unknown> = {}) {
  return (await cmd("TX_CREATE", { kind, account_id: bank, amount: String(amount), effective_at: new Date().toISOString(), note, source, ...extra })).tx_id as string;
}
async function tx(id: string) {
  return ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).find((t) => t.id === id);
}
async function balance() {
  return Number(((await call("GET", "/v1/accounts")).json.data as any[]).find((a) => a.id === bank).balance);
}
async function ledgerZero() {
  const r = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(r.rows[0].s).toBe("0");
}

beforeAll(async () => {
  h = await startHarness();
  cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Lê Đào Nhân Sâm" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  bank = (await cmd("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "VCB", opening_amount: "20000000", baseline_at: ago(30) })).account_id;
  catSalary = ((await call("GET", "/v1/categories")).json.data as any[]).find((c) => c.name === "Lương").id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("debt collection", () => {
  let autoSettle = "";
  let namDebt = "";
  let namMoney = "";

  it("money with the debt's memo code from NGUYEN VAN NAM is booked as his repayment, not as income", async () => {
    const d = await debt("Nguyễn Văn Nam", "RECEIVABLE", 535_000, { note: "tiền nhà" });
    namDebt = d.id;
    const rem = (await call("GET", `/v1/debts/${d.id}/reminder`)).json.data;
    expect(rem.memo).toMatch(/^MOMA [A-Z0-9]{6}$/);
    expect(rem.message).toContain("535.000đ");
    expect(rem.message).toContain(rem.memo);
    expect(rem.tone).toBe("first");
    const before = await balance();
    const incomeBefore = Number((await call("GET", "/v1/reports/summary")).json.data.income);

    namMoney = await money("UNKNOWN_CREDIT", 535_000, `NGUYEN VAN NAM chuyen tien ${rem.memo}`);
    const after = await debtById(d.id);
    expect(after.state).toBe("SETTLED");
    expect(after.remaining).toBe("0");
    expect((await tx(namMoney)).status).toBe("VOID");
    const settle = (await call("GET", `/v1/transactions/${namMoney}/collect`)).json.data;
    expect(settle.state).toBe("AUTO");
    expect(settle.hints).toContain("memo");
    autoSettle = settle.id;
    const repay = await tx(settle.repay_tx_id);
    expect([repay.kind, repay.status, repay.source]).toEqual(["LOAN_COLLECTED", "POSTED", "NOTIFICATION"]);
    expect(repay.note).toContain("NGUYEN VAN NAM");
    expect(await balance()).toBe(before + 535_000);
    expect(Number((await call("GET", "/v1/reports/summary")).json.data.income)).toBe(incomeBefore); // not counted as income
    await ledgerZero();
  });

  it("undo gives the money back exactly as it arrived and the debt is open again; never re-suggested", async () => {
    const before = await balance();
    const r = await call("POST", `/v1/collect/${autoSettle}/undo`);
    expect(r.status).toBe(200);
    expect(r.json.data.state).toBe("REJECTED");
    const restored = await tx(r.json.data.restored_tx_id);
    expect([restored.kind, restored.status, restored.amount]).toEqual(["UNKNOWN_CREDIT", "POSTED", "535000"]);
    expect((await debtById(namDebt)).state).toBe("OPEN");
    expect(await balance()).toBe(before);
    await ledgerZero();
    // The re-created money is a new transaction: the sweep may match it again by memo → that is the owner's call now,
    // but the original pair is never suggested again.
    const sug = (await call("GET", "/v1/collect/suggestions")).json.data as any[];
    expect(sug.some((s) => s.money.tx_id === namMoney)).toBe(false);
    // The re-created copy carries the same memo code but is never booked against Nam again (no undo loop).
    await runCollectSweep({ cfg, gw: new SupabaseFinanceGateway(cfg) }, new Date());
    expect((await debtById(namDebt)).state).toBe("OPEN");
    expect((await tx(r.json.data.restored_tx_id)).status).toBe("POSTED");
    // Cancel the debt so it does not interfere with the next cases.
    const dd = await debtById(namDebt);
    await cmd("DEBT_CANCEL", { debt_id: namDebt, expected_version: dd.version, reason: "test" });
  });

  it("a partial payment with the memo code settles part of the debt automatically", async () => {
    const d = await debt("Trần Thị Lan", "RECEIVABLE", 1_000_000);
    const memo = (await call("GET", `/v1/debts/${d.id}/reminder`)).json.data.memo;
    const m = await money("UNKNOWN_CREDIT", 400_000, `${memo} tra truoc`);
    const after = await debtById(d.id);
    expect([after.state, after.remaining]).toEqual(["PARTIAL", "600000"]);
    expect((await tx(m)).status).toBe("VOID");
    await ledgerZero();
    // "Hoàn tác" in the debt sheet (DEBT_PAYMENT_REVERSE): the 400.000 comes back as it arrived, balance unchanged.
    const before = await balance();
    const pay = after.payments.find((p: any) => !p.reversed);
    await cmd("DEBT_PAYMENT_REVERSE", { debt_id: d.id, payment_id: pay.id, expected_version: after.version });
    expect((await debtById(d.id)).remaining).toBe("1000000");
    expect(await balance()).toBe(before);
    const back = ((await call("GET", "/v1/transactions?limit=100")).json.data as any[]).filter((t) => t.status === "POSTED" && t.amount === "400000" && t.kind === "UNKNOWN_CREDIT");
    expect(back).toHaveLength(1);
    await ledgerZero();
  });

  it("name + partial amount waits for one tap; accepting books it", async () => {
    const d = await debt("Phạm Quốc Bảo", "RECEIVABLE", 800_000);
    const m = await money("UNKNOWN_CREDIT", 300_000, "PHAM QUOC BAO chuyen khoan");
    expect((await tx(m)).status).toBe("POSTED");
    const sug = ((await call("GET", "/v1/collect/suggestions")).json.data as any[]).filter((s) => s.money.tx_id === m);
    expect(sug).toHaveLength(1);
    expect(sug[0].debt.id).toBe(d.id);
    const r = await call("POST", `/v1/collect/${sug[0].id}/decide`, { accept: true });
    expect(r.json.data.state).toBe("CONFIRMED");
    expect((await debtById(d.id)).remaining).toBe("500000");
    expect((await tx(m)).status).toBe("VOID");
    await ledgerZero();
  });

  it("two overdue debtors owing the same amount and no name: both suggested, none booked; choosing one rejects the other", async () => {
    const a = await debt("Huy", "RECEIVABLE", 200_000, { due_date: dateAgo(3) });
    const b = await debt("Minh", "RECEIVABLE", 200_000, { due_date: dateAgo(2) });
    const m = await money("UNKNOWN_CREDIT", 200_000, "CHUYEN TIEN");
    expect((await tx(m)).status).toBe("POSTED");
    const sug = ((await call("GET", "/v1/collect/suggestions")).json.data as any[]).filter((s) => s.money.tx_id === m);
    expect(sug.map((s) => s.debt.id).sort()).toEqual([a.id, b.id].sort());
    expect((await debtById(a.id)).state).toBe("OPEN");
    const pick = sug.find((s) => s.debt.id === b.id);
    expect((await call("POST", `/v1/collect/${pick.id}/decide`, { accept: true })).json.data.state).toBe("CONFIRMED");
    expect((await debtById(b.id)).state).toBe("SETTLED");
    const left = ((await call("GET", "/v1/collect/suggestions")).json.data as any[]).filter((s) => s.money.tx_id === m);
    expect(left).toEqual([]);
    await ledgerZero();
  });

  it("paying a creditor (full name + full amount) settles what the owner owes, not an expense", async () => {
    const d = await debt("Lê Văn Hùng", "PAYABLE", 300_000);
    const expenseBefore = Number((await call("GET", "/v1/reports/summary")).json.data.expense);
    const m = await money("UNKNOWN_DEBIT", 300_000, "CK LE VAN HUNG tra no");
    expect((await tx(m)).status).toBe("VOID");
    expect((await debtById(d.id)).state).toBe("SETTLED");
    expect(Number((await call("GET", "/v1/reports/summary")).json.data.expense)).toBe(expenseBefore);
    // the debt sheet's "Hoàn tác" for that repayment goes through the collect undo (money comes back as captured)
    const repayTx = (await call("GET", `/v1/transactions/${m}/collect`)).json.data.repay_tx_id;
    const u = await call("POST", "/v1/collect/undo-by-tx", { tx_id: repayTx });
    expect(u.json.data.undone).toBe(true);
    expect((await tx(u.json.data.restored_tx_id)).status).toBe("POSTED");
    expect((await call("POST", "/v1/collect/undo-by-tx", { tx_id: crypto.randomUUID() })).json.data.undone).toBe(false);
    await ledgerZero();
  });

  it("reminders: due list carries the message and memo, marking reminded makes the next one firmer; creditor bank is saved", async () => {
    const d = await debt("Đỗ Thu Trang", "RECEIVABLE", 150_000, { due_date: dateAgo(1), note: "tiền vé xem phim" });
    const due = (await call("GET", "/v1/debts/reminders")).json.data as any[];
    const r = due.find((x) => x.debt_id === d.id);
    expect(r.message).toContain("150.000đ");
    expect(r.message).toContain("tiền vé xem phim");
    expect(r.tone).toBe("second"); // already overdue
    expect((await call("POST", `/v1/debts/${d.id}/reminded`)).json.data.remind_count).toBe(1);
    // reminded today → not due again until 7 days later
    expect(((await call("GET", "/v1/debts/reminders")).json.data as any[]).some((x) => x.debt_id === d.id)).toBe(false);
    const snooze = await call("POST", `/v1/debts/${d.id}/snooze`, { days: 3 });
    expect(snooze.status).toBe(200);

    const p = await debt("Võ Minh Khôi", "PAYABLE", 90_000, { due_date: dateAgo(-1) });
    const bankSet = await call("PUT", `/v1/contacts/${p.contact}/bank`, { bank: "Techcombank", bin: "970407", account_number: "1903 1234 5678", holder: "vo minh khoi" });
    expect(bankSet.status).toBe(200);
    const pr = (await call("GET", `/v1/debts/${p.id}/reminder`)).json.data;
    expect(pr.contact_bank).toEqual({ bank: "Techcombank", bin: "970407", account_number: "190312345678", holder: "VO MINH KHOI" });
    expect(((await call("GET", "/v1/debts/reminders")).json.data as any[]).some((x) => x.debt_id === p.id)).toBe(true); // due tomorrow
    expect((await call("PUT", `/v1/contacts/${p.contact}/bank`, { account_number: "12" })).status).toBe(400);
  });
});

describe("self-running goals", () => {
  it("a salary proposes the goal's monthly saving; one tap allocates it; milestones are announced once", async () => {
    const due = new Date(Date.now() + 7 * 3_600_000 + 365 * 86_400_000).toISOString().slice(0, 10);
    const g = (await cmd("GOAL_CREATE", { name: "Laptop", target: "25000000", due_date: due })).goal_id;
    const plan = ((await call("GET", "/v1/goals/plan")).json.data as any[]).find((x) => x.id === g);
    expect(plan.months_left).toBeGreaterThanOrEqual(12);
    expect(Number(plan.required_monthly)).toBeGreaterThan(1_900_000);
    const expected = Math.ceil(Number(plan.required_monthly) / 50_000) * 50_000;

    const salary = await money("INCOME", 15_000_000, "Luong thang 11", "MANUAL", { category_id: catSalary });
    const props = ((await call("GET", "/v1/goals/proposals")).json.data as any[]).filter((p) => p.goal_id === g);
    expect(props).toHaveLength(1);
    expect([props[0].reason, props[0].amount, props[0].source_tx, props[0].account_id]).toEqual(["INCOME", String(expected), salary, bank]);
    // the same income never proposes twice (the sweep re-checks it)
    await runCollectSweep({ cfg, gw: new SupabaseFinanceGateway(cfg) }, new Date());
    expect(((await call("GET", "/v1/goals/proposals")).json.data as any[]).filter((p) => p.goal_id === g)).toHaveLength(1);

    const acc = await call("POST", `/v1/goals/proposals/${props[0].id}/accept`);
    expect([acc.status, acc.json.data.state, acc.json.data.allocated]).toEqual([200, "ACCEPTED", String(expected)]);
    expect((await call("POST", `/v1/goals/proposals/${props[0].id}/accept`)).json.data.replayed).toBe(true);
    expect(((await call("GET", "/v1/goals/proposals")).json.data as any[]).filter((p) => p.goal_id === g)).toHaveLength(0);
    const after = ((await call("GET", "/v1/goals/plan")).json.data as any[]).find((x) => x.id === g);
    expect(after.allocated).toBe(String(expected));
    expect(Number(after.pace_monthly)).toBeGreaterThan(0);
    expect(after.eta).not.toBeNull();

    // 25 % milestone after a bigger allocation; announced once
    const gv = ((await call("GET", "/v1/goals")).json.data as any).goals?.find?.((x: any) => x.id === g) ?? null;
    const version = gv?.version ?? (await h.db.query("select version from pf_goal where id = $1", [g])).rows[0].version;
    await cmd("GOAL_ALLOCATE", { goal_id: g, account_id: bank, amount: "5000000", expected_version: version });
    const ms = (await h.db.query("select public.pf_goal_milestones_due($1) as m", [owner])).rows[0].m;
    expect(ms).toEqual([expect.objectContaining({ goal_id: g, pct: 25 })]);
    expect((await h.db.query("select public.pf_goal_milestones_due($1) as m", [owner])).rows[0].m).toEqual([]);
    await ledgerZero();
  });

  it("small income does not propose; dismissing three times stops proposals of that kind", async () => {
    const g = (await cmd("GOAL_CREATE", { name: "Du lịch", target: "6000000" })).goal_id;
    await money("UNKNOWN_CREDIT", 150_000, "hoan tien", "NOTIFICATION");
    expect(((await call("GET", "/v1/goals/proposals")).json.data as any[]).filter((p) => p.goal_id === g)).toHaveLength(0);
    for (let i = 0; i < 3; i++) {
      const r = (await h.db.query("select public.pf_goal_propose($1, $2) as r", [owner, { goal_id: g, account_id: bank, amount: "100000", reason: "MONTH_END", period: `2026-0${i + 1}` }])).rows[0].r;
      expect(r.status).toBe("PROPOSED");
      expect((await call("POST", `/v1/goals/proposals/${r.id}/dismiss`)).status).toBe(200);
    }
    const r4 = (await h.db.query("select public.pf_goal_propose($1, $2) as r", [owner, { goal_id: g, account_id: bank, amount: "100000", reason: "MONTH_END", period: "2026-04" }])).rows[0].r;
    expect(r4).toEqual({ status: "SKIPPED", why: "dismissed" });
  });

  it("month surplus compares spending with the overall budget", async () => {
    const month = new Date(Date.now() + 7 * 3_600_000).toISOString().slice(0, 7);
    await cmd("BUDGET_UPSERT", { month, limit: "50000000", carryover: false });
    const s = (await h.db.query("select public.pf_goal_month_surplus($1, $2) as s", [owner, month])).rows[0].s;
    expect(s.basis).toBe("BUDGET");
    expect(Number(s.surplus)).toBe(50_000_000 - Number(s.spent));
    expect(s.account_id).toBe(bank);
  });
});
