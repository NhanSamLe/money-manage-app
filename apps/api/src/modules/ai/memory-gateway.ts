import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { MemoryEntry, MemoryItem, MemoryKind, MemorySource, MemoryWrite, ReflectStats } from "./memory";

// Server-only RPCs of migration 009 (assistant memory). Same transport and error mapping as SupabaseFinanceGateway.
export interface MemoryGateway {
  list(owner: string, kind: MemoryKind | null, limit: number): Promise<MemoryEntry[]>;
  relevant(owner: string, terms: string[], limit: number): Promise<MemoryEntry[]>;
  upsert(owner: string, w: MemoryWrite): Promise<MemoryEntry | null>;
  upsertMany(owner: string, items: MemoryWrite[]): Promise<number>;
  replace(owner: string, kind: MemoryKind, source: MemorySource, items: MemoryItem[]): Promise<number>;
  remove(owner: string, id: string): Promise<unknown>;
  decay(owner: string): Promise<{ decayed: number; dropped: number }>;
  observe(owner: string, type: string, payload: unknown, result: unknown): Promise<{ learned: string | null }>;
  confirmRecent(owner: string): Promise<number>;
  reflectStats(owner: string, days: number): Promise<ReflectStats>;
}

export class SupabaseMemoryGateway implements MemoryGateway {
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

  list(owner: string, kind: MemoryKind | null, limit: number) {
    return this.rpc<MemoryEntry[]>("pf_ai_memory_list", { p_owner: owner, p_kind: kind, p_limit: limit });
  }
  relevant(owner: string, terms: string[], limit: number) {
    return this.rpc<MemoryEntry[]>("pf_ai_memory_relevant", { p_owner: owner, p_terms: terms, p_limit: limit });
  }
  upsert(owner: string, w: MemoryWrite) {
    return this.rpc<MemoryEntry | null>("pf_ai_memory_upsert", {
      p_owner: owner, p_kind: w.kind, p_key: w.key, p_value: w.value, p_source: w.source, p_weight: w.weight ?? null,
    });
  }
  upsertMany(owner: string, items: MemoryWrite[]) {
    return this.rpc<number>("pf_ai_memory_upsert_many", { p_owner: owner, p_items: items });
  }
  replace(owner: string, kind: MemoryKind, source: MemorySource, items: MemoryItem[]) {
    return this.rpc<number>("pf_ai_memory_replace", { p_owner: owner, p_kind: kind, p_source: source, p_items: items });
  }
  remove(owner: string, id: string) {
    return this.rpc<unknown>("pf_ai_memory_delete", { p_owner: owner, p_id: id });
  }
  decay(owner: string) {
    return this.rpc<{ decayed: number; dropped: number }>("pf_ai_memory_decay", { p_owner: owner });
  }
  observe(owner: string, type: string, payload: unknown, result: unknown) {
    return this.rpc<{ learned: string | null }>("pf_ai_observe_command", { p_owner: owner, p_type: type, p_payload: payload, p_result: result });
  }
  confirmRecent(owner: string) {
    return this.rpc<number>("pf_ai_confirm_recent", { p_owner: owner });
  }
  reflectStats(owner: string, days: number) {
    return this.rpc<ReflectStats>("pf_ai_reflect_stats", { p_owner: owner, p_days: days });
  }
}
