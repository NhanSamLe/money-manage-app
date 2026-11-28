import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";

// Server-only RPCs of migration 010 (pairing own-account transfers). The matching rules live in SQL
// (pf_private.try_pair_transfer); this port only moves requests and results.

export type PairState = "AUTO" | "CONFIRMED" | "REJECTED" | "SUGGESTED";

export interface TransferLeg {
  tx_id: string;
  kind: string;
  status: string;
  amount: string;
  effective_at: string;
  note: string | null;
  merchant: string | null;
  source: string;
  account_id: string;
  account_name: string;
  institution: string;
  account_kind: string;
  last4: string | null;
}

export interface TransferPair {
  id: string;
  state: PairState;
  score: number;
  hints: string[];
  created_at: string;
  /** Null when that side was synthesized (one-leg transfer, e.g. MoMo never notifies money out). */
  out: TransferLeg | null;
  in: TransferLeg | null;
  /** The own account on the synthesized side of a one-leg transfer. */
  synth_account?: { account_id: string; account_name: string; institution: string; account_kind: string } | null;
  transfer_tx_id?: string | null;
  decided_at?: string | null;
  can_undo?: boolean;
}

export interface PairResult {
  /** ABSORBED: the late missing leg of a one-leg transfer was attached to it. */
  status: "NONE" | "AUTO" | "SUGGESTED" | "ABSORBED";
  /** SAME_PAYMENT: the result is a duplicate merge / suggestion (migration 018), not an own-account transfer. */
  kind?: "SAME_PAYMENT";
  same_id?: string;
  keep_tx_id?: string;
  pair_id?: string;
  transfer_tx_id?: string;
  suggested?: number;
}

export interface SweepResult {
  checked: number;
  auto: number;
  suggested: number;
  failed: number;
}

/** One payment seen twice (migration 018): `keep` stays, `dup` is merged into it. */
export interface SamePayment {
  id: string;
  state: PairState;
  score: number;
  hints: string[];
  created_at: string;
  decided_at?: string | null;
  keep: TransferLeg | null;
  dup: TransferLeg | null;
  can_undo: boolean;
}

export interface SamePaymentGateway {
  duplicateSuggestions(owner: string): Promise<SamePayment[]>;
  duplicateDecide(owner: string, id: string, accept: boolean): Promise<{ id: string; state: PairState; keep_tx_id?: string }>;
  duplicateUndo(owner: string, id: string): Promise<{ id: string; state: PairState; keep_tx_id: string; restored_tx_id: string }>;
  duplicateForTx(owner: string, txId: string): Promise<SamePayment | null>;
}

export interface TransferGateway extends SamePaymentGateway {
  tryPair(owner: string, txId: string): Promise<PairResult>;
  sweep(owner: string, hours: number): Promise<SweepResult>;
  suggestions(owner: string): Promise<TransferPair[]>;
  decide(owner: string, pairId: string, accept: boolean): Promise<{ pair_id: string; state: PairState; transfer_tx_id?: string }>;
  undo(owner: string, pairId: string): Promise<{ pair_id: string; state: PairState; voided_transfer_tx_id: string; out_tx_id: string | null; in_tx_id: string | null }>;
  pairForTx(owner: string, txId: string): Promise<TransferPair | null>;
}

export class SupabaseTransferGateway implements TransferGateway {
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

  tryPair(owner: string, txId: string) {
    return this.rpc<PairResult>("pf_transfer_try_pair", { p_owner: owner, p_tx: txId });
  }
  sweep(owner: string, hours: number) {
    return this.rpc<SweepResult>("pf_transfer_sweep", { p_owner: owner, p_hours: hours });
  }
  suggestions(owner: string) {
    return this.rpc<TransferPair[]>("pf_transfer_suggestions", { p_owner: owner });
  }
  decide(owner: string, pairId: string, accept: boolean) {
    return this.rpc<{ pair_id: string; state: PairState; transfer_tx_id?: string }>("pf_transfer_decide", { p_owner: owner, p_pair: pairId, p_accept: accept });
  }
  undo(owner: string, pairId: string) {
    return this.rpc<{ pair_id: string; state: PairState; voided_transfer_tx_id: string; out_tx_id: string | null; in_tx_id: string | null }>("pf_transfer_undo", {
      p_owner: owner,
      p_pair: pairId,
    });
  }
  pairForTx(owner: string, txId: string) {
    return this.rpc<TransferPair | null>("pf_transfer_pair_for_tx", { p_owner: owner, p_tx: txId });
  }
  duplicateSuggestions(owner: string) {
    return this.rpc<SamePayment[]>("pf_same_payment_suggestions", { p_owner: owner });
  }
  duplicateDecide(owner: string, id: string, accept: boolean) {
    return this.rpc<{ id: string; state: PairState; keep_tx_id?: string }>("pf_same_payment_decide", { p_owner: owner, p_id: id, p_accept: accept });
  }
  duplicateUndo(owner: string, id: string) {
    return this.rpc<{ id: string; state: PairState; keep_tx_id: string; restored_tx_id: string }>("pf_same_payment_undo", { p_owner: owner, p_id: id });
  }
  duplicateForTx(owner: string, txId: string) {
    return this.rpc<SamePayment | null>("pf_same_payment_for_tx", { p_owner: owner, p_tx: txId });
  }
}
