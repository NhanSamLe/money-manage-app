import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { AttachmentBucket } from "../../src/entrypoints/routes-attachments";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Transaction attachments (migration 013) against the real API code, PostgREST and Postgres; R2 is an in-memory map.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...Array.from({ length: 60 }, (_, i) => i)]);

let h: Harness;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
const store = new Map<string, Uint8Array>();
const bucket: AttachmentBucket = {
  put: async (k, v) => void store.set(k, new Uint8Array(v)),
  get: async (k) => {
    const v = store.get(k);
    return v ? { body: new Response(v).body!, size: v.byteLength } : null;
  },
  delete: async (k) => void store.delete(k),
};
const env = { ATTACHMENTS: bucket } as never;

async function call(method: string, path: string, body?: unknown, raw?: Uint8Array) {
  const headers: Record<string, string> = { "x-device-id": DEVICE, authorization: `Bearer ${jwt}` };
  if (!raw) headers["content-type"] = "application/json";
  const res = await app.request(path, { method, headers, body: raw ?? (body === undefined ? null : JSON.stringify(body)) }, env);
  return res;
}
async function json(method: string, path: string, body?: unknown, raw?: Uint8Array) {
  const res = await call(method, path, body, raw);
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
  expect(res.status).toBe(200);
  return ((await res.json()) as any).data;
}

beforeAll(async () => {
  h = await startHarness();
  const cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 10_000 } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await h.db.query("select id from auth.users where email = 'owner@example.test'")).rows[0].id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await json("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await json("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("transaction attachments", () => {
  beforeEach(() => store.clear());
  it("attach, list, open and delete a receipt picture; Postgres only keeps the key", async () => {
    const account = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Tiền mặt", opening_amount: "500000", baseline_at: new Date(Date.now() - 86_400_000).toISOString() })).account_id;
    const cats = (await json("GET", "/v1/categories")).json.data as any[];
    const cat = cats.find((c) => c.type === "EXPENSE").id;
    const tx = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: account, amount: "65000", category_id: cat, effective_at: new Date().toISOString() })).tx_id;

    const up = await json("POST", `/v1/transactions/${tx}/attachments`, undefined, JPEG);
    expect(up.status).toBe(201);
    const id = up.json.data.id as string;
    expect(store.size).toBe(1);

    const row = (await h.db.query("select object_key, size_bytes, content_type from pf_tx_attachment where id = $1", [id])).rows[0];
    expect(row).toMatchObject({ size_bytes: JPEG.length, content_type: "image/jpeg" });
    expect(row.object_key.startsWith(`${owner}/${tx}/`)).toBe(true);

    const list = await json("GET", `/v1/transactions/${tx}/attachments`);
    expect(list.json.data).toEqual([expect.objectContaining({ id, tx_id: tx, content_type: "image/jpeg", size_bytes: JPEG.length })]);

    const img = await call("GET", `/v1/attachments/${id}`);
    expect(img.status).toBe(200);
    expect(new Uint8Array(await img.arrayBuffer())).toEqual(JPEG);

    expect((await json("DELETE", `/v1/attachments/${id}`)).status).toBe(200);
    expect(store.size).toBe(0);
    expect((await json("GET", `/v1/transactions/${tx}/attachments`)).json.data).toEqual([]);
    expect((await json("GET", `/v1/attachments/${id}`)).status).toBe(404);
  });

  it("pictures stay visible after the transaction is edited (new version lists the old version's receipts)", async () => {
    const account = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Ví sửa", opening_amount: "300000", baseline_at: new Date(Date.now() - 86_400_000).toISOString() })).account_id;
    const cat = ((await json("GET", "/v1/categories")).json.data as any[]).find((c) => c.type === "EXPENSE").id;
    const tx = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: account, amount: "20000", category_id: cat, effective_at: new Date().toISOString() })).tx_id;
    const first = (await json("POST", `/v1/transactions/${tx}/attachments`, undefined, JPEG)).json.data.id;
    const edited = await cmd("TX_CORRECT", {
      tx_id: tx,
      reason: "Sửa số tiền",
      expected_version: ((await json("GET", "/v1/transactions?limit=100")).json.data as any[]).find((x) => x.id === tx).version,
      replacement: { kind: "EXPENSE", account_id: account, amount: "25000", category_id: cat, effective_at: new Date().toISOString() },
    });
    const newTx = (edited.replacement_tx_id ?? edited.tx_id) as string;
    expect(newTx).not.toBe(tx);
    const second = (await json("POST", `/v1/transactions/${newTx}/attachments`, undefined, JPEG)).json.data.id;
    const list = (await json("GET", `/v1/transactions/${newTx}/attachments`)).json.data as any[];
    expect(list.map((a) => a.id)).toEqual([first, second]);
    // The old version only sees its own picture.
    expect(((await json("GET", `/v1/transactions/${tx}/attachments`)).json.data as any[]).map((a) => a.id)).toEqual([first]);
  });

  it("an unknown transaction is refused and leaves no picture behind", async () => {
    const r = await json("POST", `/v1/transactions/${crypto.randomUUID()}/attachments`, undefined, JPEG);
    expect(r.status).toBe(404);
    expect(store.size).toBe(0);
  });

  it("keeps at most 10 pictures per transaction", async () => {
    const account = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Ví phụ", opening_amount: "100000", baseline_at: new Date(Date.now() - 86_400_000).toISOString() })).account_id;
    const cat = ((await json("GET", "/v1/categories")).json.data as any[]).find((c) => c.type === "EXPENSE").id;
    const tx = (await cmd("TX_CREATE", { kind: "EXPENSE", account_id: account, amount: "1000", category_id: cat, effective_at: new Date().toISOString() })).tx_id;
    for (let i = 0; i < 10; i++) expect((await json("POST", `/v1/transactions/${tx}/attachments`, undefined, JPEG)).status).toBe(201);
    const over = await json("POST", `/v1/transactions/${tx}/attachments`, undefined, JPEG);
    expect(over.status).toBe(422);
    expect(over.json.error?.code).toBe("ATTACHMENT_LIMIT");
    expect(store.size).toBe(10);
  });
});
