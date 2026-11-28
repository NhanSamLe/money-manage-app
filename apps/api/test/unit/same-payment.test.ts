import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import type { TransferGateway } from "../../src/modules/transfers/gateway";
import { DomainError } from "../../src/shared/errors";

// Matching / merging is SQL (migration 018, covered by test/e2e/same-payment.e2e.test.ts); these tests cover the
// HTTP surface of the duplicate review routes.
const OWNER = "11111111-1111-1111-1111-111111111111";
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SAME = "88888888-8888-4888-8888-888888888888";
const TX = "77777777-7777-4777-8777-777777777777";
const cfg: Config = { supabaseUrl: "https://x.supabase.co", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@example.test", dbTimeoutMs: 1000 };
const authed = { authorization: "Bearer t", "x-device-id": DEVICE, "content-type": "application/json" };
const env = {} as never;

function makeApp(over: Partial<Record<string, (...a: any[]) => Promise<unknown>>> = {}) {
  const gw = { getOwnerId: vi.fn(async () => OWNER) } as unknown as FinanceGateway;
  const verifier = {
    verify: vi.fn(async (h: string | undefined) => {
      if (!h) throw new DomainError("UNAUTHENTICATED");
      return { userId: OWNER, sessionId: "33333333-3333-3333-3333-333333333333" };
    }),
  } as unknown as SessionVerifier;
  const mg = { observe: vi.fn(async () => ({ learned: null })) } as unknown as MemoryGateway;
  const tg = {
    duplicateSuggestions: vi.fn(over.duplicateSuggestions ?? (async () => [{ id: SAME, state: "SUGGESTED", score: 55, hints: ["wallet"] }])),
    duplicateDecide: vi.fn(over.duplicateDecide ?? (async (_o: string, id: string, accept: boolean) => ({ id, state: accept ? "CONFIRMED" : "REJECTED" }))),
    duplicateUndo: vi.fn(over.duplicateUndo ?? (async (_o: string, id: string) => ({ id, state: "REJECTED", keep_tx_id: TX, restored_tx_id: TX }))),
    duplicateForTx: vi.fn(over.duplicateForTx ?? (async () => null)),
  };
  return { app: buildApp(() => ({ cfg, gw, verifier, mg, tg: tg as unknown as TransferGateway })), tg };
}

describe("duplicate (same-payment) routes", () => {
  it("lists suggestions for the owner", async () => {
    const { app, tg } = makeApp();
    const res = await app.request("/v1/duplicates/suggestions", { headers: authed }, env);
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).data[0].id).toBe(SAME);
    expect(tg.duplicateSuggestions).toHaveBeenCalledWith(OWNER);
  });

  it("decides with a strict boolean body", async () => {
    const { app, tg } = makeApp();
    const yes = await app.request(`/v1/duplicates/${SAME}/decide`, { method: "POST", headers: authed, body: JSON.stringify({ accept: true }) }, env);
    expect(((await yes.json()) as any).data.state).toBe("CONFIRMED");
    expect(tg.duplicateDecide).toHaveBeenCalledWith(OWNER, SAME, true);
    const no = await app.request(`/v1/duplicates/${SAME}/decide`, { method: "POST", headers: authed, body: JSON.stringify({ accept: false }) }, env);
    expect(((await no.json()) as any).data.state).toBe("REJECTED");
    for (const body of ["{}", JSON.stringify({ accept: "yes" }), JSON.stringify({ accept: true, extra: 1 }), "nope"]) {
      expect((await app.request(`/v1/duplicates/${SAME}/decide`, { method: "POST", headers: authed, body }, env)).status).toBe(400);
    }
    expect((await app.request(`/v1/duplicates/not-a-uuid/decide`, { method: "POST", headers: authed, body: JSON.stringify({ accept: true }) }, env)).status).toBe(400);
  });

  it("undo and by-transaction lookups validate ids and pass domain errors through", async () => {
    const { app, tg } = makeApp({ duplicateUndo: async () => { throw new DomainError("INVALID_STATE"); } });
    const undo = await app.request(`/v1/duplicates/${SAME}/undo`, { method: "POST", headers: authed }, env);
    expect(undo.status).toBe(422);
    expect(((await undo.json()) as any).error.code).toBe("INVALID_STATE");
    expect((await app.request(`/v1/duplicates/x/undo`, { method: "POST", headers: authed }, env)).status).toBe(400);
    const one = await app.request(`/v1/transactions/${TX}/duplicate`, { headers: authed }, env);
    expect(one.status).toBe(200);
    expect(((await one.json()) as any).data).toBeNull();
    expect(tg.duplicateForTx).toHaveBeenCalledWith(OWNER, TX);
    expect((await app.request(`/v1/transactions/abc/duplicate`, { headers: authed }, env)).status).toBe(400);
  });

  it("requires a session", async () => {
    const { app } = makeApp();
    expect((await app.request("/v1/duplicates/suggestions", {}, env)).status).toBe(401);
  });
});
