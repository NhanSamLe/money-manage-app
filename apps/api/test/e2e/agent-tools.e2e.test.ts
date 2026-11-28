import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { PHOTO_PREFIX } from "../../src/modules/ai/memory";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// The assistant's tools against the real API, PostgREST and Postgres (model faked): planned actions are executed the
// way the app does it (step results fill `$sN.field` / `$contact_id`), then taken back through POST /v1/ai/undo.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";

let h: Harness;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
let replies: unknown[] = [];
const env = {} as never;
const ids: Record<string, string> = {};

const ai = async () => ({ content: JSON.stringify(replies.shift() ?? { reply: "", steps: [] }), usage: { prompt_tokens: 10, completion_tokens: 10 } });

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}` }, body: body === undefined ? null : JSON.stringify(body) }, env);
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const res = await app.request("/v1/commands", {
    method: "POST",
    headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, "idempotency-key": id },
    body: JSON.stringify({ command_id: id, command_type: type, schema_version: 1, payload }),
  }, env);
  const json = (await res.json()) as any;
  expect(res.status, JSON.stringify(json)).toBe(200);
  return json.data;
}

/** Runs the COMMAND actions like the Flutter app: pre-command, `$sN.field` from earlier results, `$result.field` for undo. */
async function execute(actions: any[]) {
  const results: Record<string, any> = {};
  const done: { action: any; result: any; commandId: string }[] = [];
  for (const a of actions) {
    if (a.type !== "COMMAND") continue;
    let payload = JSON.stringify(a.command.payload);
    if (a.pre) {
      const r = await cmd(a.pre.command_type, a.pre.payload);
      payload = payload.replaceAll(`$${a.pre.bind}`, r[a.pre.bind]);
    }
    payload = payload.replace(/"\$(s\d{1,2}[a-z]?)\.([a-z_]+)"/g, (_m, step, field) => JSON.stringify(results[step]?.[field]));
    const commandId = crypto.randomUUID();
    const res = await app.request("/v1/commands", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, "idempotency-key": commandId },
      body: JSON.stringify({ command_id: commandId, command_type: a.command.command_type, schema_version: 1, payload: JSON.parse(payload) }),
    }, env);
    const json = (await res.json()) as any;
    expect(res.status, JSON.stringify(json)).toBe(200);
    results[a.id] = json.data;
    done.push({ action: a, result: json.data, commandId });
  }
  return done;
}
async function undo(step: { action: any; result: any; commandId: string }) {
  const fill = (v: unknown): unknown => (typeof v === "string" && v.startsWith("$result.") ? step.result[v.slice(8)] : v);
  const ops = step.action.undo.ops.map((op: Record<string, unknown>) => Object.fromEntries(Object.entries(op).map(([k, v]) => [k, fill(v)])));
  const r = await call("POST", "/v1/ai/undo", { step_command_id: step.commandId, ops, ...(step.action.undo.habit ? { habit: step.action.undo.habit } : {}) });
  expect(r.status, JSON.stringify(r.json)).toBe(200);
  return r.json.data;
}
async function balance(account: string): Promise<number> {
  const accounts = (await call("GET", "/v1/accounts")).json.data as any[];
  return Number(accounts.find((a) => a.id === account).balance);
}
async function ledgerZero() {
  const r = await h.db.query("select coalesce(sum(signed_amount::numeric), 0)::text as s from pf_entry");
  expect(r.rows[0].s).toBe("0");
}

beforeAll(async () => {
  h = await startHarness();
  const cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg), ai }) as never);
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await call("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await call("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  ids.vcb = (await cmd("ACCOUNT_CREATE", { kind: "BANK", institution: "Vietcombank", name: "VCB", opening_amount: "5000000", baseline_at: new Date(Date.now() - 86_400_000).toISOString() })).account_id;
  const cats = (await call("GET", "/v1/categories")).json.data as any[];
  ids.food = cats.find((c) => c.type === "EXPENSE" && /ăn/i.test(c.name))?.id ?? cats.find((c) => c.type === "EXPENSE").id;
  ids.nam = (await cmd("CONTACT_CREATE", { alias: "Nam" })).contact_id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("assistant tools on the real ledger", () => {
  it("bill photo -> split question -> 'chia Nam với Lan' -> one expense + split debts; Hoàn tác restores everything", async () => {
    const before = await balance(ids.vcb!);
    const bill = `${PHOTO_PREFIX}\nQUÁN LẨU THÁI\nSố khách: 3\nLẩu thái 1 389.000\nBia Tiger 6 150.000\nTổng cộng 849.000`;
    replies = [{ reply: "Hóa đơn lẩu 849.000đ.", steps: [{ do: "EXPENSE", amount: "849000", account: ids.vcb, category: ids.food, note: "Lẩu Thái" }] }];
    const first = (await call("POST", "/v1/ai/agent", { text: bill })).json.data;
    expect(first.actions[0].type).toBe("CHOICES");
    const pending = first.plan.find((p: any) => p.do === "SPLIT_PENDING");
    expect(pending).toEqual(expect.objectContaining({ amount: "849000", account: ids.vcb, purpose: "EATOUT" }));

    replies = [{ reply: "Đã chia.", steps: [{ do: "SPLIT", amount: "849000", people: ["Nam", "Lan"], include_me: true, account: ids.vcb, category: ids.food, note: "Lẩu Thái", tx: null }] }];
    const second = (await call("POST", "/v1/ai/agent", { text: "chia Nam với Lan", previous: { steps: [{ do: "SPLIT_PENDING", status: "ASKED", data: pending }] } })).json.data;
    expect(second.actions.map((a: any) => a.command?.command_type)).toEqual(["TX_CREATE", "SPLIT_APPLY"]);
    const done = await execute(second.actions);
    expect(await balance(ids.vcb!)).toBe(before - 849000);
    const debts = ((await call("GET", "/v1/debts")).json.data as any[]).filter((x) => x.state === "OPEN");
    expect(debts.map((x) => [x.contact_alias, x.principal]).sort()).toEqual([["Lan", "285000"], ["Nam", "285000"]]);
    const summary = (await call("GET", "/v1/reports/summary")).json.data;
    expect(Number(summary.expense)).toBe(279000); // the owner's share only
    await ledgerZero();

    // Hoàn tác the split, then the expense: back to where we started.
    await undo(done[1]!);
    expect(((await call("GET", "/v1/debts")).json.data as any[]).filter((x) => x.state === "OPEN")).toEqual([]);
    await undo(done[0]!);
    expect(await balance(ids.vcb!)).toBe(before);
    // Second tap on the same Hoàn tác is harmless.
    const again = await undo(done[0]!);
    expect(again.undone[0].status).toMatch(/REPLAYED|ALREADY_UNDONE|COMMITTED/);
    expect(await balance(ids.vcb!)).toBe(before);
    await ledgerZero();
  });

  it("a payment already captured from the bank is filled in from the photo, not recorded twice", async () => {
    const captured = (await cmd("TX_CREATE", { kind: "UNKNOWN_DEBIT", account_id: ids.vcb, amount: "64000", effective_at: new Date(Date.now() - 20 * 60_000).toISOString(), source: "NOTIFICATION" })).tx_id;
    const before = await balance(ids.vcb!);
    replies = [{ reply: "", steps: [{ do: "EXPENSE", amount: "64000", account: ids.vcb, category: ids.food, note: "Highlands", tx: captured }] }];
    const r = (await call("POST", "/v1/ai/agent", { text: `${PHOTO_PREFIX}\nHIGHLANDS COFFEE\nPhin sữa đá 1 39.000\nBánh mì que 1 25.000\nTổng cộng 64.000` })).json.data;
    expect(r.actions).toHaveLength(1);
    expect(r.actions[0].command.command_type).toBe("TX_ANNOTATE");
    expect(r.actions[0].attach_photo).toBe(true);
    await execute(r.actions);
    const t = ((await call("GET", "/v1/transactions?limit=50")).json.data as any[]).find((x) => x.id === captured);
    expect(t.kind).toBe("EXPENSE");
    expect(t.category_id).toBe(ids.food);
    expect(await balance(ids.vcb!)).toBe(before);
    await ledgerZero();
  });

  it("lending through the agent runs by itself and Hoàn tác cancels the debt", async () => {
    const before = await balance(ids.vcb!);
    replies = [{ reply: "Đã ghi.", steps: [{ do: "LEND", amount: "300000", who: "Nam", contact: ids.nam, account: ids.vcb }] }];
    const r = (await call("POST", "/v1/ai/agent", { text: "Nam mượn 300k" })).json.data;
    expect(r.actions[0].risk).toBe("low");
    const done = await execute(r.actions);
    expect(await balance(ids.vcb!)).toBe(before - 300000);
    await undo(done[0]!);
    expect(await balance(ids.vcb!)).toBe(before);
    await ledgerZero();
  });

  it("generic CMD tool: rename a contact found by LOOKUP-free id, undoable where it makes sense", async () => {
    replies = [{ reply: "Đã thêm.", steps: [{ do: "CMD", type: "CONTACT_CREATE", payload: { alias: "Huy" } }, { do: "CMD", type: "DEBT_CREATE", payload: { direction: "RECEIVABLE", contact_id: "$s1.contact_id", principal: "50000", originated_at: new Date().toISOString(), account_id: ids.vcb } }] }];
    const r = (await call("POST", "/v1/ai/agent", { text: "Huy nợ tôi 50k, thêm Huy vào danh bạ" })).json.data;
    expect(r.actions.map((a: any) => a.type)).toEqual(["COMMAND", "COMMAND"]);
    const done = await execute(r.actions);
    expect(((await call("GET", "/v1/debts")).json.data as any[]).some((x) => x.contact_alias === "Huy" && x.state === "OPEN")).toBe(true);
    await undo(done[1]!);
    await undo(done[0]!);
    expect(((await call("GET", "/v1/contacts")).json.data as any[]).find((c) => c.alias === "Huy")?.archived ?? true).toBe(true);
    await ledgerZero();
  });
});
