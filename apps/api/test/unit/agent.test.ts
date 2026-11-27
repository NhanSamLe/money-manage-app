import { describe, expect, it } from "vitest";
import { resolveAgentOutput, buildAgentMessages, type AgentContext } from "../../src/modules/ai/agent";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const ctx: AgentContext = {
  today: "2026-11-27",
  nowIso: "2026-11-27T03:00:00.000Z",
  accounts: [
    { id: U(1), name: "Tiền mặt", kind: "CASH", balance: "500000" },
    { id: U(2), name: "Vietcombank", kind: "BANK", balance: "9000000" },
  ],
  categories: [
    { id: U(10), name: "Ăn uống", type: "EXPENSE" },
    { id: U(11), name: "Lương", type: "INCOME" },
  ],
  contacts: [{ id: U(20), alias: "Nam" }],
  debts: [{ id: U(30), direction: "RECEIVABLE", contact_alias: "Nam", remaining: "500000", state: "OPEN" }],
  goals: [{ id: U(40), name: "Laptop", target: "30000000", allocated: "0" }],
  defaultAccountId: U(1),
  lastTx: { id: U(50), version: 1 },
};
const run = (steps: unknown[]) => resolveAgentOutput({ reply: "ok", steps }, ctx);

describe("agent plan resolution", () => {
  it("turns one sentence into several validated low-risk commands", () => {
    const r = run([
      { do: "EXPENSE", amount: "30000", account: U(1), category: U(10), date: "2026-11-27", note: "cà phê" },
      { do: "EXPENSE", amount: 65000, account: null, category: U(10), date: "2026-11-27" },
      { do: "INCOME", amount: "15.000.000", account: U(2), category: U(11) },
    ]);
    expect(r.actions.map((a) => a.type)).toEqual(["COMMAND", "COMMAND", "COMMAND"]);
    const second = r.actions[1]!;
    if (second.type === "COMMAND") {
      expect(second.command.payload["account_id"]).toBe(U(1)); // default account fills the gap
      expect(second.risk).toBe("low");
    }
    const third = r.actions[2]!;
    if (third.type === "COMMAND") expect(third.command.payload["amount"]).toBe("15000000");
  });

  it("never guesses: missing amount, unknown ids and wrong category kind become questions", () => {
    const r = run([
      { do: "EXPENSE", account: U(1), category: U(10) },
      { do: "EXPENSE", amount: "1000", account: U(1), category: "nope" },
      { do: "EXPENSE", amount: "1000", account: U(1), category: U(11) },
      { do: "TRANSFER", amount: "1000", from: U(1), to: U(1) },
      { do: "EXPENSE", amount: "1000", account: U(1), category: U(10), date: "2030-01-01" },
    ]);
    expect(r.actions.every((a) => a.type === "ASK")).toBe(true);
  });

  it("lending to a new person chains a contact first and is high risk", () => {
    const r = run([{ do: "LEND", amount: "500000", who: "Hùng", contact: null, account: U(1), date: "2026-11-26" }]);
    const a = r.actions[0]!;
    expect(a.type).toBe("COMMAND");
    if (a.type === "COMMAND") {
      expect(a.risk).toBe("high");
      expect(a.pre?.command_type).toBe("CONTACT_CREATE");
      expect(a.command.payload["contact_id"]).toBe("$contact_id");
    }
  });

  it("lending to a known contact reuses it and a historical loan needs no account", () => {
    const r = run([{ do: "LEND", amount: "200000", who: "nam", account: null }]);
    const a = r.actions[0]!;
    if (a.type === "COMMAND") {
      expect(a.pre).toBeUndefined();
      expect(a.command.payload["contact_id"]).toBe(U(20));
      expect(a.command.payload["historical"]).toBe(true);
    }
  });

  it("repaying a debt, saving to a goal, budgets and cancel work against real ids", () => {
    const r = run([
      { do: "REPAY_DEBT", debt: U(30), amount: "200000", account: U(1) },
      { do: "SAVE_GOAL", goal: U(40), amount: "300000", account: U(2) },
      { do: "SET_BUDGET", category: U(10), limit: "3000000", month: "2026-11" },
      { do: "CANCEL_LAST" },
      { do: "REPAY_DEBT", debt: "unknown", amount: "1000" },
    ]);
    expect(r.actions.slice(0, 4).every((a) => a.type === "COMMAND")).toBe(true);
    expect(r.actions[4]!.type).toBe("ASK");
    const cancel = r.actions[3]!;
    if (cancel.type === "COMMAND") expect(cancel.command.payload["tx_id"]).toBe(U(50));
  });

  it("answers are routed, unknown actions and garbage are rejected", () => {
    expect(run([{ do: "ANSWER", what: "SUMMARY", month: "2026-10" }])).toMatchObject({ actions: [{ type: "ANSWER", what: "SUMMARY", month: "2026-10" }] });
    expect(resolveAgentOutput({ steps: [{ do: "DROP_TABLE" }] }, ctx).actions[0]!.type).toBe("ASK");
    expect(resolveAgentOutput("hello", ctx).actions[0]!.type).toBe("ASK");
    expect(resolveAgentOutput({ steps: new Array(20).fill({ do: "CANCEL_LAST" }) }, ctx).actions[0]!.type).toBe("ASK");
  });

  it("the prompt carries only ids and names, never balances or emails", () => {
    const { messages } = buildAgentMessages("ăn trưa 65k", [], ctx);
    const body = messages[1]!.content;
    expect(body).toContain(U(1));
    expect(body).not.toContain("9000000");
    expect(body).not.toMatch(/@/);
  });
});
