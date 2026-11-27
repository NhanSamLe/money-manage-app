import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { PeriodStats } from "../insights/analysis";
import type { DayStatus, Period } from "./schedule";

// Server-only RPCs of migration 008 (reminders, push log, insights, period stats). Same transport and error mapping
// as SupabaseFinanceGateway.
export interface RemindersGateway {
  settingsRead(owner: string): Promise<unknown>;
  settingsWrite(owner: string, settings: unknown): Promise<unknown>;
  dayStatus(owner: string, day: string): Promise<DayStatus>;
  skipSet(owner: string, kind: string, day: string, on: boolean): Promise<DayStatus>;
  pushClaim(owner: string, key: string): Promise<boolean>;
  insightCreate(owner: string, period: Period, start: string, end: string, payload: unknown): Promise<Record<string, unknown>>;
  insightList(owner: string, period: Period | null, limit: number): Promise<Record<string, unknown>[]>;
  insightGet(owner: string, id: string): Promise<Record<string, unknown>>;
  insightLatest(owner: string, period: Period): Promise<Record<string, unknown> | null>;
  periodStats(owner: string, from: string, to: string): Promise<PeriodStats>;
}

export class SupabaseRemindersGateway implements RemindersGateway {
  constructor(private readonly cfg: Config) {}

  private async rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const res = await fetch(`${this.cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: serviceHeaders(this.cfg),
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(this.cfg.dbTimeoutMs),
    });
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { code?: string; message?: string };
      if (body.code !== "P0001") console.log(JSON.stringify({ op: "rpc_failed", rpc: name, status: res.status, pg: body.code ?? null }));
      throw new DomainError(body.code === "P0001" && body.message ? body.message : "DB_ERROR");
    }
    return (await res.json()) as T;
  }

  settingsRead(owner: string) {
    return this.rpc<unknown>("pf_reminder_settings_read", { p_owner: owner });
  }
  settingsWrite(owner: string, settings: unknown) {
    return this.rpc<unknown>("pf_reminder_settings_write", { p_owner: owner, p_settings: settings });
  }
  dayStatus(owner: string, day: string) {
    return this.rpc<DayStatus>("pf_reminder_day_status", { p_owner: owner, p_day: day });
  }
  skipSet(owner: string, kind: string, day: string, on: boolean) {
    return this.rpc<DayStatus>("pf_reminder_skip_set", { p_owner: owner, p_kind: kind, p_day: day, p_on: on });
  }
  pushClaim(owner: string, key: string) {
    return this.rpc<boolean>("pf_push_log_claim", { p_owner: owner, p_key: key });
  }
  insightCreate(owner: string, period: Period, start: string, end: string, payload: unknown) {
    return this.rpc<Record<string, unknown>>("pf_insight_create", { p_owner: owner, p_period: period, p_start: start, p_end: end, p_payload: payload });
  }
  insightList(owner: string, period: Period | null, limit: number) {
    return this.rpc<Record<string, unknown>[]>("pf_insight_list", { p_owner: owner, p_period: period, p_limit: limit });
  }
  insightGet(owner: string, id: string) {
    return this.rpc<Record<string, unknown>>("pf_insight_get", { p_owner: owner, p_id: id });
  }
  insightLatest(owner: string, period: Period) {
    return this.rpc<Record<string, unknown> | null>("pf_insight_latest", { p_owner: owner, p_period: period });
  }
  periodStats(owner: string, from: string, to: string) {
    return this.rpc<PeriodStats>("pf_period_stats", { p_owner: owner, p_from: from, p_to: to });
  }
}
