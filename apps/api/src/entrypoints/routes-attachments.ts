import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import { DomainError } from "../shared/errors";

// Transaction attachments (migration 013): pictures go to Cloudflare R2, Postgres keeps only the object key.
// Every read and write checks the owner through the RPCs; R2 objects are never public.

/** The subset of the Workers R2 binding used here (keeps tests free of the Workers runtime). */
export interface AttachmentBucket {
  put(key: string, value: ArrayBuffer, options?: { httpMetadata?: { contentType?: string } }): Promise<unknown>;
  get(key: string): Promise<{ body: ReadableStream; size: number } | null>;
  delete(key: string): Promise<void>;
  /** One page of keys under a prefix (orphan sweep, routes-maintenance.ts). Optional so test fakes may omit it. */
  list?(opts: { prefix?: string; cursor?: string; limit?: number }): Promise<{
    objects: { key: string; uploaded?: Date; size?: number }[];
    truncated: boolean;
    cursor?: string;
  }>;
}

interface AttachmentDeps {
  cfg: Config;
}

export const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
const TYPES: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

function ok(c: Context<any>, data: unknown, status = 200) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } }, status as any);
}

async function rpc<T>(cfg: Config, name: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: cfg.serviceRoleKey, authorization: `Bearer ${cfg.serviceRoleKey}`, "content-type": "application/json" },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(cfg.dbTimeoutMs),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
    if (body.code !== "P0001") console.log(JSON.stringify({ op: "rpc_failed", rpc: name, status: res.status, pg: body.code ?? null }));
    throw new DomainError(body.code === "P0001" && body.message ? body.message : "DB_ERROR");
  }
  return (await res.json()) as T;
}

/** Sniffs the real image type from the first bytes; the declared content-type is not trusted. */
export function sniffImage(b: Uint8Array): string | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (
    b.length >= 12 &&
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  )
    return "image/webp";
  return null;
}

const UUID = z.string().uuid();
/** Path ids: anything but a UUID is a 400 VALIDATION_FAILED (never an unexpected error). */
function idParam(c: Context<any>, name: string): string {
  const r = UUID.safeParse(c.req.param(name));
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}

export function registerAttachmentRoutes(
  app: Hono<any>,
  getDeps: (env: any) => AttachmentDeps,
  getBucket: (env: any) => AttachmentBucket | undefined,
  auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>,
) {
  const bucketOf = (c: Context<any>): AttachmentBucket => {
    const b = getBucket(c.env);
    if (!b) throw new DomainError("STORAGE_UNAVAILABLE");
    return b;
  };

  app.get("/v1/transactions/:id/attachments", auth, async (c) => {
    const tx = idParam(c, "id");
    const data = await rpc(getDeps(c.env).cfg, "pf_attachment_list", { p_owner: (c as any).get("owner"), p_tx: tx });
    return ok(c, data);
  });

  // Body = the raw picture (already compressed on the phone). One picture per request.
  app.post("/v1/transactions/:id/attachments", auth, async (c) => {
    const tx = idParam(c, "id");
    const owner = (c as any).get("owner") as string;
    const declared = Number(c.req.header("content-length") ?? "0");
    if (declared > MAX_ATTACHMENT_BYTES) throw new DomainError("ATTACHMENT_TOO_LARGE");
    const buf = await c.req.arrayBuffer();
    if (buf.byteLength === 0) throw new DomainError("VALIDATION_FAILED");
    if (buf.byteLength > MAX_ATTACHMENT_BYTES) throw new DomainError("ATTACHMENT_TOO_LARGE");
    const type = sniffImage(new Uint8Array(buf, 0, Math.min(16, buf.byteLength)));
    if (!type) throw new DomainError("ATTACHMENT_TYPE");

    const bucket = bucketOf(c);
    const key = `${owner}/${tx}/${crypto.randomUUID()}.${TYPES[type]}`;
    try {
      await bucket.put(key, buf, { httpMetadata: { contentType: type } });
    } catch (e) {
      console.log(JSON.stringify({ op: "r2_put_failed", error: String(e).slice(0, 200) }));
      throw new DomainError("STORAGE_UNAVAILABLE");
    }
    try {
      const data = await rpc(getDeps(c.env).cfg, "pf_attachment_add", {
        p_owner: owner,
        p_tx: tx,
        p_key: key,
        p_type: type,
        p_size: buf.byteLength,
      });
      return ok(c, data, 201);
    } catch (e) {
      // No orphan pictures: the row was refused (limit, unknown transaction...), so drop the object again.
      await bucket.delete(key).catch(() => undefined);
      throw e;
    }
  });

  app.get("/v1/attachments/:id", auth, async (c) => {
    const id = idParam(c, "id");
    const meta = await rpc<{ object_key: string; content_type: string }>(getDeps(c.env).cfg, "pf_attachment_get", {
      p_owner: (c as any).get("owner"),
      p_id: id,
    });
    const obj = await bucketOf(c).get(meta.object_key);
    if (!obj) throw new DomainError("NOT_FOUND");
    return new Response(obj.body, {
      headers: {
        "content-type": meta.content_type,
        "content-length": String(obj.size),
        // Private to this device; the id never changes content.
        "cache-control": "private, max-age=31536000, immutable",
      },
    });
  });

  app.delete("/v1/attachments/:id", auth, async (c) => {
    const id = idParam(c, "id");
    const r = await rpc<{ object_key: string }>(getDeps(c.env).cfg, "pf_attachment_delete", {
      p_owner: (c as any).get("owner"),
      p_id: id,
    });
    await bucketOf(c)
      .delete(r.object_key)
      .catch((e) => console.log(JSON.stringify({ op: "r2_delete_failed", error: String(e).slice(0, 200) })));
    return ok(c, { deleted: true });
  });
}
