import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { SplitContext } from "./split";

// Server-only RPCs of migration 016 (recurring rules with bill splitting). Ledger work happens in SQL
// (pf_private.cmd_split_apply / cmd_split_undo); this port only moves requests and results.

export interface ApplyShare {
  contact_id?: string | null;
  /** New person (contact created by name, or matched case-insensitively) when contact_id is absent. */
  name?: string | null;
  amount: string;
}

export interface ApplyRequest {
  tx_id: string;
  shares: ApplyShare[];
  category_id?: string | null;
  merchant?: string | null;
  recurring_id?: string | null;
  occurrence_id?: string | null;
  application_id?: string | null;
  source?: "RECURRING" | "BILL" | "MANUAL" | "AI";
  confidence?: number;
  note?: string | null;
  hints?: string[];
}

export interface ProposeRequest extends Omit<ApplyRequest, "shares" | "application_id" | "merchant"> {
  shares: { contact_id: string | null; name: string; amount: string }[];
  owner_amount?: string;
}

export interface MissedOccurrence {
  occurrence_id: string;
  recurring_id: string;
  name: string;
  amount: string;
  due_date: string;
  window_start: number;
  window_end: number;
}

export interface SplitGateway {
  syncOccurrences(owner: string, todayLocal: string): Promise<number>;
  context(owner: string, txId: string): Promise<SplitContext | null>;
  apply(owner: string, req: ApplyRequest): Promise<{ application_id: string; tx_id: string; shares: { contact_id: string; name: string; amount: string; debt_id: string }[]; owner_amount: string }>;
  propose(owner: string, req: ProposeRequest): Promise<{ status: "PROPOSED" | "DISMISSED_BEFORE"; application_id?: string }>;
  undo(owner: string, applicationId: string): Promise<{ application_id: string; state: string; debts_cancelled: number }>;
  dismiss(owner: string, applicationId: string): Promise<{ application_id: string; state: string }>;
  list(owner: string, txId: string | null, state: string | null): Promise<Record<string, unknown>[]>;
  missed(owner: string, todayLocal: string): Promise<MissedOccurrence[]>;
  ruleSuggestions(owner: string): Promise<Record<string, unknown>[]>;
  /** Recent money-out transactions the sweep re-checks (hook failed / rule added after the payment). */
  recentDebits(owner: string, hours: number): Promise<string[]>;
  pushClaim(owner: string, key: string): Promise<boolean>;
  /** Category / merchant / note from a bill photo, set in place. Returns the previous values (for undo). */
  billAnnotate(owner: string, txId: string, p: { category_id?: string | null; merchant?: string | null; note?: string | null }): Promise<BillAnnotateResult>;
}

export interface BillAnnotateResult {
  tx_id: string;
  reclassified: boolean;
  previous: { kind: string; category_id: string | null; merchant: string | null; note: string | null };
}

export class SupabaseSplitGateway implements SplitGateway {
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

  syncOccurrences(owner: string, todayLocal: string) {
    return this.rpc<number>("pf_sync_occurrences", { p_owner: owner, p_today: todayLocal });
  }
  context(owner: string, txId: string) {
    return this.rpc<SplitContext | null>("pf_split_context", { p_owner: owner, p_tx: txId });
  }
  apply(owner: string, req: ApplyRequest) {
    return this.rpc<Awaited<ReturnType<SplitGateway["apply"]>>>("pf_split_apply", { p_owner: owner, p: req });
  }
  propose(owner: string, req: ProposeRequest) {
    return this.rpc<Awaited<ReturnType<SplitGateway["propose"]>>>("pf_split_propose", { p_owner: owner, p: req });
  }
  undo(owner: string, applicationId: string) {
    return this.rpc<Awaited<ReturnType<SplitGateway["undo"]>>>("pf_split_undo", { p_owner: owner, p_application: applicationId });
  }
  dismiss(owner: string, applicationId: string) {
    return this.rpc<Awaited<ReturnType<SplitGateway["dismiss"]>>>("pf_split_dismiss", { p_owner: owner, p_application: applicationId });
  }
  list(owner: string, txId: string | null, state: string | null) {
    return this.rpc<Record<string, unknown>[]>("pf_split_list", { p_owner: owner, p_tx: txId, p_state: state });
  }
  missed(owner: string, todayLocal: string) {
    return this.rpc<MissedOccurrence[]>("pf_split_missed", { p_owner: owner, p_today: todayLocal });
  }
  ruleSuggestions(owner: string) {
    return this.rpc<Record<string, unknown>[]>("pf_split_rule_suggestions", { p_owner: owner });
  }
  recentDebits(owner: string, hours: number) {
    return this.rpc<string[]>("pf_split_recent_debits", { p_owner: owner, p_hours: hours });
  }
  pushClaim(owner: string, key: string) {
    return this.rpc<boolean>("pf_push_log_claim", { p_owner: owner, p_key: key });
  }
  billAnnotate(owner: string, txId: string, p: { category_id?: string | null; merchant?: string | null; note?: string | null }) {
    const args: Record<string, unknown> = {};
    if (p.category_id) args.category_id = p.category_id;
    if (p.merchant) args.merchant = p.merchant;
    if (p.note !== undefined && p.note !== null) args.note = p.note;
    return this.rpc<BillAnnotateResult>("pf_bill_annotate", { p_owner: owner, p_tx: txId, p: args });
  }
}
