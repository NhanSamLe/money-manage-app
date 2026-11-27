import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import { DomainError } from "../../src/shared/errors";
import { API_VERSION } from "../../src/shared/version";

const OWNER = "11111111-1111-1111-1111-111111111111";
const DEVICE = "44444444-4444-4444-4444-444444444444";
const CMD = "55555555-5555-5555-5555-555555555501";

const cfg: Config = {
  supabaseUrl: "https://x.supabase.co",
  publishableKey: "pk",
  serviceRoleKey: "sk",
  ownerEmail: "o@example.test",
  dbTimeoutMs: 1000,
};

function makeApp(opts: { userId?: string; owner?: string | null } = {}) {
  const gw = {
    getOwnerId: vi.fn(async () => (opts.owner === undefined ? OWNER : opts.owner)),
    getSetupState: vi.fn(async () => "BOUND"),
    executeCommand: vi.fn(async () => ({ status: "COMMITTED" })),
    readAccounts: vi.fn(async () => []),
  } as unknown as FinanceGateway;
  const verifier = {
    verify: vi.fn(async (h: string | undefined) => {
      if (!h) throw new DomainError("UNAUTHENTICATED");
      return { userId: opts.userId ?? OWNER, sessionId: "33333333-3333-3333-3333-333333333333" };
    }),
  } as unknown as SessionVerifier;
  const mg = { observe: vi.fn(async () => ({ learned: null })) } as unknown as MemoryGateway;
  return { app: buildApp(() => ({ cfg, gw, verifier, mg })), gw, mg };
}

const authed = { authorization: "Bearer t", "x-device-id": DEVICE, "content-type": "application/json" };
const env = {} as never;

describe("http api", () => {
  it("serves health with the packaged version", async () => {
    const { app } = makeApp();
    const res = await app.request("/v1/health", {}, env);
    expect(res.status).toBe(200);
    expect(((await res.json()) as { data: { api_version: string } }).data.api_version).toBe(API_VERSION);
  });

  it("rejects missing credentials with 401 and a request id", async () => {
    const { app } = makeApp();
    const res = await app.request("/v1/accounts", {}, env);
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { request_id: string } }).error.request_id).toBeTruthy();
  });

  it("refuses a valid user who is not the bound owner (403)", async () => {
    const { app } = makeApp({ userId: "99999999-9999-9999-9999-999999999999" });
    expect((await app.request("/v1/accounts", { headers: authed }, env)).status).toBe(403);
  });

  it("refuses everything before setup is complete (403)", async () => {
    const { app } = makeApp({ owner: null });
    expect((await app.request("/v1/accounts", { headers: authed }, env)).status).toBe(403);
  });

  it("requires an Idempotency-Key equal to command_id", async () => {
    const { app, gw } = makeApp();
    const body = JSON.stringify({ command_id: CMD, command_type: "TX_REVERSE", schema_version: 1, payload: { tx_id: CMD, reason: "x", expected_version: 1 } });
    expect((await app.request("/v1/commands", { method: "POST", headers: authed, body }, env)).status).toBe(400);
    const wrong = { ...authed, "idempotency-key": "55555555-5555-5555-5555-555555555502" };
    expect((await app.request("/v1/commands", { method: "POST", headers: wrong, body }, env)).status).toBe(400);
    expect(gw.executeCommand).not.toHaveBeenCalled();
  });

  it("forwards a valid command and hashes deterministically", async () => {
    const { app, gw } = makeApp();
    const body = JSON.stringify({ command_id: CMD, command_type: "TX_REVERSE", schema_version: 1, payload: { tx_id: CMD, reason: "x", expected_version: 1 } });
    const headers = { ...authed, "idempotency-key": CMD };
    expect((await app.request("/v1/commands", { method: "POST", headers, body }, env)).status).toBe(200);
    expect((await app.request("/v1/commands", { method: "POST", headers, body }, env)).status).toBe(200);
    const calls = vi.mocked(gw.executeCommand).mock.calls;
    expect(calls[0]?.[2]).toBe(calls[1]?.[2]);
  });

  it("answers NOT_IMPLEMENTED for known but unbuilt commands (no fake success)", async () => {
    const { app } = makeApp();
    const body = JSON.stringify({ command_id: CMD, command_type: "SPLIT_BILL_CREATE", schema_version: 1, payload: {} });
    const res = await app.request("/v1/commands", { method: "POST", headers: { ...authed, "idempotency-key": CMD }, body }, env);
    expect(res.status).toBe(422);
  });

  it("rejects malformed money before reaching the database", async () => {
    const { app, gw } = makeApp();
    const body = JSON.stringify({ command_id: CMD, command_type: "TX_CREATE", schema_version: 1, payload: { kind: "EXPENSE", account_id: CMD, amount: "12.5", effective_at: "2026-11-27T05:00:00Z", category_id: CMD } });
    const res = await app.request("/v1/commands", { method: "POST", headers: { ...authed, "idempotency-key": CMD }, body }, env);
    expect(res.status).toBe(400);
    expect(gw.executeCommand).not.toHaveBeenCalled();
  });

  it("answers 400 (not 503) for an invalid report month", async () => {
    const { app } = makeApp();
    expect((await app.request("/v1/reports/summary?month=2026-13", { headers: authed }, env)).status).toBe(400);
  });

  it("maps domain errors to stable codes without leaking internals", async () => {
    const { app, gw } = makeApp();
    vi.mocked(gw.readAccounts).mockRejectedValueOnce(new Error("secret connection string"));
    const res = await app.request("/v1/accounts", { headers: authed }, env);
    expect(res.status).toBe(503);
    expect(JSON.stringify(await res.json())).not.toContain("secret");
  });
});
