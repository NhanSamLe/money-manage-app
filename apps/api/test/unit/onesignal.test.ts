import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_ONESIGNAL_APP_ID, loadConfig, type Config, type Env } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";
import { ONESIGNAL_URL, bankEventPush, formatVnd, sendPush } from "../../src/modules/push/onesignal";

const OWNER = "6b1c0d2e-1111-4222-8333-444455556666";

function recorder(status = 200) {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = (async (url: unknown, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ id: "n1" }), { status });
  }) as typeof fetch;
  return { calls, f };
}

afterEach(() => vi.restoreAllMocks());

describe("OneSignal config", () => {
  const base: Env = { SUPABASE_URL: "https://x.supabase.co", SUPABASE_PUBLISHABLE_KEY: "pk", SUPABASE_SERVICE_ROLE_KEY: "sk", OWNER_EMAIL: "o@x.vn" };
  it("defaults the app id and leaves push off without a REST key", () => {
    const cfg = loadConfig(base);
    expect(cfg.onesignalAppId).toBe(DEFAULT_ONESIGNAL_APP_ID);
    expect(cfg.onesignalRestKey).toBeUndefined();
  });
  it("reads the REST key and an app id override", () => {
    const cfg = loadConfig({ ...base, ONESIGNAL_REST_KEY: "rk", ONESIGNAL_APP_ID: "other" });
    expect(cfg).toMatchObject({ onesignalRestKey: "rk", onesignalAppId: "other" });
  });
});

describe("sendPush", () => {
  const cfg = { onesignalAppId: DEFAULT_ONESIGNAL_APP_ID, onesignalRestKey: "rest-key-secret" };

  it("posts the current OneSignal shape targeting the owner's external_id", async () => {
    const { calls, f } = recorder();
    const ok = await sendPush(cfg, f, { ownerId: OWNER, title: "T", body: "B", data: { a: 1 }, androidGroup: "g" });
    expect(ok).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(ONESIGNAL_URL);
    expect(calls[0]!.url).toBe("https://api.onesignal.com/notifications?c=push");
    expect(calls[0]!.init.method).toBe("POST");
    const h = calls[0]!.init.headers as Record<string, string>;
    expect(h.authorization).toBe("Key rest-key-secret");
    expect(JSON.parse(String(calls[0]!.init.body))).toEqual({
      app_id: DEFAULT_ONESIGNAL_APP_ID,
      target_channel: "push",
      include_aliases: { external_id: [OWNER] },
      headings: { en: "T", vi: "T" },
      contents: { en: "B", vi: "B" },
      data: { a: 1 },
      android_group: "g",
    });
  });

  it("is disabled without a REST key", async () => {
    const { calls, f } = recorder();
    expect(await sendPush({ onesignalAppId: DEFAULT_ONESIGNAL_APP_ID }, f, { ownerId: OWNER, title: "T", body: "B" })).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("never throws: upstream errors and network failures are logged without secrets", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const bad = recorder(400);
    expect(await sendPush(cfg, bad.f, { ownerId: OWNER, title: "T", body: "B" })).toBe(false);
    const boom = (async () => {
      throw new TypeError("network down rest-key-secret");
    }) as typeof fetch;
    expect(await sendPush(cfg, boom, { ownerId: OWNER, title: "T", body: "B" })).toBe(false);
    expect(log).toHaveBeenCalledTimes(2);
    for (const [line] of log.mock.calls) {
      expect(String(line)).not.toContain("rest-key-secret");
      expect(JSON.parse(String(line))).toMatchObject({ op: "push.onesignal", outcome: "error" });
    }
  });

  it("aborts a slow request (5s timeout) instead of hanging", async () => {
    const spy = vi.spyOn(AbortSignal, "timeout");
    const { f } = recorder();
    await sendPush(cfg, f, { ownerId: OWNER, title: "T", body: "B" });
    expect(spy).toHaveBeenCalledWith(5_000);
  });
});

describe("bank event message", () => {
  it("formats VND with dots", () => {
    expect(formatVnd(0)).toBe("0");
    expect(formatVnd(999)).toBe("999");
    expect(formatVnd(1000)).toBe("1.000");
    expect(formatVnd(1500000)).toBe("1.500.000");
    expect(formatVnd(1234567890)).toBe("1.234.567.890");
  });
  it("money in / money out titles and bank • content body", () => {
    const a = bankEventPush(OWNER, { direction: "in", amount: 1500000, bankName: "Vietcombank", content: "LUONG T11" }, "tx-1");
    expect(a).toMatchObject({ ownerId: OWNER, title: "Tiền vào +1.500.000 đ", body: "Vietcombank • LUONG T11", androidGroup: "moma_bank" });
    expect(a.data).toEqual({ type: "bank_tx", direction: "in", amount: "1500000", tx_id: "tx-1", route: "/tx/tx-1" });
    const b = bankEventPush(OWNER, { direction: "out", amount: 200000, bankName: "MBBank", content: "GRAB" });
    expect(b.title).toBe("Tiền ra -200.000 đ");
    expect(b.body).toBe("MBBank • GRAB");
  });
  it("truncates content to 80 characters", () => {
    const m = bankEventPush(OWNER, { direction: "out", amount: 1, bankName: "VCB", content: "x".repeat(200) });
    const content = m.body.slice("VCB • ".length);
    expect(content.length).toBe(80);
    expect(content.endsWith("…")).toBe(true);
  });
});

describe("SePay webhook -> push (gateway faked)", () => {
  const WEBHOOK_KEY = "hook-key";
  const cfg: Config = {
    supabaseUrl: "https://x.supabase.co", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@example.test", dbTimeoutMs: 1000,
    sepayWebhookKey: WEBHOOK_KEY, onesignalAppId: DEFAULT_ONESIGNAL_APP_ID, onesignalRestKey: "rk",
  };
  function makeApp(status: string, opts: { restKey?: boolean } = {}) {
    const gw = {
      linkFind: vi.fn(async () => ({ owner_id: OWNER, account_id: "acc" })),
      readCategories: vi.fn(async () => [{ id: "cat-in", name: "Khác", type: "INCOME" }, { id: "cat-out", name: "Khác", type: "EXPENSE" }]),
      ingestBankEvent: vi.fn(async () => ({ status, tx_id: "tx-9" })),
    } as unknown as FinanceGateway;
    const push = recorder();
    const c: Config = { ...cfg };
    if (opts.restKey === false) delete c.onesignalRestKey;
    const app = buildApp(() => ({ cfg: c, gw, verifier: {} as SessionVerifier, pushFetch: push.f }));
    return { app, push };
  }
  const hook = (app: ReturnType<typeof buildApp>, ctx?: ExecutionContext) =>
    app.request(
      "/v1/webhooks/sepay",
      {
        method: "POST",
        headers: { authorization: `Apikey ${WEBHOOK_KEY}`, "content-type": "application/json" },
        body: JSON.stringify({ id: 1, gateway: "Vietcombank", transactionDate: "2026-11-27 11:08:33", accountNumber: "1017588888", content: "LUONG", transferType: "in", transferAmount: 1500000, accumulated: 2000000, referenceCode: "FT1" }),
      },
      {} as never,
      ctx,
    );

  it("sends one push for an APPLIED event (inline without an execution context)", async () => {
    const { app, push } = makeApp("APPLIED");
    const res = await hook(app);
    expect(res.status).toBe(200);
    expect(push.calls).toHaveLength(1);
    const body = JSON.parse(String(push.calls[0]!.init.body));
    expect(body.include_aliases).toEqual({ external_id: [OWNER] });
    expect(body.headings.vi).toBe("Tiền vào +1.500.000 đ");
    expect(body.contents.vi).toBe("Vietcombank • LUONG");
    expect(body.data.tx_id).toBe("tx-9");
  });

  it("hands the send to waitUntil when the Worker provides an execution context", async () => {
    const { app, push } = makeApp("APPLIED");
    const pending: Promise<unknown>[] = [];
    const ctx = { waitUntil: (p: Promise<unknown>) => pending.push(p), passThroughOnException: () => undefined, props: {} } as unknown as ExecutionContext;
    expect((await hook(app, ctx)).status).toBe(200);
    expect(pending).toHaveLength(1);
    await Promise.all(pending);
    expect(push.calls).toHaveLength(1);
  });

  it("never pushes for DUPLICATE or UNMATCHED, nor when push is not configured", async () => {
    for (const s of ["DUPLICATE", "UNMATCHED"]) {
      const { app, push } = makeApp(s);
      expect((await hook(app)).status).toBe(200);
      expect(push.calls).toHaveLength(0);
    }
    const off = makeApp("APPLIED", { restKey: false });
    expect((await hook(off.app)).status).toBe(200);
    expect(off.push.calls).toHaveLength(0);
  });

  it("a failing OneSignal never fails the webhook", async () => {
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    const gw = {
      linkFind: vi.fn(async () => ({ owner_id: OWNER, account_id: "acc" })),
      readCategories: vi.fn(async () => [{ id: "cat-in", name: "Khác", type: "INCOME" }]),
      ingestBankEvent: vi.fn(async () => ({ status: "APPLIED" })),
    } as unknown as FinanceGateway;
    const boom = (async () => {
      throw new Error("down");
    }) as typeof fetch;
    const app = buildApp(() => ({ cfg, gw, verifier: {} as SessionVerifier, pushFetch: boom }));
    const res = await hook(app);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true });
  });
});
