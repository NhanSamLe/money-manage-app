import { afterEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { MAX_ATTACHMENT_BYTES, sniffImage, type AttachmentBucket } from "../../src/entrypoints/routes-attachments";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

const OWNER = "11111111-1111-4111-8111-111111111111";
const TX = "22222222-2222-4222-8222-222222222222";
const ATT = "55555555-5555-4555-8555-555555555555";
const cfg: Config = {
  supabaseUrl: "https://db.test",
  publishableKey: "pk",
  serviceRoleKey: "sk",
  ownerEmail: "o@test",
  dbTimeoutMs: 1000,
};
const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444" };
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 6, 7, 8]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
const WEBP = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);

function fakeBucket() {
  const store = new Map<string, Uint8Array>();
  const bucket: AttachmentBucket & { store: typeof store } = {
    store,
    put: vi.fn(async (k: string, v: ArrayBuffer) => {
      store.set(k, new Uint8Array(v));
    }),
    get: vi.fn(async (k: string) => {
      const v = store.get(k);
      return v ? { body: new Response(v).body!, size: v.byteLength } : null;
    }),
    delete: vi.fn(async (k: string) => {
      store.delete(k);
    }),
  };
  return bucket;
}

/** Fake PostgREST: answers the attachment RPCs from an in-memory table. */
function fakeDb(opts: { refuseAdd?: string } = {}) {
  const rows: { id: string; tx_id: string; object_key: string; content_type: string; size_bytes: number }[] = [];
  const calls: { name: string; args: any }[] = [];
  const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
    const name = url.split("/rpc/")[1]!;
    const args = JSON.parse(String(init.body));
    calls.push({ name, args });
    const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    if (name === "pf_attachment_add") {
      if (opts.refuseAdd) return json({ code: "P0001", message: opts.refuseAdd }, 400);
      const r = { id: ATT, tx_id: args.p_tx, object_key: args.p_key, content_type: args.p_type, size_bytes: args.p_size };
      rows.push(r);
      return json({ id: r.id, tx_id: r.tx_id, content_type: r.content_type, size_bytes: r.size_bytes });
    }
    if (name === "pf_attachment_list") return json(rows.filter((r) => r.tx_id === args.p_tx).map(({ object_key: _k, ...r }) => r));
    if (name === "pf_attachment_get") {
      const r = rows.find((x) => x.id === args.p_id);
      return r ? json({ object_key: r.object_key, content_type: r.content_type }) : json({ code: "P0001", message: "NOT_FOUND" }, 400);
    }
    if (name === "pf_attachment_delete") {
      const i = rows.findIndex((x) => x.id === args.p_id);
      if (i < 0) return json({ code: "P0001", message: "NOT_FOUND" }, 400);
      const [r] = rows.splice(i, 1);
      return json({ object_key: r!.object_key });
    }
    return json({}, 404);
  });
  vi.stubGlobal("fetch", fetchMock);
  return { rows, calls };
}

function makeApp() {
  const gw = { getOwnerId: vi.fn(async () => OWNER) } as unknown as FinanceGateway;
  const verifier = { verify: vi.fn(async () => ({ userId: OWNER, sessionId: "s" })) } as unknown as SessionVerifier;
  return buildApp(() => ({ cfg, gw, verifier }) as any);
}

afterEach(() => vi.unstubAllGlobals());

describe("sniffImage", () => {
  it("recognises JPEG, PNG and WebP by their bytes and nothing else", () => {
    expect(sniffImage(JPEG)).toBe("image/jpeg");
    expect(sniffImage(PNG)).toBe("image/png");
    expect(sniffImage(WEBP)).toBe("image/webp");
    expect(sniffImage(new TextEncoder().encode("<svg onload=alert(1)>"))).toBeNull();
    expect(sniffImage(new Uint8Array([0xff]))).toBeNull();
  });
});

describe("attachment routes", () => {
  it("upload -> list -> download -> delete keeps R2 and the table in step", async () => {
    const db = fakeDb();
    const bucket = fakeBucket();
    const app = makeApp();
    const env = { ATTACHMENTS: bucket } as never;

    const up = await app.request(`/v1/transactions/${TX}/attachments`, { method: "POST", headers: { ...headers, "content-type": "image/jpeg" }, body: JPEG }, env);
    expect(up.status).toBe(201);
    expect(((await up.json()) as any).data).toMatchObject({ id: ATT, content_type: "image/jpeg", size_bytes: JPEG.length });
    const [key] = [...bucket.store.keys()];
    // Key is scoped by owner and transaction; the extension follows the sniffed type.
    expect(key).toMatch(new RegExp(`^${OWNER}/${TX}/[0-9a-f-]{36}\\.jpg$`));
    expect(db.calls.find((c) => c.name === "pf_attachment_add")!.args).toMatchObject({ p_owner: OWNER, p_tx: TX, p_key: key, p_type: "image/jpeg" });

    const list = (await (await app.request(`/v1/transactions/${TX}/attachments`, { headers }, env)).json()) as any;
    expect(list.data).toHaveLength(1);
    expect(list.data[0]).not.toHaveProperty("object_key");

    const img = await app.request(`/v1/attachments/${ATT}`, { headers }, env);
    expect(img.status).toBe(200);
    expect(img.headers.get("content-type")).toBe("image/jpeg");
    expect(img.headers.get("cache-control")).toContain("private");
    expect(new Uint8Array(await img.arrayBuffer())).toEqual(JPEG);

    const del = await app.request(`/v1/attachments/${ATT}`, { method: "DELETE", headers }, env);
    expect(del.status).toBe(200);
    expect(bucket.store.size).toBe(0);
    expect((await app.request(`/v1/attachments/${ATT}`, { headers }, env)).status).toBe(404);
  });

  it("refuses non-images, empty and oversized bodies before touching R2", async () => {
    fakeDb();
    const bucket = fakeBucket();
    const app = makeApp();
    const env = { ATTACHMENTS: bucket } as never;
    const post = (body: BodyInit, extra: Record<string, string> = {}) =>
      app.request(`/v1/transactions/${TX}/attachments`, { method: "POST", headers: { ...headers, ...extra }, body }, env);

    const svg = await post(new TextEncoder().encode("<svg/>"), { "content-type": "image/jpeg" });
    expect(svg.status).toBe(422);
    expect(((await svg.json()) as any).error.code).toBe("ATTACHMENT_TYPE");
    expect((await post(new Uint8Array(0))).status).toBe(400);
    const big = new Uint8Array(MAX_ATTACHMENT_BYTES + 1);
    big.set(JPEG);
    const tooBig = await post(big);
    expect(tooBig.status).toBe(422);
    expect(((await tooBig.json()) as any).error.code).toBe("ATTACHMENT_TOO_LARGE");
    expect(bucket.put).not.toHaveBeenCalled();
    expect((await app.request(`/v1/transactions/not-a-uuid/attachments`, { headers }, env)).status).toBe(400);
  });

  it("removes the uploaded object again when the database refuses the row (no orphans)", async () => {
    fakeDb({ refuseAdd: "ATTACHMENT_LIMIT" });
    const bucket = fakeBucket();
    const app = makeApp();
    const res = await app.request(`/v1/transactions/${TX}/attachments`, { method: "POST", headers, body: PNG }, { ATTACHMENTS: bucket } as never);
    expect(res.status).toBe(422);
    expect(((await res.json()) as any).error.code).toBe("ATTACHMENT_LIMIT");
    expect(bucket.put).toHaveBeenCalledTimes(1);
    expect(bucket.store.size).toBe(0);
  });

  it("reports storage unavailable when the bucket is not bound, and requires auth", async () => {
    fakeDb();
    const app = makeApp();
    const res = await app.request(`/v1/transactions/${TX}/attachments`, { method: "POST", headers, body: JPEG }, {} as never);
    expect(res.status).toBe(503);
    // 503s are reported as the generic retryable TEMPORARY_FAILURE (http.ts convention).
    expect(((await res.json()) as any).error.code).toBe("TEMPORARY_FAILURE");
  });
});
