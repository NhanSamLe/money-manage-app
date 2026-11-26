export interface Env {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  BOOTSTRAP_SECRET: string;
  OWNER_EMAIL: string;
}

export interface Config {
  supabaseUrl: string;
  publishableKey: string;
  serviceRoleKey: string;
  bootstrapSecret: string;
  ownerEmail: string;
  dbTimeoutMs: number;
}

// New-style secret keys (sb_secret_...) are not JWTs and must go in `apikey` only; legacy service_role JWTs need both headers.
export function serviceHeaders(cfg: Pick<Config, "serviceRoleKey">): Record<string, string> {
  const h: Record<string, string> = { apikey: cfg.serviceRoleKey, "content-type": "application/json" };
  if (!cfg.serviceRoleKey.startsWith("sb_secret_")) h["authorization"] = `Bearer ${cfg.serviceRoleKey}`;
  return h;
}

const DB_TIMEOUT_MS = 5_000;
const MIN_BOOTSTRAP_SECRET_LEN = 32;

// Fail closed: any missing or placeholder secret aborts the request.
export function loadConfig(env: Env): Config {
  const need = (k: keyof Env): string => {
    const v = env[k];
    if (!v || v.startsWith("REPLACE") || v.includes("PROJECT_REF")) throw new Error(`CONFIG_MISSING:${k}`);
    return v;
  };
  const bootstrapSecret = need("BOOTSTRAP_SECRET");
  if (bootstrapSecret.length < MIN_BOOTSTRAP_SECRET_LEN) throw new Error("CONFIG_WEAK:BOOTSTRAP_SECRET");
  return {
    supabaseUrl: need("SUPABASE_URL").replace(/\/$/, ""),
    publishableKey: need("SUPABASE_PUBLISHABLE_KEY"),
    serviceRoleKey: need("SUPABASE_SERVICE_ROLE_KEY"),
    bootstrapSecret,
    ownerEmail: need("OWNER_EMAIL").toLowerCase(),
    dbTimeoutMs: DB_TIMEOUT_MS,
  };
}
