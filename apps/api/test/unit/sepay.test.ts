import { describe, expect, it } from "vitest";
import { eventKey, hmacHex, parseWebhook, ruleCategory, verifyWebhook, vnToIso } from "../../src/modules/bank/sepay";

const cats = [
  { id: "a", name: "Ăn uống", type: "EXPENSE" },
  { id: "b", name: "Di chuyển", type: "EXPENSE" },
  { id: "c", name: "Khác", type: "EXPENSE" },
  { id: "d", name: "Lương", type: "INCOME" },
  { id: "e", name: "Khác", type: "INCOME" },
];

describe("SePay webhook authentication", () => {
  const body = '{"id":1}';
  it("accepts the shared API key and nothing else", async () => {
    const h = (v: string) => new Headers({ authorization: v });
    expect(await verifyWebhook(h("Apikey secret-1"), body, { apiKey: "secret-1" })).toBe(true);
    expect(await verifyWebhook(h("Apikey nope"), body, { apiKey: "secret-1" })).toBe(false);
    expect(await verifyWebhook(h("Bearer secret-1"), body, { apiKey: "secret-1" })).toBe(false);
    expect(await verifyWebhook(new Headers(), body, { apiKey: "secret-1" })).toBe(false);
  });
  it("fails closed when nothing is configured", async () => {
    expect(await verifyWebhook(new Headers({ authorization: "Apikey x" }), body, {})).toBe(false);
  });
  it("verifies HMAC over timestamp.rawBody and rejects stale or tampered requests", async () => {
    const now = 1_800_000_000;
    const sig = `sha256=${await hmacHex("k", `${now}.${body}`)}`;
    const ok = new Headers({ "x-sepay-signature": sig, "x-sepay-timestamp": String(now) });
    expect(await verifyWebhook(ok, body, { hmacSecret: "k" }, now + 10)).toBe(true);
    expect(await verifyWebhook(ok, body + " ", { hmacSecret: "k" }, now + 10)).toBe(false);
    expect(await verifyWebhook(ok, body, { hmacSecret: "k" }, now + 1000)).toBe(false);
    expect(await verifyWebhook(ok, body, { hmacSecret: "other" }, now + 10)).toBe(false);
  });
});

describe("SePay payloads", () => {
  const p = { id: 92704, gateway: "Vietcombank", transactionDate: "2026-11-27 11:08:33", accountNumber: "1017588888", content: "NGUYEN VAN A chuyen tien", transferType: "in", transferAmount: 5000000, accumulated: 105000000, referenceCode: "FT24012345678" };
  it("parses an incoming transfer with the Vietnam time zone", async () => {
    const e = await parseWebhook(p);
    expect(e).toMatchObject({ direction: "in", amount: 5000000, balance: 105000000, atIso: "2026-11-27T04:08:33.000Z" });
  });
  it("rejects malformed events instead of guessing", async () => {
    expect(await parseWebhook({ ...p, transferAmount: -5 })).toBeNull();
    expect(await parseWebhook({ ...p, transferAmount: 1.5 })).toBeNull();
    expect(await parseWebhook({ ...p, transferType: "sideways" })).toBeNull();
    expect(await parseWebhook({ ...p, transactionDate: "yesterday" })).toBeNull();
    expect(await parseWebhook("x")).toBeNull();
  });
  it("identity comes from the bank reference so webhook and polling never double-post", async () => {
    const a = await eventKey("SEPAY", "1017588888", "FT24012345678", "in", 5000000, "2026-11-27T04:08:33.000Z", 92704);
    const b = await eventKey("SEPAY", "1017588888", "FT24012345678", "in", 5000000, "2026-11-27T04:08:33.000Z", "uuid-from-api");
    expect(a).toBe(b);
    const c = await eventKey("SEPAY", "1017588888", "", "in", 5000000, "2026-11-27T04:08:33.000Z", 92704);
    expect(c).not.toBe(a);
  });
  it("vnToIso handles only the documented format", () => {
    expect(vnToIso("2026-11-27 00:00:00")).toBe("2026-11-26T17:00:00.000Z");
    expect(vnToIso("27/11/2026")).toBeNull();
  });
});

describe("keyword classification fallback", () => {
  it("maps common memos to categories of the right type", () => {
    expect(ruleCategory("GRAB*TRIP HA NOI", "out", cats)).toBe("b");
    expect(ruleCategory("CAFE HIGHLANDS", "out", cats)).toBe("a");
    expect(ruleCategory("LUONG THANG 11", "in", cats)).toBe("d");
  });
  it("falls back to Khác of the same direction, never the wrong type", () => {
    expect(ruleCategory("random memo", "out", cats)).toBe("c");
    expect(ruleCategory("random memo", "in", cats)).toBe("e");
    expect(ruleCategory("LUONG", "out", cats)).not.toBe("d");
  });
});
