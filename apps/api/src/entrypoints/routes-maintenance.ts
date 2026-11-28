import type { Context, Hono } from "hono";
import type { Config } from "../bootstrap/config";
import type { FinanceGateway } from "../modules/ledger/ports";
import { sendPush } from "../modules/push/onesignal";
import { DomainError } from "../shared/errors";
import type { AttachmentBucket } from "./routes-attachments";
import { secretEquals } from "./routes-insights";

// Data lifecycle + capacity (migration 022, D-028). Free tiers only: Supabase Free 500 MB, R2 10 GB, Workers Free.
// The database does the heavy lifting in bounded batches (pf_lifecycle_run); the Worker only waits on it, so each
// tick stays far under the 10 ms CPU limit. The GitHub Actions maintenance job calls /v1/internal/maintenance daily
// and loops batches until nothing is left; the Cloudflare cron does one batch at night as a fallback.

export const DB_LIMIT_BYTES = 500 * 1024 * 1024; // Supabase Free: 500 MB per project
export const R2_LIMIT_BYTES = 10 * 1024 * 1024 * 1024; // R2 free: 10 GB-month
export const WARN_LEVELS = [60, 80] as const;
const R2_PAGE = 200;
/** Workers Free allows ~50 subrequests per invocation: bound every loop (RPC calls + R2 deletes) well under it. */
const MAX_R2_DELETES_PER_PAGE = 15;
export const INTERNAL_MAX_PASSES = 15;
const INTERNAL_R2_PAGES = 2;
const ORPHAN_MIN_AGE_MS = 24 * 3_600_000; // an upload whose row is still being written is never an orphan

export interface MaintenanceDeps {
  cfg: Config;
  gw: FinanceGateway;
  pushFetch?: typeof fetch;
  /** Injectable for tests; defaults to PostgREST RPC calls. */
  lg?: MaintenanceGateway;
}

export interface LifecycleResult {
  tables: Record<string, number>;
  month_stats: number;
  months: number;
  more: boolean;
  at?: string;
}

export interface CapacityRecord {
  week: string;
  db_bytes: number;
  pct: number;
  warn: number;
}

export interface CapacityReport {
  db_bytes: number;
  top: { table: string; bytes: number; rows: number }[];
  r2_bytes: number;
  attachments: number;
  tx_count: number;
  history: { week: string; db_bytes: number; r2_bytes: number }[];
  ai: {
    this_month_micro_usd: number;
    this_month_calls?: number;
    by_feature?: { feature: string; calls: number; micro_usd: number }[];
    months: { period: string; micro_usd: number }[];
  };
  last_run_at: string | null;
  last_result: Partial<LifecycleResult>;
  runs: number;
  r2_swept_at: string | null;
}

export interface MaintenanceGateway {
  run(owner: string): Promise<LifecycleResult>;
  record(owner: string, limitBytes: number): Promise<CapacityRecord>;
  report(owner: string): Promise<CapacityReport>;
  orphans(owner: string, keys: string[]): Promise<string[]>;
  r2Cursor(owner: string, cursor: string | null, done: boolean): Promise<unknown>;
  state(owner: string): Promise<{ r2_cursor?: string | null; r2_swept_at?: string | null }>;
  pushClaim(owner: string, key: string): Promise<boolean>;
}

export class SupabaseMaintenanceGateway implements MaintenanceGateway {
  constructor(private readonly cfg: Config) {}
  private async rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const res = await fetch(`${this.cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey: this.cfg.serviceRoleKey, authorization: `Bearer ${this.cfg.serviceRoleKey}`, "content-type": "application/json" },
      body: JSON.stringify(args),
      // A cleanup batch may take longer than an ordinary read.
      signal: AbortSignal.timeout(Math.max(this.cfg.dbTimeoutMs, 20_000)),
    });
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
      if (body.code !== "P0001") console.log(JSON.stringify({ op: "rpc_failed", rpc: name, status: res.status, pg: body.code ?? null }));
      throw new DomainError(body.code === "P0001" && body.message ? body.message : "DB_ERROR");
    }
    return (await res.json()) as T;
  }
  run(owner: string) {
    return this.rpc<LifecycleResult>("pf_lifecycle_run", { p_owner: owner });
  }
  record(owner: string, limitBytes: number) {
    return this.rpc<CapacityRecord>("pf_capacity_record", { p_owner: owner, p_limit_bytes: limitBytes });
  }
  report(owner: string) {
    return this.rpc<CapacityReport>("pf_capacity_report", { p_owner: owner });
  }
  orphans(owner: string, keys: string[]) {
    return this.rpc<string[]>("pf_lifecycle_r2_orphans", { p_owner: owner, p_keys: keys });
  }
  r2Cursor(owner: string, cursor: string | null, done: boolean) {
    return this.rpc("pf_lifecycle_r2_cursor", { p_owner: owner, p_cursor: cursor, p_done: done });
  }
  state(owner: string) {
    return this.rpc<{ r2_cursor?: string | null; r2_swept_at?: string | null }>("pf_lifecycle_state_get", { p_owner: owner });
  }
  pushClaim(owner: string, key: string) {
    return this.rpc<boolean>("pf_push_log_claim", { p_owner: owner, p_key: key });
  }
}

const lgOf = (d: MaintenanceDeps): MaintenanceGateway => d.lg ?? new SupabaseMaintenanceGateway(d.cfg);

// ---------------------------------------------------------------- projection (pure)
export interface Projection {
  /** Average growth of the database per month (bytes), from the last ~3 months of weekly snapshots; null = not enough data. */
  growth_per_month: number | null;
  /** Months until the database reaches 80% / 100% of the limit; null = not growing (or unknown). */
  months_to_80: number | null;
  months_to_full: number | null;
  /** "Đủ dùng ~N năm" style label for the app. */
  label: string;
  pct: number;
}

const WEEK_MS = 7 * 86_400_000;
const MONTH_MS = 30.44 * 86_400_000;

/**
 * Least-squares slope of database size over the snapshots of the last 13 weeks (at least 3 snapshots spanning 2+
 * weeks), converted to bytes per month. A shrinking or flat database (after cleanups) projects "no limit in sight".
 */
export function projectCapacity(history: { week: string; db_bytes: number }[], currentBytes: number, limitBytes = DB_LIMIT_BYTES): Projection {
  const pct = limitBytes > 0 ? Math.round((1000 * currentBytes) / limitBytes) / 10 : 0;
  const pts = history
    .map((h) => ({ t: Date.parse(`${h.week}T00:00:00Z`), y: Number(h.db_bytes) }))
    .filter((p) => Number.isFinite(p.t) && Number.isFinite(p.y))
    .sort((a, b) => a.t - b.t);
  const last = pts.at(-1);
  const recent = last ? pts.filter((p) => p.t >= last.t - 13 * WEEK_MS) : [];
  let growth: number | null = null;
  if (recent.length >= 3 && recent.at(-1)!.t - recent[0]!.t >= 2 * WEEK_MS) {
    const n = recent.length;
    const mt = recent.reduce((s, p) => s + p.t, 0) / n;
    const my = recent.reduce((s, p) => s + p.y, 0) / n;
    const num = recent.reduce((s, p) => s + (p.t - mt) * (p.y - my), 0);
    const den = recent.reduce((s, p) => s + (p.t - mt) ** 2, 0);
    growth = den > 0 ? Math.round((num / den) * MONTH_MS) : null;
  }
  const monthsTo = (target: number): number | null => {
    if (growth === null || growth <= 0) return null;
    if (currentBytes >= target) return 0;
    return Math.round(((target - currentBytes) / growth) * 10) / 10;
  };
  const m80 = monthsTo(0.8 * limitBytes);
  const mFull = monthsTo(limitBytes);
  return { growth_per_month: growth, months_to_80: m80, months_to_full: mFull, label: projectionLabel(growth, m80, pct), pct };
}

export function projectionLabel(growth: number | null, months80: number | null, pct: number): string {
  if (pct >= 80) return "Đã dùng trên 80% dung lượng: cần dọn dẹp hoặc lưu trữ năm cũ";
  if (growth === null) return "Chưa đủ dữ liệu để dự báo (cần vài tuần)";
  if (months80 === null) return "Dung lượng không tăng: đủ dùng lâu dài";
  if (months80 >= 24) return `Đủ dùng ~${Math.floor(months80 / 12)} năm nữa`;
  if (months80 >= 1) return `Đủ dùng ~${Math.round(months80)} tháng nữa`;
  return "Sắp chạm 80% dung lượng";
}

// ---------------------------------------------------------------- jobs
const vnClock = (now: Date) => {
  const v = new Date(now.getTime() + 7 * 3_600_000);
  return { day: v.getUTCDay(), date: v.getUTCDate(), minutes: v.getUTCHours() * 60 + v.getUTCMinutes(), iso: v.toISOString().slice(0, 10) };
};

/** Runs lifecycle batches until nothing is left (or maxPasses). */
export async function runLifecycle(d: MaintenanceDeps, owner: string, maxPasses = 1): Promise<{ passes: number; totals: Record<string, number>; month_stats: number; more: boolean }> {
  const lg = lgOf(d);
  const totals: Record<string, number> = {};
  let month_stats = 0;
  let more = false;
  let passes = 0;
  for (; passes < maxPasses; ) {
    const r = await lg.run(owner);
    passes++;
    for (const [k, v] of Object.entries(r.tables ?? {})) totals[k] = (totals[k] ?? 0) + Number(v);
    month_stats += Number(r.month_stats ?? 0);
    more = Boolean(r.more);
    if (!more) break;
  }
  return { passes, totals, month_stats, more };
}

/** Weekly snapshot + one push (and inbox item) the first time the database crosses 60% / 80%. */
export async function recordCapacity(d: MaintenanceDeps, owner: string): Promise<CapacityRecord> {
  const lg = lgOf(d);
  const rec = await lg.record(owner, DB_LIMIT_BYTES);
  if (rec.warn > 0 && (await lg.pushClaim(owner, `capacity:${rec.warn}:${rec.week}`))) {
    const free = rec.warn >= 80;
    await sendPush(d.cfg, d.pushFetch ?? fetch, {
      ownerId: owner,
      title: `Dữ liệu đã dùng ${Math.round(rec.pct)}% dung lượng miễn phí`,
      body: free
        ? "MoMa đã dọn bớt dữ liệu phụ. Mở Dung lượng & chi phí để lưu trữ năm cũ sang kho ảnh (miễn phí)."
        : "Vẫn còn nhiều chỗ. MoMa tự dọn dữ liệu phụ mỗi đêm; bạn xem chi tiết trong Cài đặt.",
      data: { type: "capacity", route: "/settings/capacity" },
      androidGroup: "moma_system",
    });
  }
  return rec;
}

/**
 * One page of the R2 orphan sweep: lists keys under the owner's prefix, deletes those no attachment row uses and
 * that are older than a day. The cursor is kept in the database so the next call continues; a finished pass stamps
 * r2_swept_at. Returns the number of deleted objects (0 when the bucket cannot list).
 */
export async function sweepR2Page(d: MaintenanceDeps, owner: string, bucket: AttachmentBucket | undefined, now = new Date()): Promise<{ listed: number; deleted: number; done: boolean }> {
  if (!bucket?.list) return { listed: 0, deleted: 0, done: true };
  const lg = lgOf(d);
  const st = await lg.state(owner);
  const page = await bucket.list({ prefix: `${owner}/`, limit: R2_PAGE, ...(st.r2_cursor ? { cursor: st.r2_cursor } : {}) });
  const keys = page.objects.map((o) => o.key);
  const orphanSet = new Set(keys.length ? await lg.orphans(owner, keys) : []);
  let deleted = 0;
  let capped = false;
  for (const o of page.objects) {
    if (!orphanSet.has(o.key)) continue;
    if (deleted >= MAX_R2_DELETES_PER_PAGE) {
      capped = true; // same page again next time, so no orphan is skipped
      break;
    }
    if (o.uploaded && now.getTime() - new Date(o.uploaded).getTime() < ORPHAN_MIN_AGE_MS) continue;
    try {
      await bucket.delete(o.key);
      deleted++;
    } catch (e) {
      console.log(JSON.stringify({ op: "r2_orphan_delete_failed", error: String(e).slice(0, 120) }));
    }
  }
  if (capped) return { listed: keys.length, deleted, done: false };
  const done = !page.truncated;
  await lg.r2Cursor(owner, done ? null : (page.cursor ?? null), done);
  return { listed: keys.length, deleted, done };
}

/**
 * Cron hook (every 15 minutes, never throws). Vietnam time:
 *   03:30-03:59 every night: one lifecycle batch per tick (fallback for the GitHub Actions job);
 *   Monday 04:00-04:14: weekly capacity snapshot (+ 60/80% warning);
 *   days 1-7 of the month 04:15-04:59: one R2 orphan page per tick.
 */
export async function runMaintenance(d: MaintenanceDeps, now: Date, bucket?: AttachmentBucket): Promise<string[]> {
  const done: string[] = [];
  try {
    const owner = await d.gw.getOwnerId();
    if (!owner) return done;
    const c = vnClock(now);
    if (c.minutes >= 210 && c.minutes < 240) {
      await runLifecycle(d, owner, 1);
      done.push("lifecycle");
    }
    if (c.day === 1 && c.minutes >= 240 && c.minutes < 255) {
      await recordCapacity(d, owner);
      done.push("capacity");
    }
    if (c.date <= 7 && c.minutes >= 255 && c.minutes < 300) {
      await sweepR2Page(d, owner, bucket, now);
      done.push("r2");
    }
  } catch (e) {
    console.log(JSON.stringify({ op: "maintenance", outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
  }
  return done;
}

// ---------------------------------------------------------------- routes
function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}

export function registerMaintenanceRoutes(
  app: Hono<any>,
  getDeps: (env: any) => MaintenanceDeps,
  getBucket: (env: any) => AttachmentBucket | undefined,
  auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>,
) {
  // Capacity & cost screen.
  app.get("/v1/system/capacity", auth, async (c) => {
    const d = getDeps(c.env);
    const r = await lgOf(d).report((c as any).get("owner"));
    return ok(c, {
      ...r,
      db_limit_bytes: DB_LIMIT_BYTES,
      r2_limit_bytes: R2_LIMIT_BYTES,
      projection: projectCapacity(r.history ?? [], Number(r.db_bytes), DB_LIMIT_BYTES),
    });
  });

  // "Dọn dẹp ngay": one bounded batch (more = true means the nightly job will continue).
  app.post("/v1/system/cleanup", auth, async (c) => {
    const d = getDeps(c.env);
    return ok(c, await runLifecycle(d, (c as any).get("owner"), 1));
  });

  // Daily heavy run from GitHub Actions (free minutes): every batch until done, the capacity snapshot and a few R2
  // pages. Guarded by the cron secret like /v1/internal/tick.
  app.post("/v1/internal/maintenance", async (c) => {
    const d = getDeps(c.env);
    if (!d.cfg.cronSecret) throw new DomainError("NOT_FOUND");
    if (!(await secretEquals(c.req.header("x-cron-secret") ?? "", d.cfg.cronSecret))) throw new DomainError("UNAUTHENTICATED");
    const owner = await d.gw.getOwnerId();
    if (!owner) return ok(c, { owner: false });
    const lifecycle = await runLifecycle(d, owner, INTERNAL_MAX_PASSES);
    const capacity = await recordCapacity(d, owner);
    let r2 = { listed: 0, deleted: 0, done: true };
    const bucket = getBucket(c.env);
    for (let i = 0; i < INTERNAL_R2_PAGES; i++) {
      const p = await sweepR2Page(d, owner, bucket);
      r2 = { listed: r2.listed + p.listed, deleted: r2.deleted + p.deleted, done: p.done };
      if (p.done) break;
    }
    return ok(c, { lifecycle, capacity, r2 });
  });
}
