import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { pairableCommand, runTransferSweep } from "../../src/entrypoints/routes-transfers";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import type { TransferGateway } from "../../src/modules/transfers/gateway";
import { DomainError } from "../../src/shared/errors";

// Matching and scoring are SQL (pf_private.try_pair_transfer, tested in supabase/tests/isolated/008 and e2e);
// these tests cover the HTTP surface and the best-effort hooks around it.
const OWNER = "11111111-1111-1111-1111-111111111111";
const DEVICE = "44444444-4444-4444-4444-444444444444";
const ACC = "22222222-2222-4222-8222-222222222222";
const PAIR = "66666666-6666-4666-8666-666666666666";
const TX = "77777777-7777-4777-8777-777777777777";
const cfg: Config = { supabaseUrl: "https://x.supabase.co", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@example.test", dbTimeoutMs: 1000 };
const authed = { authorization: "Bearer t", "x-device-id": DEVICE, "content-type": "application/json" };
const env = {} as never;

function makeApp(opts: { tryPair?: () => Promise<unknown>; result?: Record<string, unknown> } = {}) {
  const gw = {
    getOwnerId: vi.fn(async () => OWNER),
    executeCommand: vi.fn(async () => opts.result ?? { status: "COMMITTED", tx_id: TX }),
  } as unknown as FinanceGateway;
  const verifier = {
    verify: vi.fn(async (h: string | undefined) => {
      if (!h) throw new DomainError("UNAUTHENTICATED");
      return { userId: OWNER, sessionId: "33333333-3333-3333-3333-333333333333" };
    }),
  } as unknown as SessionVerifier;
  const mg = { observe: vi.fn(async () => ({ learned: null })) } as unknown as MemoryGateway;
  const tg = {
    tryPair: vi.fn(opts.tryPair ?? (async () => ({ status: "AUTO", pair_id: PAIR, transfer_tx_id: TX }))),
    sweep: vi.fn(async () => ({ checked: 3, auto: 1, suggested: 0, failed: 0 })),
    suggestions: vi.fn(async () => [{ id: PAIR, state: "SUGGESTED" }]),
    decide: vi.fn(async (_o: string, id: string, accept: boolean) => ({ pair_id: id, state: accept ? "CONFIRMED" : "REJECTED" })),
    undo: vi.fn(async (_o: string, id: string) => ({ pair_id: id, state: "REJECTED" })),
    pairForTx: vi.fn(async () => null),
  };
  return { app: buildApp(() => ({ cfg, gw, verifier, mg, tg: tg as unknown as TransferGateway })), gw, tg };
}

async function command(app: ReturnType<typeof buildApp>, payload: Record<string, unknown>) {
  const id = crypto.randomUUID();
  return app.request(
    "/v1/commands",
    { method: "POST", headers: { ...authed, "idempotency-key": id }, body: JSON.stringify({ command_id: id, command_type: "TX_CREATE", schema_version: 1, payload }) },
    env,
  );
}
const money = (over: Record<string, unknown> = {}) => ({ kind: "UNKNOWN_CREDIT", account_id: ACC, amount: "500000", effective_at: "2026-11-28T03:00:00Z", source: "NOTIFICATION", ...over });

describe("pairableCommand", () => {
  const ok = { status: "COMMITTED", tx_id: TX };
  it("selects new notification money in/out only", () => {
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money() }, ok)).toBe(TX);
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money({ kind: "EXPENSE" }) }, ok)).toBe(TX);
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money({ source: "MANUAL" }) }, ok)).toBeUndefined();
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money({ source: undefined }) }, ok)).toBeUndefined();
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money({ kind: "TRANSFER" }) }, ok)).toBeUndefined();
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money() }, { status: "REPLAYED", tx_id: TX })).toBeUndefined();
    expect(pairableCommand({ command_type: "TX_REVERSE", payload: money() }, ok)).toBeUndefined();
    expect(pairableCommand({ command_type: "TX_CREATE", payload: money() }, { status: "COMMITTED" })).toBeUndefined();
  });
});

describe("pairing hook after /v1/commands", () => {
  it("tries to pair a notification capture once", async () => {
    const { app, tg } = makeApp();
    expect((await command(app, money())).status).toBe(200);
    expect(tg.tryPair).toHaveBeenCalledWith(OWNER, TX);
  });

  it("never fails the command and logs one line when pairing fails", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const { app, tg } = makeApp({ tryPair: async () => { throw new DomainError("DB_ERROR"); } });
    const res = await command(app, money());
    expect(res.status).toBe(200);
    expect(((await res.json()) as { data: { tx_id: string } }).data.tx_id).toBe(TX);
    expect(tg.tryPair).toHaveBeenCalledTimes(1);
    const lines = log.mock.calls.map((c) => String(c[0])).filter((l) => l.includes("transfer_pair"));
    expect(lines).toEqual([JSON.stringify({ op: "transfer_pair", step: "command", outcome: "error", code: "DB_ERROR" })]);
    log.mockRestore();
  });

  it("leaves manual entries alone", async () => {
    const { app, tg } = makeApp();
    await command(app, money({ source: "MANUAL" }));
    expect(tg.tryPair).not.toHaveBeenCalled();
  });
});

describe("transfer routes", () => {
  it("lists suggestions", async () => {
    const { app } = makeApp();
    const res = await app.request("/v1/transfers/suggestions", { headers: authed }, env);
    expect(res.status).toBe(200);
    expect(((await res.json()) as { data: unknown[] }).data).toEqual([{ id: PAIR, state: "SUGGESTED" }]);
  });

  it("accepts or rejects a suggestion; the body must be {accept: boolean}", async () => {
    const { app, tg } = makeApp();
    const post = (path: string, body: unknown) => app.request(path, { method: "POST", headers: authed, body: JSON.stringify(body) }, env);
    const yes = await post(`/v1/transfers/suggestions/${PAIR}`, { accept: true });
    expect(((await yes.json()) as { data: { state: string } }).data.state).toBe("CONFIRMED");
    const no = await post(`/v1/transfers/suggestions/${PAIR}`, { accept: false });
    expect(((await no.json()) as { data: { state: string } }).data.state).toBe("REJECTED");
    expect(tg.decide.mock.calls).toEqual([[OWNER, PAIR, true], [OWNER, PAIR, false]]);
    expect((await post(`/v1/transfers/suggestions/${PAIR}`, { accept: "yes" })).status).toBe(400);
    expect((await post(`/v1/transfers/suggestions/${PAIR}`, {})).status).toBe(400);
    expect((await post("/v1/transfers/suggestions/not-a-uuid", { accept: true })).status).toBe(400);
  });

  it("undoes a pair and maps domain errors", async () => {
    const { app, tg } = makeApp();
    const res = await app.request(`/v1/transfers/${PAIR}/undo`, { method: "POST", headers: authed }, env);
    expect(res.status).toBe(200);
    expect(tg.undo).toHaveBeenCalledWith(OWNER, PAIR);
    tg.undo.mockImplementationOnce(async () => { throw new DomainError("INVALID_STATE"); });
    expect((await app.request(`/v1/transfers/${PAIR}/undo`, { method: "POST", headers: authed }, env)).status).toBe(422);
  });

  it("returns the pair behind a transfer, or null", async () => {
    const { app, tg } = makeApp();
    const res = await app.request(`/v1/transfers/by-tx/${TX}`, { headers: authed }, env);
    expect(((await res.json()) as { data: unknown }).data).toBeNull();
    expect(tg.pairForTx).toHaveBeenCalledWith(OWNER, TX);
  });

  it("needs a signed-in owner", async () => {
    const { app } = makeApp();
    expect((await app.request("/v1/transfers/suggestions", {}, env)).status).toBe(401);
  });
});

describe("reconciliation sweep", () => {
  it("returns counts and never throws", async () => {
    const tg = { sweep: vi.fn(async () => ({ checked: 2, auto: 1, suggested: 1, failed: 0 })) } as unknown as TransferGateway;
    expect(await runTransferSweep({ cfg, tg }, OWNER)).toEqual({ checked: 2, auto: 1, suggested: 1, failed: 0 });
    expect((tg.sweep as any).mock.calls[0]).toEqual([OWNER, 48]);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const bad = { sweep: vi.fn(async () => { throw new DomainError("DB_ERROR"); }) } as unknown as TransferGateway;
    expect(await runTransferSweep({ cfg, tg: bad }, OWNER)).toBeNull();
    expect(log).toHaveBeenCalledTimes(1);
    log.mockRestore();
  });
});
