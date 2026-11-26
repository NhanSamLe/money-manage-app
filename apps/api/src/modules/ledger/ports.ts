// Port: every financial write/read goes through server-only DB RPCs. No ledger logic in TypeScript.
export interface CommandContext {
  ownerId: string;
  sessionId: string;
  deviceId: string;
}

export interface FinanceGateway {
  executeCommand(ctx: CommandContext, commandId: string, hash: string, command: unknown): Promise<Record<string, unknown>>;
  readAccounts(ownerId: string): Promise<unknown>;
  readCategories(ownerId: string): Promise<unknown>;
  readTransactions(ownerId: string, limit: number, before: { at: string; id: string } | null): Promise<unknown>;
  readDashboard(ownerId: string, fromIso: string, toIso: string): Promise<unknown>;
  readProfile(ownerId: string): Promise<unknown>;
  readContacts(ownerId: string): Promise<unknown>;
  readDebts(ownerId: string, todayLocal: string): Promise<unknown>;
  readGoals(ownerId: string): Promise<unknown>;
  readBudgets(ownerId: string, monthFirstDay: string): Promise<unknown>;
  /** Generates due occurrences (idempotent) and returns templates with their expected occurrences. */
  readRecurring(ownerId: string, todayLocal: string): Promise<unknown>;
  registerDevice(ownerId: string, sessionId: string, deviceId: string, label: string): Promise<unknown>;
  getOwnerId(): Promise<string | null>;
  getSetupState(): Promise<string>;
}
