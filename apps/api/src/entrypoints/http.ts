import { Hono, type Context } from "hono";
import { z } from "zod";
import { loadConfig, serviceHeaders, type Config, type Env } from "../bootstrap/config";
import { SessionVerifier, type Session } from "../modules/auth/verify-session";
import { IMPLEMENTED_TYPES, KNOWN_TYPES, implementedCommand } from "../modules/ledger/command-schemas";
import type { CommandContext, FinanceGateway } from "../modules/ledger/ports";
import { SupabaseFinanceGateway } from "../modules/ledger/supabase-gateway";
import { MAX_INPUT_CHARS, MODEL, MONTHLY_CAP_MICRO, actualMicro, buildMessages, buildRequestBody, deepseekProvider, estimateMicro, parseModelJson, resolveOutput, type AccountRef, type CategoryRef, type ProviderCall } from "../modules/ai/assistant";
import { canonicalJson, sha256Hex } from "../shared/canonical";
import { DomainError, isKnownCode, specFor } from "../shared/errors";
import { API_VERSION } from "../shared/version";
import { currentVnDate, currentVnMonth, monthRangeUtc } from "../shared/report-period";

const MAX_BODY_BYTES = 64 * 1024;
const DEFAULT_PAGE = 50;
const MAX_PAGE = 100;
const UUID = z.string().uuid();

interface Deps {
  cfg: Config;
  gw: FinanceGateway;
  verifier: SessionVerifier;
  /** Undefined => AI is OFF (rules + manual only). */
  ai?: ProviderCall;
}
type Vars = { Variables: { rid: string; session: Session; owner: string; deviceId: string } };

// Composition root: concrete adapters are wired here only.
function compose(env: Env): Deps {
  const cfg = loadConfig(env);
  return { cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg), ...(cfg.deepseekKey ? { ai: deepseekProvider(cfg.deepseekKey) } : {}) };
}

function ok(c: Context<Vars>, data: unknown, extra: Record<string, unknown> = {}) {
  return c.json({ data, meta: { request_id: c.get("rid"), ...extra } });
}

function fail(c: Context<Vars>, code: string) {
  const spec = specFor(code);
  // Unknown internal errors never leak details: generic code + correlation id only.
  const publicCode = spec.status === 503 && code !== "DB_ERROR" && !code.startsWith("AI_") ? "TEMPORARY_FAILURE" : code;
  return c.json(
    { error: { code: publicCode, message: spec.message, retryable: spec.retryable, request_id: c.get("rid") } },
    spec.status,
  );
}

export function buildApp(getDeps: (env: Env) => Deps = compose) {
  const app = new Hono<{ Bindings: Env } & Vars>();

  app.use("*", async (c, next) => {
    c.set("rid", crypto.randomUUID());
    const len = Number(c.req.header("content-length") ?? 0);
    if (len > MAX_BODY_BYTES) return fail(c as unknown as Context<Vars>, "VALIDATION_FAILED");
    await next();
  });

  app.onError((err, c) => {
    // Input-validation RangeErrors (bad month, bad money) carry a catalogue code and are client errors, not outages.
    const code =
      err instanceof DomainError ? err.code : err instanceof RangeError && isKnownCode(err.message) ? err.message : "UNEXPECTED";
    // Structured, redacted log: no request/response bodies.
    console.log(JSON.stringify({ request_id: c.get("rid"), op: c.req.path, outcome: "error", code, detail: code === "UNEXPECTED" ? safeDetail(err) : undefined }));
    return fail(c as unknown as Context<Vars>, code);
  });

  // Owner-authenticated routes: JWT valid + sub == singleton owner + device header present.
  const auth = async (c: Context<{ Bindings: Env } & Vars>, next: () => Promise<void>) => {
    const d = getDeps(c.env);
    const session = await d.verifier.verify(c.req.header("authorization"));
    const owner = await d.gw.getOwnerId();
    if (!owner) throw new DomainError("OWNER_NOT_BOUND");
    if (owner !== session.userId) throw new DomainError("IDENTITY_CONFLICT");
    const deviceId = c.req.header("x-device-id") ?? "";
    c.set("session", session);
    c.set("owner", owner);
    c.set("deviceId", deviceId);
    await next();
  };
  const needDevice = (c: Context<{ Bindings: Env } & Vars>): string => {
    const id = c.get("deviceId");
    if (!UUID.safeParse(id).success) throw new DomainError("VALIDATION_FAILED");
    return id;
  };

  // ------------------------------------------------------------ public
  app.get("/v1/health", (c) => ok(c as unknown as Context<Vars>, { status: "OK", api_version: API_VERSION, instance_name: "moma" }));

  app.get("/v1/auth/config", async (c) => {
    const d = getDeps(c.env);
    const setup_state = await d.gw.getSetupState();
    return ok(c as unknown as Context<Vars>, { project_url: d.cfg.supabaseUrl, publishable_key: d.cfg.publishableKey, setup_state });
  });

  // One-time deployment secret + fixed owner email -> Supabase invite. No public signup.
  app.post("/v1/setup/start", async (c) => {
    const d = getDeps(c.env);
    // Sign-up is open only to the configured owner email; control of that mailbox (emailed code) proves identity.
    const { email } = z.object({ email: z.string().email().max(254) }).parse(await c.req.json().catch(() => ({})));
    if (email.trim().toLowerCase() !== d.cfg.ownerEmail) throw new DomainError("EMAIL_NOT_ALLOWED");
    // Retries by the owner must not be locked out by their own earlier lease: the lease id is derived from the owner email (same holder re-enters; the 15 min expiry still bounds stale state).
    const lease = await leaseIdFor(d.cfg.ownerEmail);
    await rpcSetup(d, "pf_setup_reserve", { p_lease: lease, p_expires: new Date(Date.now() + 15 * 60_000).toISOString() });
    const invite = () =>
      fetch(`${d.cfg.supabaseUrl}/auth/v1/invite`, {
        method: "POST",
        headers: serviceHeaders(d.cfg),
        body: JSON.stringify({ email: d.cfg.ownerEmail }),
        signal: AbortSignal.timeout(10_000),
      });
    let res = await invite();
    if (res.status === 422) {
      // An earlier attempt already created the owner user (it may even have opened the old link): while no owner is
      // bound, replace it so a fresh code is mailed. The reset RPC below refuses once setup is BOUND.
      const stale = await findOwnerAuthUser(d);
      if (stale) {
        await rpcSetup(d, "pf_setup_reset_invite", { p_lease: lease });
        const del = await fetch(`${d.cfg.supabaseUrl}/auth/v1/admin/users/${stale}`, {
          method: "DELETE",
          headers: serviceHeaders(d.cfg),
          signal: AbortSignal.timeout(10_000),
        });
        if (!del.ok) throw new DomainError("TEMPORARY_FAILURE");
        res = await invite();
      }
    }
    if (!res.ok) {
      // Upstream status and error_code only (never the body text, which may echo input).
      const e = (await res.json().catch(() => ({}))) as { error_code?: string };
      console.log(JSON.stringify({ request_id: c.get("rid"), op: "auth.invite", upstream_status: res.status, upstream_code: typeof e.error_code === "string" ? e.error_code : undefined }));
      throw new DomainError("TEMPORARY_FAILURE");
    }
    const user = (await res.json()) as { id?: string };
    if (!user.id) throw new DomainError("TEMPORARY_FAILURE");
    await rpcSetup(d, "pf_setup_record_invite", { p_lease: lease, p_user: user.id });
    return ok(c as unknown as Context<Vars>, { state: "INVITE_PENDING" });
  });

  app.post("/v1/setup/claim", async (c) => {
    const d = getDeps(c.env);
    const session = await d.verifier.verify(c.req.header("authorization"));
    const body = z.object({ display_name: z.string().max(80).default("") }).parse(await c.req.json().catch(() => ({})));
    const profile = await rpcSetup(d, "pf_setup_claim", { p_user: session.userId, p_display_name: body.display_name });
    return ok(c as unknown as Context<Vars>, profile);
  });

  // ------------------------------------------------------------ owner
  app.post("/v1/devices/register", auth, async (c) => {
    const d = getDeps(c.env);
    const body = z.object({ device_id: UUID, label: z.string().min(1).max(80) }).parse(await c.req.json());
    return ok(c as unknown as Context<Vars>, await d.gw.registerDevice(c.get("owner"), c.get("session").sessionId, body.device_id, body.label));
  });

  app.get("/v1/profile", auth, async (c) => ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readProfile(c.get("owner"))));
  app.get("/v1/accounts", auth, async (c) => ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readAccounts(c.get("owner"))));
  app.get("/v1/categories", auth, async (c) => ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readCategories(c.get("owner"))));

  app.get("/v1/transactions", auth, async (c) => {
    const q = z
      .object({ limit: z.coerce.number().int().min(1).max(MAX_PAGE).default(DEFAULT_PAGE), cursor: z.string().max(200).optional() })
      .parse(c.req.query());
    const before = q.cursor ? decodeCursor(q.cursor) : null;
    const rows = (await getDeps(c.env).gw.readTransactions(c.get("owner"), q.limit, before)) as Array<{ effective_at: string; id: string }>;
    const last = rows.length === q.limit ? rows[rows.length - 1] : undefined;
    return ok(c as unknown as Context<Vars>, rows, last ? { next_cursor: encodeCursor(last.effective_at, last.id) } : {});
  });

  app.get("/v1/reports/summary", auth, async (c) => {
    const month = z.object({ month: z.string().default(currentVnMonth(new Date())) }).parse(c.req.query()).month;
    const { from, to } = monthRangeUtc(month);
    return ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readDashboard(c.get("owner"), from, to), { as_of: new Date().toISOString() });
  });

  app.get("/v1/contacts", auth, async (c) => ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readContacts(c.get("owner"))));
  app.get("/v1/debts", auth, async (c) =>
    ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readDebts(c.get("owner"), currentVnDate(new Date()))),
  );
  app.get("/v1/goals", auth, async (c) => ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readGoals(c.get("owner"))));
  app.get("/v1/budgets", auth, async (c) => {
    const month = z.object({ month: z.string().default(currentVnMonth(new Date())) }).parse(c.req.query()).month;
    monthRangeUtc(month); // validates YYYY-MM
    return ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readBudgets(c.get("owner"), `${month}-01`));
  });
  app.get("/v1/recurring", auth, async (c) =>
    ok(c as unknown as Context<Vars>, await getDeps(c.env).gw.readRecurring(c.get("owner"), currentVnDate(new Date()))),
  );

  // ------------------------------------------------------------ AI assistant (proposal only; never writes)
  app.get("/v1/ai/status", auth, async (c) => {
    const d = getDeps(c.env);
    const u = await d.gw.aiUsage(c.get("owner")).catch(() => null);
    return ok(c as unknown as Context<Vars>, { enabled: Boolean(d.ai), provider: "deepseek", model: MODEL, cap_micro: MONTHLY_CAP_MICRO, usage: u });
  });

  app.post("/v1/ai/chat", auth, async (c) => {
    const d = getDeps(c.env);
    if (!d.ai) throw new DomainError("AI_DISABLED");
    needDevice(c);
    const { text } = z.object({ text: z.string().trim().min(1).max(MAX_INPUT_CHARS) }).parse(await c.req.json().catch(() => ({})));
    const owner = c.get("owner");
    const now = new Date();
    const today = currentVnDate(now);
    const accounts = ((await d.gw.readAccounts(owner)) as (AccountRef & { archived?: boolean })[]).filter((a) => !a.archived);
    const categories = (await d.gw.readCategories(owner)) as CategoryRef[];
    const { messages, bytes } = buildMessages(text, today, accounts, categories);
    const est = estimateMicro(bytes);
    // Reserve the worst case first (fails closed at the monthly cap); a provider failure keeps the reservation (spec 05 s5).
    const { id: reservation } = await d.gw.aiReserve(owner, est, MONTHLY_CAP_MICRO, "deepseek", MODEL);
    let out;
    try {
      out = await d.ai(buildRequestBody(messages));
    } catch (e) {
      await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined); // vendor may still bill: keep it counted
      throw e instanceof DomainError ? e : new DomainError("AI_UNAVAILABLE");
    }
    await d.gw.aiSettle(owner, reservation, actualMicro(out.usage));
    const result = resolveOutput(parseModelJson(out.content), { today, nowIso: now.toISOString(), accounts, categories });
    if (result.type === "query_summary") {
      const { from, to } = monthRangeUtc(result.month);
      const summary = await d.gw.readDashboard(owner, from, to);
      return ok(c as unknown as Context<Vars>, { ...result, summary }, { as_of: now.toISOString() });
    }
    return ok(c as unknown as Context<Vars>, result);
  });

  app.post("/v1/commands", auth, async (c) => {
    const d = getDeps(c.env);
    const deviceId = needDevice(c);
    const key = c.req.header("idempotency-key") ?? "";
    const raw: unknown = await c.req.json().catch(() => null);
    if (!UUID.safeParse(key).success || typeof raw !== "object" || raw === null) throw new DomainError("VALIDATION_FAILED");
    const type = (raw as { command_type?: unknown }).command_type;
    if (typeof type !== "string") throw new DomainError("VALIDATION_FAILED");
    const parsed = implementedCommand.safeParse(raw);
    if (!parsed.success) {
      // Catalogued-but-unbuilt command types are explicit NOT_IMPLEMENTED; malformed or unknown input is a validation error.
      const unbuilt = KNOWN_TYPES.has(type) && !IMPLEMENTED_TYPES.has(type);
      throw new DomainError(unbuilt ? "NOT_IMPLEMENTED" : "VALIDATION_FAILED");
    }
    if (parsed.data.command_id !== key) throw new DomainError("VALIDATION_FAILED");
    const ctx: CommandContext = { ownerId: c.get("owner"), sessionId: c.get("session").sessionId, deviceId };
    const hash = await sha256Hex(canonicalJson({ owner: ctx.ownerId, command: parsed.data }));
    return ok(c as unknown as Context<Vars>, await d.gw.executeCommand(ctx, key, hash, parsed.data));
  });

  return app;
}

// Returns the auth user id registered for the owner email, if any. Only ever used while setup is not BOUND:
// pf_setup_reset_invite refuses to run once an owner is bound, so a real owner account can never be replaced.
async function findOwnerAuthUser(d: Deps): Promise<string | undefined> {
  const r = await fetch(`${d.cfg.supabaseUrl}/auth/v1/admin/users?per_page=200`, {
    headers: serviceHeaders(d.cfg),
    signal: AbortSignal.timeout(10_000),
  });
  if (!r.ok) return undefined;
  const body = (await r.json()) as { users?: { id: string; email?: string }[] };
  return (body.users ?? []).find((x) => x.email?.toLowerCase() === d.cfg.ownerEmail)?.id;
}

async function leaseIdFor(seed: string): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`moma-setup-lease:${seed}`)));
  h[6] = (h[6]! & 0x0f) | 0x50; // version 5-style
  h[8] = (h[8]! & 0x3f) | 0x80;
  const x = [...h.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}

async function rpcSetup(d: Deps, name: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${d.cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(d.cfg),
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(d.cfg.dbTimeoutMs),
  });
  if (!res.ok) {
    const b = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
    throw new DomainError(b.code === "P0001" && b.message ? b.message : "DB_ERROR");
  }
  return res.json();
}

// Logs never carry raw error text: only our own CONFIG_* markers (key names, no values) or the error class.
function safeDetail(err: Error): string | undefined {
  if (err instanceof DomainError) return undefined;
  return /^CONFIG_(MISSING|WEAK):[A-Z_]+$/.test(err.message) ? err.message : err.name;
}

function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

function encodeCursor(at: string, id: string): string {
  return btoa(JSON.stringify({ at, id })).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
function decodeCursor(s: string): { at: string; id: string } {
  try {
    const o = z.object({ at: z.string().datetime({ offset: true }), id: UUID }).parse(JSON.parse(atob(s.replaceAll("-", "+").replaceAll("_", "/"))));
    return o;
  } catch {
    throw new DomainError("VALIDATION_FAILED");
  }
}

const app = buildApp();
export default app;
