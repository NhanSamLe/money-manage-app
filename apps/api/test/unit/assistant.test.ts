import { describe, expect, it } from "vitest";
import { actualMicro, estimateMicro, parseModelJson, resolveOutput, buildMessages } from "../../src/modules/ai/assistant";

const accounts = [{ id: "a1", name: "Tiền mặt", kind: "CASH" }];
const categories = [
  { id: "c1", name: "Ăn uống", type: "EXPENSE" },
  { id: "c2", name: "Lương", type: "INCOME" },
];
const ctx = { today: "2026-11-27", nowIso: "2026-11-27T03:00:00.000Z", accounts, categories };

describe("assistant output handling", () => {
  it("accepts a consistent expense proposal", () => {
    const r = resolveOutput({ action: "CREATE_TX", kind: "EXPENSE", amount_vnd: "65000", account_id: "a1", category_id: "c1", date: "2026-11-27", note: "ăn trưa" }, ctx);
    expect(r.type).toBe("proposal");
    if (r.type === "proposal") {
      expect(r.proposal.amount_vnd).toBe("65000");
      expect(r.proposal.effective_at).toBe(ctx.nowIso);
    }
  });
  it("turns relative past dates into local noon", () => {
    const r = resolveOutput({ action: "CREATE_TX", amount_vnd: 50000, account_id: "a1", category_id: "c1", date: "2026-11-26" }, ctx);
    expect(r.type === "proposal" && r.proposal.effective_at).toBe("2026-11-26T05:00:00.000Z");
  });
  it("never guesses: unknown ids, missing amount or wrong kind become questions", () => {
    expect(resolveOutput({ action: "CREATE_TX", amount_vnd: "1000", account_id: "zzz", category_id: "c1" }, ctx).type).toBe("ask");
    expect(resolveOutput({ action: "CREATE_TX", account_id: "a1", category_id: "c1" }, ctx).type).toBe("ask");
    expect(resolveOutput({ action: "CREATE_TX", kind: "INCOME", amount_vnd: "1000", account_id: "a1", category_id: "c1" }, ctx).type).toBe("ask");
    expect(resolveOutput({ action: "CREATE_TX", amount_vnd: "-5", account_id: "a1", category_id: "c1" }, ctx).type).toBe("ask");
    expect(resolveOutput({ action: "CREATE_TX", amount_vnd: "1000", account_id: "a1", category_id: "c1", date: "2027-05-01" }, ctx).type).toBe("ask");
  });
  it("rejects garbage from the provider as a question, not an action", () => {
    expect(resolveOutput({ action: "DROP_TABLE" }, ctx).type).toBe("ask");
    expect(resolveOutput("hello", ctx).type).toBe("ask");
  });
  it("routes summaries with a valid month only", () => {
    expect(resolveOutput({ action: "QUERY_SUMMARY", month: "2026-10" }, ctx)).toEqual({ type: "query_summary", month: "2026-10" });
    expect(resolveOutput({ action: "QUERY_SUMMARY", month: "bad" }, ctx)).toEqual({ type: "query_summary", month: "2026-11" });
  });
  it("strips provider control tokens and extracts the JSON object", () => {
    expect(parseModelJson('xx {"action":<|endoftext|>"NONE"} yy')).toEqual({ action: "NONE" });
    expect(() => parseModelJson("no json")).toThrow();
  });
  it("reserves at least the real cost", () => {
    const { bytes } = buildMessages("ăn trưa 65k", "2026-11-27", accounts, categories);
    expect(estimateMicro(bytes)).toBeGreaterThan(actualMicro({ prompt_tokens: bytes, completion_tokens: 400 }) - 1);
  });
});
