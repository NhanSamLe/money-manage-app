export interface Env {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  /** Deprecated (ADR D-012): sign-up is gated by OWNER_EMAIL + emailed code; kept only so old deployments still load. */
  BOOTSTRAP_SECRET?: string;
  /** Optional: DeepSeek API key for the AI assistant. Absent => AI is OFF (rules + manual only). */
  DEEPSEEK_API_KEY?: string;
  /** SePay API token (userapi.sepay.vn/v2): lists verified bank accounts and polls transactions. */
  SEPAY_API_TOKEN?: string;
  /** Shared key SePay sends as `Authorization: Apikey <key>` with every webhook. */
  SEPAY_WEBHOOK_KEY?: string;
  /** Alternative: SePay HMAC-SHA256 webhook secret. */
  SEPAY_WEBHOOK_SECRET?: string;
  OWNER_EMAIL: string;
  /** Optional: only for legacy Supabase projects that still sign tokens with a shared HS256 secret. */
  SUPABASE_JWT_SECRET?: string;
  /** OneSignal App ID (public). Defaults to the MoMa app. */
  ONESIGNAL_APP_ID?: string;
  /** OneSignal REST API key. Absent => push notifications are OFF. */
  ONESIGNAL_REST_KEY?: string;
  /** Optional: shared secret for POST /v1/internal/tick (external scheduler fallback). Absent => endpoint is 404. */
  CRON_SECRET?: string;
  /** R2 bucket moma-attachments (receipt pictures). Absent => attachments return STORAGE_UNAVAILABLE. */
  ATTACHMENTS?: import("../entrypoints/routes-attachments").AttachmentBucket;
}

export interface Config {
  supabaseUrl: string;
  publishableKey: string;
  serviceRoleKey: string;
  bootstrapSecret?: string;
  deepseekKey?: string;
  sepayToken?: string;
  sepayWebhookKey?: string;
  sepayWebhookSecret?: string;
  ownerEmail: string;
  jwtSecret?: string;
  /** OneSignal App ID (always set; defaults to the MoMa app). */
  onesignalAppId?: string;
  /** Undefined => push is OFF. */
  onesignalRestKey?: string;
  /** Undefined => POST /v1/internal/tick is disabled (404). */
  cronSecret?: string;
  dbTimeoutMs: number;
}

export const DEFAULT_ONESIGNAL_APP_ID = "fce35790-4bdd-420a-aedb-0d41593e7894";

// New-style secret keys (sb_secret_...) are not JWTs and must go in `apikey` only; legacy service_role JWTs need both headers.
export function serviceHeaders(cfg: Pick<Config, "serviceRoleKey">): Record<string, string> {
  const h: Record<string, string> = { apikey: cfg.serviceRoleKey, "content-type": "application/json" };
  if (!cfg.serviceRoleKey.startsWith("sb_secret_")) h["authorization"] = `Bearer ${cfg.serviceRoleKey}`;
  return h;
}

const DB_TIMEOUT_MS = 5_000;

// Fail closed: any missing or placeholder secret aborts the request.
export function loadConfig(env: Env): Config {
  const need = (k: Exclude<keyof Env, "ATTACHMENTS">): string => {
    const v = env[k];
    if (!v || v.startsWith("REPLACE") || v.includes("PROJECT_REF")) throw new Error(`CONFIG_MISSING:${k}`);
    return v;
  };
  return {
    supabaseUrl: need("SUPABASE_URL").replace(/\/$/, ""),
    publishableKey: need("SUPABASE_PUBLISHABLE_KEY"),
    serviceRoleKey: need("SUPABASE_SERVICE_ROLE_KEY"),
    ownerEmail: need("OWNER_EMAIL").toLowerCase(),
    ...(env.SEPAY_API_TOKEN ? { sepayToken: env.SEPAY_API_TOKEN } : {}),
    ...(env.SEPAY_WEBHOOK_KEY ? { sepayWebhookKey: env.SEPAY_WEBHOOK_KEY } : {}),
    ...(env.SEPAY_WEBHOOK_SECRET ? { sepayWebhookSecret: env.SEPAY_WEBHOOK_SECRET } : {}),
    ...(env.DEEPSEEK_API_KEY ? { deepseekKey: env.DEEPSEEK_API_KEY } : {}),
    ...(env.SUPABASE_JWT_SECRET ? { jwtSecret: env.SUPABASE_JWT_SECRET } : {}),
    onesignalAppId: env.ONESIGNAL_APP_ID || DEFAULT_ONESIGNAL_APP_ID,
    ...(env.ONESIGNAL_REST_KEY ? { onesignalRestKey: env.ONESIGNAL_REST_KEY } : {}),
    ...(env.CRON_SECRET ? { cronSecret: env.CRON_SECRET } : {}),
    dbTimeoutMs: DB_TIMEOUT_MS,
  };
}
