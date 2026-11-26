import { serviceHeaders, type Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";
import type { CommandContext, FinanceGateway } from "./ports";

interface PgError {
  code?: string;
  message?: string;
}

export class SupabaseFinanceGateway implements FinanceGateway {
  constructor(private readonly cfg: Config) {}

  private async rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const res = await fetch(`${this.cfg.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: serviceHeaders(this.cfg),
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(this.cfg.dbTimeoutMs),
    });
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as PgError;
      // RPCs raise stable domain codes as the exception message (errcode P0001).
      throw new DomainError(body.code === "P0001" && body.message ? body.message : "DB_ERROR");
    }
    return (await res.json()) as T;
  }

  executeCommand(ctx: CommandContext, commandId: string, hash: string, command: unknown) {
    return this.rpc<Record<string, unknown>>("pf_execute_command", {
      p_owner: ctx.ownerId,
      p_session: ctx.sessionId,
      p_device: ctx.deviceId,
      p_command_id: commandId,
      p_hash: hash,
      p_command: command,
    });
  }
  readAccounts(ownerId: string) {
    return this.rpc("pf_read_accounts", { p_owner: ownerId });
  }
  readCategories(ownerId: string) {
    return this.rpc("pf_read_categories", { p_owner: ownerId });
  }
  readTransactions(ownerId: string, limit: number, before: { at: string; id: string } | null) {
    return this.rpc("pf_read_transactions", { p_owner: ownerId, p_limit: limit, p_before_at: before?.at ?? null, p_before_id: before?.id ?? null });
  }
  readDashboard(ownerId: string, fromIso: string, toIso: string) {
    return this.rpc("pf_read_dashboard", { p_owner: ownerId, p_from: fromIso, p_to: toIso });
  }
  readProfile(ownerId: string) {
    return this.rpc("pf_read_profile", { p_owner: ownerId });
  }
  registerDevice(ownerId: string, sessionId: string, deviceId: string, label: string) {
    return this.rpc("pf_device_register", { p_owner: ownerId, p_session: sessionId, p_device: deviceId, p_label: label });
  }
  getOwnerId() {
    return this.rpc<string | null>("pf_get_owner", {});
  }
  getSetupState() {
    return this.rpc<string>("pf_get_setup_state", {});
  }
}
