import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { GoalPlan, IncomeFacts, ReminderInfo } from "./collect";

// Supabase RPCs of migration 019 (debt collection + goals). Injectable so routes are unit-tested without a database.

export interface SettleJson {
  id: string;
  state: "AUTO" | "CONFIRMED" | "SUGGESTED" | "REJECTED";
  score: number;
  hints: string[];
  amount: string;
  created_at: string;
  repay_tx_id: string | null;
  restored_tx_id: string | null;
  debt: { id: string; direction: "RECEIVABLE" | "PAYABLE"; contact_id: string; contact_alias: string; principal: string; remaining: string; note: string | null; state: string };
  money: { tx_id: string; kind: string; status: string; amount: string; effective_at: string; note: string | null; merchant: string | null; source: string; account_id: string | null; account_name: string | null; institution: string | null };
  can_undo?: boolean;
}

export interface TryResult {
  status: "NONE" | "AUTO" | "SUGGESTED";
  settle_id?: string;
  repay_tx_id?: string;
  debt_id?: string;
  suggested?: number;
}

export interface GoalProposal {
  id: string;
  goal_id: string;
  goal_name: string;
  target: string;
  allocated: string;
  account_id: string;
  account_name: string;
  amount: string;
  reason: "INCOME" | "MONTH_END";
  period: string;
  source_tx: string | null;
  created_at: string;
  available: string;
}

export interface MonthSurplus {
  month: string;
  spent: string;
  baseline: string | null;
  basis: "BUDGET" | "AVERAGE" | null;
  surplus: string | null;
  account_id: string | null;
  account_name: string | null;
  available: string;
}

export interface CollectGateway {
  tryTx(owner: string, txId: string): Promise<TryResult>;
  sweep(owner: string, hours: number): Promise<{ checked: number; auto: number; suggested: number; repaired: number; failed: number }>;
  suggestions(owner: string): Promise<SettleJson[]>;
  forTx(owner: string, txId: string): Promise<SettleJson | null>;
  recentAuto(owner: string, hours: number): Promise<SettleJson[]>;
  decide(owner: string, id: string, accept: boolean): Promise<Record<string, unknown>>;
  undo(owner: string, id: string): Promise<Record<string, unknown>>;
  undoByTx(owner: string, txId: string): Promise<Record<string, unknown> | null>;
  reminder(owner: string, debtId: string, today: string): Promise<ReminderInfo>;
  due(owner: string, today: string): Promise<ReminderInfo[]>;
  markReminded(owner: string, debtId: string): Promise<Record<string, unknown>>;
  snooze(owner: string, debtId: string, until: string): Promise<Record<string, unknown>>;
  contactBank(owner: string, contactId: string, p: { bank?: string | undefined; bin?: string | null | undefined; account_number?: string | undefined; holder?: string | null | undefined }): Promise<Record<string, unknown>>;
  goalPlan(owner: string, today: string): Promise<GoalPlan[]>;
  incomeFacts(owner: string, txId: string): Promise<(IncomeFacts & { note: string | null }) | null>;
  propose(owner: string, p: { goal_id: string; account_id: string; amount: string; reason: "INCOME" | "MONTH_END"; period: string; source_tx?: string }): Promise<{ status: "PROPOSED" | "EXISTS" | "SKIPPED"; id?: string }>;
  proposals(owner: string): Promise<GoalProposal[]>;
  accept(owner: string, id: string): Promise<Record<string, unknown>>;
  dismiss(owner: string, id: string): Promise<Record<string, unknown>>;
  monthSurplus(owner: string, month: string): Promise<MonthSurplus>;
  milestones(owner: string): Promise<{ goal_id: string; name: string; pct: number; target: string; allocated: string }[]>;
  pushClaim(owner: string, key: string): Promise<boolean>;
  /** Original money back for repayments undone elsewhere (DEBT_PAYMENT_REVERSE / DEBT_CANCEL). */
  repair(owner: string): Promise<number>;
}

export class SupabaseCollectGateway implements CollectGateway {
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

  tryTx(owner: string, txId: string) {
    return this.rpc<TryResult>("pf_collect_try", { p_owner: owner, p_tx: txId });
  }
  sweep(owner: string, hours: number) {
    return this.rpc<Awaited<ReturnType<CollectGateway["sweep"]>>>("pf_collect_sweep", { p_owner: owner, p_hours: hours });
  }
  suggestions(owner: string) {
    return this.rpc<SettleJson[]>("pf_collect_suggestions", { p_owner: owner });
  }
  forTx(owner: string, txId: string) {
    return this.rpc<SettleJson | null>("pf_collect_for_tx", { p_owner: owner, p_tx: txId });
  }
  recentAuto(owner: string, hours: number) {
    return this.rpc<SettleJson[]>("pf_collect_recent_auto", { p_owner: owner, p_hours: hours });
  }
  decide(owner: string, id: string, accept: boolean) {
    return this.rpc<Record<string, unknown>>("pf_collect_decide", { p_owner: owner, p_id: id, p_accept: accept });
  }
  undo(owner: string, id: string) {
    return this.rpc<Record<string, unknown>>("pf_collect_undo", { p_owner: owner, p_id: id });
  }
  undoByTx(owner: string, txId: string) {
    return this.rpc<Record<string, unknown> | null>("pf_collect_undo_by_tx", { p_owner: owner, p_tx: txId });
  }
  reminder(owner: string, debtId: string, today: string) {
    return this.rpc<ReminderInfo>("pf_collect_reminder", { p_owner: owner, p_debt: debtId, p_today: today });
  }
  due(owner: string, today: string) {
    return this.rpc<ReminderInfo[]>("pf_collect_due", { p_owner: owner, p_today: today });
  }
  markReminded(owner: string, debtId: string) {
    return this.rpc<Record<string, unknown>>("pf_collect_mark_reminded", { p_owner: owner, p_debt: debtId });
  }
  snooze(owner: string, debtId: string, until: string) {
    return this.rpc<Record<string, unknown>>("pf_collect_snooze", { p_owner: owner, p_debt: debtId, p_until: until });
  }
  contactBank(owner: string, contactId: string, p: { bank?: string | undefined; bin?: string | null | undefined; account_number?: string | undefined; holder?: string | null | undefined }) {
    return this.rpc<Record<string, unknown>>("pf_contact_bank_set", { p_owner: owner, p_contact: contactId, p });
  }
  goalPlan(owner: string, today: string) {
    return this.rpc<GoalPlan[]>("pf_goal_plan", { p_owner: owner, p_today: today });
  }
  incomeFacts(owner: string, txId: string) {
    return this.rpc<(IncomeFacts & { note: string | null }) | null>("pf_goal_income_facts", { p_owner: owner, p_tx: txId });
  }
  propose(owner: string, p: { goal_id: string; account_id: string; amount: string; reason: "INCOME" | "MONTH_END"; period: string; source_tx?: string }) {
    return this.rpc<{ status: "PROPOSED" | "EXISTS" | "SKIPPED"; id?: string }>("pf_goal_propose", { p_owner: owner, p });
  }
  proposals(owner: string) {
    return this.rpc<GoalProposal[]>("pf_goal_proposals", { p_owner: owner });
  }
  accept(owner: string, id: string) {
    return this.rpc<Record<string, unknown>>("pf_goal_proposal_accept", { p_owner: owner, p_id: id });
  }
  dismiss(owner: string, id: string) {
    return this.rpc<Record<string, unknown>>("pf_goal_proposal_dismiss", { p_owner: owner, p_id: id });
  }
  monthSurplus(owner: string, month: string) {
    return this.rpc<MonthSurplus>("pf_goal_month_surplus", { p_owner: owner, p_month: month });
  }
  milestones(owner: string) {
    return this.rpc<{ goal_id: string; name: string; pct: number; target: string; allocated: string }[]>("pf_goal_milestones_due", { p_owner: owner });
  }
  pushClaim(owner: string, key: string) {
    return this.rpc<boolean>("pf_push_log_claim", { p_owner: owner, p_key: key });
  }
  repair(owner: string) {
    return this.rpc<number>("pf_collect_repair", { p_owner: owner });
  }
}
