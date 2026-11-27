import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import { resetSepayCache } from "../../src/modules/bank/sepay";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import type { MemoryGateway } from "../../src/modules/ai/memory-gateway";
import { DomainError } from "../../src/shared/errors";

// POST /v1/banks/sepay/link (create vs attach to an existing account) and the full number on owner-only reads.
const OWNER = "11111111-1111-1111-1111-111111111111";
const DEVICE = "44444444-4444-4444-4444-444444444444";
const EXT = "11111111-aaaa-4aaa-8aaa-111111111111";
const ACC = "22222222-2222-4222-8222-222222222222";
const NUMBER = "1017588888";
const cfg: Config = {
  supabaseUrl: "https://x.supabase.co",
  publishableKey: "pk",
  serviceRoleKey: "sk",
  ownerEmail: "o@example.test",
  dbTimeoutMs: 1000,
  sepayToken: "tok",
} as Config;

const sepayFetch: typeof fetch = async (input) => {
  if (String(input).includes("/bank-accounts")) {
    return new Response(
      JSON.stringify({ status: "success", data: [{ id: EXT, account_holder_name: "NGUYEN VAN A", account_number: NUMBER, accumulated: 2500000, active: 1, bank_short_name: "Vietcombank", label: "VCB", connection_type: "api" }] }),
      { status: 200 },
    );
  }
  return new Response("{}", { status: 404 });
};

type Row = { id: string; kind: string; last4: string | null; archived: boolean; version: number; baseline_known: boolean };
function makeApp(state: { accounts: Row[]; links: { external_id: string; account_id: string }[] }) {
  const commands: { command_type: string; payload: Record<string, unknown> }[] = [];
  const gw = {
    getOwnerId: vi.fn(async () => OWNER),
    getSetupState: vi.fn(async () => "BOUND"),
    readAccounts: vi.fn(async () => state.accounts),
    readLinks: vi.fn(async () => state.links),
    linkAccount: vi.fn(async (_o: string, accountId: string, a: { externalId: string }) => {
      state.links.push({ external_id: a.externalId, account_id: accountId });
      return { replayed: false };
    }),
    executeCommand: vi.fn(async (_ctx: unknown, _id: string, _h: string, cmd: { command_type: string; payload: Record<string, unknown> }) => {
      commands.push(cmd);
      return cmd.command_type === "ACCOUNT_CREATE" ? { account_id: "33333333-3333-4333-8333-333333333333", status: "COMMITTED" } : { status: "COMMITTED" };
    }),
  } as unknown as FinanceGateway;
  const verifier = {
    verify: vi.fn(async (h: string | undefined) => {
      if (!h) throw new DomainError("UNAUTHENTICATED");
      return { userId: OWNER, sessionId: "33333333-3333-3333-3333-333333333333" };
    }),
  } as unknown as SessionVerifier;
  const mg = { observe: vi.fn(async () => ({ learned: null })) } as unknown as MemoryGateway;
  const app = buildApp(() => ({ cfg, gw, verifier, mg, sepayFetch }));
  const req = async (method: string, path: string, body?: unknown) => {
    const res = await app.request(
      path,
      { method, headers: { authorization: "Bearer t", "x-device-id": DEVICE, "content-type": "application/json" }, body: body === undefined ? null : JSON.stringify(body) },
      {} as never,
    );
    return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
  };
  return { req, gw, commands, state };
}

describe("SePay link", () => {
  beforeEach(() => resetSepayCache());

  it("without account_id creates a new MoMa account at the bank balance", async () => {
    const t = makeApp({ accounts: [], links: [] });
    const r = await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT });
    expect(r.status).toBe(200);
    expect(r.json.data).toMatchObject({ attached: false, last4: "8888" });
    expect(t.commands.map((c) => c.command_type)).toEqual(["ACCOUNT_CREATE"]);
    expect(t.commands[0]!.payload).toMatchObject({ kind: "BANK", opening_amount: "2500000", last4: "8888" });
  });

  it("attaches to an existing account: no new account, fills last4 and the unknown opening balance", async () => {
    const t = makeApp({ accounts: [{ id: ACC, kind: "BANK", last4: null, archived: false, version: 3, baseline_known: false }], links: [] });
    const r = await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: ACC });
    expect(r.status).toBe(200);
    expect(r.json.data).toMatchObject({ account_id: ACC, attached: true });
    expect(t.commands.map((c) => c.command_type)).toEqual(["ACCOUNT_UPDATE"]);
    expect(t.commands[0]!.payload).toEqual({ account_id: ACC, expected_version: 3, last4: "8888", balance: "2500000" });
    expect(t.state.links).toEqual([{ external_id: EXT, account_id: ACC }]);
  });

  it("attaching an account whose balance is known keeps it (no adjustment) and repeating is a no-op", async () => {
    const t = makeApp({ accounts: [{ id: ACC, kind: "BANK", last4: "8888", archived: false, version: 1, baseline_known: true }], links: [] });
    expect((await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: ACC })).status).toBe(200);
    const again = await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: ACC });
    expect(again.status).toBe(200);
    expect(again.json.data.account_id).toBe(ACC);
    expect(t.commands).toEqual([]);
    expect(t.gw.linkAccount).toHaveBeenCalledTimes(1);
  });

  it("refuses unknown, card or already-linked accounts, and a second MoMa account for the same bank account", async () => {
    const other = "44444444-aaaa-4aaa-8aaa-444444444444";
    const t = makeApp({
      accounts: [
        { id: ACC, kind: "CREDIT_CARD", last4: null, archived: false, version: 1, baseline_known: true },
        { id: other, kind: "BANK", last4: null, archived: false, version: 1, baseline_known: true },
      ],
      links: [],
    });
    expect((await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: "55555555-5555-4555-8555-555555555555" })).status).toBe(404);
    expect((await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: ACC })).status).toBe(400);
    t.state.links.push({ external_id: "another-bank-account", account_id: other });
    const dup = await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: other });
    expect(dup.status).toBe(409);
    expect(dup.json.error?.code).toBe("ACCOUNT_ALREADY_LINKED");
    t.state.links.length = 0;
    t.state.links.push({ external_id: EXT, account_id: other });
    const taken = await t.req("POST", "/v1/banks/sepay/link", { external_id: EXT, account_id: "66666666-6666-4666-8666-666666666666" });
    expect(taken.json.error?.code).toBe("BANK_ALREADY_LINKED");
  });

  it("owner reads carry the full account number (list and links)", async () => {
    const t = makeApp({ accounts: [], links: [{ external_id: EXT, account_id: ACC }] });
    const list = await t.req("GET", "/v1/banks/sepay/accounts");
    expect(list.json.data[0]).toMatchObject({ number: NUMBER, number_masked: "••••8888", linked: true });
    const links = await t.req("GET", "/v1/banks/links");
    expect(links.json.data[0]).toMatchObject({ account_id: ACC, number: NUMBER });
  });
});
