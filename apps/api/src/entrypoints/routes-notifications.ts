import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import { DomainError } from "../shared/errors";

// Notification inbox (migration 012): the app's bell lists every push the server sent, with read state.

interface InboxDeps {
  cfg: Config;
}

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
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

export function registerNotificationRoutes(
  app: Hono<any>,
  getDeps: (env: any) => InboxDeps,
  auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>,
) {
  app.get("/v1/notifications", auth, async (c) => {
    const q = z
      .object({ limit: z.coerce.number().int().min(1).max(200).optional(), before: z.string().datetime({ offset: true }).optional() })
      .parse(c.req.query());
    const data = await rpc(getDeps(c.env).cfg, "pf_notification_list", {
      p_owner: (c as any).get("owner"),
      p_limit: q.limit ?? 50,
      p_before: q.before ?? null,
    });
    return ok(c, data);
  });

  app.post("/v1/notifications/read", auth, async (c) => {
    const body = z
      .object({ ids: z.array(z.string().uuid()).max(200).optional() })
      .parse(await c.req.json().catch(() => ({})));
    const data = await rpc(getDeps(c.env).cfg, "pf_notification_mark_read", {
      p_owner: (c as any).get("owner"),
      p_ids: body.ids ?? null,
    });
    return ok(c, data);
  });
}
