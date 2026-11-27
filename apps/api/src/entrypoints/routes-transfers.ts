import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import { SupabaseTransferGateway, type TransferGateway } from "../modules/transfers/gateway";
import { DomainError } from "../shared/errors";

// Own-account transfers (migration 010): review routes, the best-effort hooks after a money-in/out is recorded
// (bank event, notification capture) and the reconciliation sweep run from runScheduled().
// Pairing never fails the operation that triggered it: errors are logged as one line and swallowed.

export interface TransferDeps {
  cfg: Config;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  tg?: TransferGateway;
}

/** Hours looked back by the scheduled reconciliation sweep. */
export const SWEEP_HOURS = 48;

export const tgOf = (d: TransferDeps): TransferGateway => d.tg ?? new SupabaseTransferGateway(d.cfg);

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}
const ownerOf = (c: Context<any>): string => (c as any).get("owner");
const UUID = z.string().uuid();

function parseOr<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}

function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "transfer_pair", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

export function registerTransferRoutes(app: Hono<any>, getDeps: (env: any) => TransferDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  // Pairs the owner should confirm (several candidates or a weak match). Both legs are still posted.
  app.get("/v1/transfers/suggestions", auth, async (c) => ok(c, await tgOf(getDeps(c.env)).suggestions(ownerOf(c))));

  // accept=true: both legs become one transfer (CONFIRMED). accept=false: REJECTED, never suggested again.
  app.post("/v1/transfers/suggestions/:id", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("id"));
    const { accept } = parseOr(z.object({ accept: z.boolean() }).strict(), await c.req.json().catch(() => null));
    return ok(c, await tgOf(getDeps(c.env)).decide(ownerOf(c), id, accept));
  });

  // Splits an automatic / accepted pairing back into the two original transactions.
  app.post("/v1/transfers/:pairId/undo", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("pairId"));
    return ok(c, await tgOf(getDeps(c.env)).undo(ownerOf(c), id));
  });

  // The pairing that produced a transfer transaction, or null (transfer entered by hand).
  app.get("/v1/transfers/by-tx/:txId", auth, async (c) => {
    const id = parseOr(UUID, c.req.param("txId"));
    return ok(c, await tgOf(getDeps(c.env)).pairForTx(ownerOf(c), id));
  });
}

// ---------------------------------------------------------------- hooks
/** After a money-in/out transaction was created from a bank event or a captured notification. Never throws. */
export async function pairAfterTx(d: TransferDeps, owner: string, txId: string | undefined, step: string): Promise<void> {
  if (!txId) return;
  try {
    await tgOf(d).tryPair(owner, txId);
  } catch (e) {
    logFailure(step, e);
  }
}

/** Which committed commands may be one leg of an own-account transfer: new TX_CREATE money in/out from a notification. */
export function pairableCommand(command: { command_type: string; payload: unknown }, result: Record<string, unknown> | null | undefined): string | undefined {
  if (command.command_type !== "TX_CREATE" || result?.status !== "COMMITTED") return undefined;
  const p = command.payload as Record<string, unknown> | null;
  if (!p || p.source !== "NOTIFICATION" || !["INCOME", "EXPENSE", "UNKNOWN_CREDIT", "UNKNOWN_DEBIT"].includes(String(p.kind))) return undefined;
  return typeof result.tx_id === "string" ? result.tx_id : undefined;
}

/** /v1/commands hook: notification captures are checked right away (bank events have their own hook). */
export async function pairAfterCommand(d: TransferDeps, owner: string, command: { command_type: string; payload: unknown }, result: Record<string, unknown>): Promise<void> {
  const txId = pairableCommand(command, result);
  if (txId) await pairAfterTx(d, owner, txId, "command");
}

/** Reconciliation for the cron: legs that arrived out of order or while the hook failed. Never throws. */
export async function runTransferSweep(d: TransferDeps, owner: string): Promise<{ checked: number; auto: number; suggested: number; failed: number } | null> {
  try {
    const r = await tgOf(d).sweep(owner, SWEEP_HOURS);
    if (r.failed > 0) console.log(JSON.stringify({ op: "transfer_pair", step: "sweep", outcome: "partial", failed: r.failed }));
    return r;
  } catch (e) {
    logFailure("sweep", e);
    return null;
  }
}
