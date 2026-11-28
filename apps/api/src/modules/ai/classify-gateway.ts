import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { ClassifyExample, ClassifyMethod } from "./classify";

// Server-only RPCs of migration 015 (automatic categorization). Same transport and error mapping as the other gateways.
export interface ClassifyCandidate {
  id: string;
  kind: string;
  amount: string;
  effective_at: string;
  note: string | null;
  merchant: string | null;
  source: string;
  version: number;
  category_id: string | null;
  institution: string | null;
  account_name: string | null;
  account_kind: string | null;
}
export interface ClassifyTxFacts {
  id: string;
  kind: string;
  note: string | null;
  merchant: string | null;
  source: string;
  category_id: string | null;
  category: string | null;
  category_type: string | null;
  previous: { status: string; category_id: string | null; method: string } | null;
}
export interface ClassifyRecord {
  tx: string;
  categoryId: string | null;
  merchant: string | null;
  confidence: number;
  method: ClassifyMethod | "RULE";
  reason: string;
  apply: boolean;
}

export interface ClassifyGateway {
  candidates(owner: string, limit: number, tx?: string): Promise<ClassifyCandidate[]>;
  examples(owner: string, limit: number): Promise<ClassifyExample[]>;
  record(owner: string, r: ClassifyRecord): Promise<{ status: "APPLIED" | "SUGGESTED" | "SKIPPED" }>;
  txFacts(owner: string, tx: string): Promise<ClassifyTxFacts>;
  pending(owner: string, limit: number, unnotified?: boolean): Promise<{ total: number; items: unknown[] }>;
  markNotified(owner: string, ids: string[]): Promise<number>;
}

export class SupabaseClassifyGateway implements ClassifyGateway {
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

  candidates(owner: string, limit: number, tx?: string) {
    return this.rpc<ClassifyCandidate[]>("pf_ai_classify_candidates", { p_owner: owner, p_limit: limit, p_tx: tx ?? null });
  }
  examples(owner: string, limit: number) {
    return this.rpc<ClassifyExample[]>("pf_ai_classify_examples", { p_owner: owner, p_limit: limit });
  }
  record(owner: string, r: ClassifyRecord) {
    return this.rpc<{ status: "APPLIED" | "SUGGESTED" | "SKIPPED" }>("pf_ai_classify_record", {
      p_owner: owner,
      p_tx: r.tx,
      p_category: r.categoryId,
      p_merchant: r.merchant,
      p_confidence: r.confidence,
      p_method: r.method,
      p_reason: r.reason.slice(0, 300),
      p_apply: r.apply,
    });
  }
  txFacts(owner: string, tx: string) {
    return this.rpc<ClassifyTxFacts>("pf_ai_classify_tx", { p_owner: owner, p_tx: tx });
  }
  pending(owner: string, limit: number, unnotified = false) {
    return this.rpc<{ total: number; items: unknown[] }>("pf_ai_classify_pending", { p_owner: owner, p_limit: limit, p_unnotified: unnotified });
  }
  markNotified(owner: string, ids: string[]) {
    return this.rpc<number>("pf_ai_classify_mark_notified", { p_owner: owner, p_ids: ids });
  }
}
