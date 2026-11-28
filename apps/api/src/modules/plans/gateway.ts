import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";

// Supabase RPCs of migration 021 (event plans, life plans, history reads). Injectable so routes are unit-tested.

export interface EventPlanJson {
  id: string;
  title: string;
  kind: string;
  starts_at: string;
  ends_at: string;
  headcount: number;
  people: string[];
  place: string | null;
  owner_pays: boolean;
  transport: "GRAB" | "OWN" | "NONE";
  note: string | null;
  estimate: Record<string, any>;
  budget: string | null;
  state: "PLANNED" | "DONE" | "CANCELLED";
  actual: Record<string, any> | null;
  reminded_at: string | null;
  alerted_at: string | null;
  closed_at: string | null;
  created_at: string;
  updated_at: string;
  version: number;
}

export interface LifePlanJson {
  id: string;
  name: string;
  kind: string;
  price: string;
  down_pct: number;
  loan_rate_pct: number;
  loan_years: number;
  inflation_pct: number;
  income_growth_pct: number;
  extra_saving: string;
  goal_id: string | null;
  target_date: string | null;
  created_at: string;
  updated_at: string;
  version: number;
}

export interface SpendRowJson {
  id: string;
  at: string;
  kind: string;
  amount: string;
  owner_amount: string;
  group_size: number | null;
  category: string | null;
  merchant: string | null;
  note: string | null;
  hour?: number;
  norm?: string;
  ride?: boolean;
  food?: boolean;
}

export interface MonthJson {
  month: string;
  income: string;
  expense: string;
  partial: boolean;
}

export interface WealthJson {
  assets: string;
  liabilities: string;
  receivable: string;
  payable: string;
  goals: { id: string; name: string; target: string; allocated: string; due_date: string | null; state: string }[];
}

export interface PlanGateway {
  eventUpsert(owner: string, p: Record<string, unknown>): Promise<EventPlanJson>;
  eventList(owner: string, state: string | null, from: string | null, to: string | null): Promise<EventPlanJson[]>;
  eventGet(owner: string, id: string): Promise<EventPlanJson>;
  eventClose(owner: string, id: string, state: "DONE" | "CANCELLED", actual: Record<string, unknown> | null): Promise<EventPlanJson>;
  eventMark(owner: string, id: string, what: "REMINDED" | "ALERTED"): Promise<boolean>;
  spendRows(owner: string, from: string, to: string): Promise<SpendRowJson[]>;
  months(owner: string, n: number): Promise<MonthJson[]>;
  wealth(owner: string): Promise<WealthJson>;
  lifeUpsert(owner: string, p: Record<string, unknown>): Promise<LifePlanJson>;
  lifeList(owner: string): Promise<LifePlanJson[]>;
  lifeDelete(owner: string, id: string): Promise<unknown>;
  pushClaim(owner: string, key: string): Promise<boolean>;
}

export class SupabasePlanGateway implements PlanGateway {
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

  eventUpsert(owner: string, p: Record<string, unknown>) {
    return this.rpc<EventPlanJson>("pf_plan_event_upsert", { p_owner: owner, p });
  }
  eventList(owner: string, state: string | null, from: string | null, to: string | null) {
    return this.rpc<EventPlanJson[]>("pf_plan_event_list", { p_owner: owner, p_state: state, p_from: from, p_to: to });
  }
  eventGet(owner: string, id: string) {
    return this.rpc<EventPlanJson>("pf_plan_event_get", { p_owner: owner, p_id: id });
  }
  eventClose(owner: string, id: string, state: "DONE" | "CANCELLED", actual: Record<string, unknown> | null) {
    return this.rpc<EventPlanJson>("pf_plan_event_close", { p_owner: owner, p_id: id, p_state: state, p_actual: actual });
  }
  eventMark(owner: string, id: string, what: "REMINDED" | "ALERTED") {
    return this.rpc<boolean>("pf_plan_event_mark", { p_owner: owner, p_id: id, p_what: what });
  }
  spendRows(owner: string, from: string, to: string) {
    return this.rpc<SpendRowJson[]>("pf_plan_spend_rows", { p_owner: owner, p_from: from, p_to: to });
  }
  months(owner: string, n: number) {
    return this.rpc<MonthJson[]>("pf_plan_months", { p_owner: owner, p_months: n });
  }
  wealth(owner: string) {
    return this.rpc<WealthJson>("pf_plan_wealth", { p_owner: owner });
  }
  lifeUpsert(owner: string, p: Record<string, unknown>) {
    return this.rpc<LifePlanJson>("pf_life_plan_upsert", { p_owner: owner, p });
  }
  lifeList(owner: string) {
    return this.rpc<LifePlanJson[]>("pf_life_plan_list", { p_owner: owner });
  }
  lifeDelete(owner: string, id: string) {
    return this.rpc<unknown>("pf_life_plan_delete", { p_owner: owner, p_id: id });
  }
  pushClaim(owner: string, key: string) {
    return this.rpc<boolean>("pf_push_log_claim", { p_owner: owner, p_key: key });
  }
}
