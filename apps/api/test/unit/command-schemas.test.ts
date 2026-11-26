import { describe, expect, it } from "vitest";
import { IMPLEMENTED_TYPES, KNOWN_TYPES, implementedCommand } from "../../src/modules/ledger/command-schemas";

const ID = "55555555-5555-5555-5555-555555555501";
const U = "44444444-4444-4444-4444-444444444444";
const wrap = (command_type: string, payload: unknown) => ({ command_id: ID, command_type, schema_version: 1, payload });
const valid = (c: unknown) => implementedCommand.safeParse(c).success;

describe("command schemas", () => {
  it("every implemented command is part of the published catalogue", () => {
    for (const t of IMPLEMENTED_TYPES) expect(KNOWN_TYPES.has(t), t).toBe(true);
    expect(IMPLEMENTED_TYPES.size).toBe(19);
  });

  it("rejects floating point and padded money everywhere", () => {
    for (const amount of ["12.5", "012", "-5", "1e3", " 5"]) {
      expect(valid(wrap("GOAL_CREATE", { name: "x", target: amount })), amount).toBe(false);
    }
  });

  it("requires an account for non-historical debts", () => {
    const base = { direction: "RECEIVABLE", contact_id: U, principal: "500000", originated_at: "2026-11-20T03:00:00Z" };
    expect(valid(wrap("DEBT_CREATE", base))).toBe(false);
    expect(valid(wrap("DEBT_CREATE", { ...base, account_id: U }))).toBe(true);
    expect(valid(wrap("DEBT_CREATE", { ...base, historical: true }))).toBe(true);
  });

  it("allows zero interest but never negative", () => {
    const base = { debt_id: U, account_id: U, principal: "1000", effective_at: "2026-11-25T03:00:00Z", expected_version: 1 };
    expect(valid(wrap("DEBT_REPAY", { ...base, interest: "0" }))).toBe(true);
    expect(valid(wrap("DEBT_REPAY", { ...base, interest: "-1" }))).toBe(false);
  });

  it("requires expected_version for updates but not creates", () => {
    expect(valid(wrap("CATEGORY_UPSERT", { name: "A", type: "EXPENSE" }))).toBe(true);
    expect(valid(wrap("CATEGORY_UPSERT", { name: "A", type: "EXPENSE", category_id: U }))).toBe(false);
    expect(valid(wrap("CATEGORY_UPSERT", { name: "A", type: "EXPENSE", category_id: U, expected_version: 1 }))).toBe(true);
  });

  it("rejects unknown fields (strict payloads)", () => {
    expect(valid(wrap("GOAL_CREATE", { name: "x", target: "1000", extra: 1 }))).toBe(false);
  });

  it("validates budget months", () => {
    expect(valid(wrap("BUDGET_UPSERT", { month: "2026-11", limit: "1000", carryover: false }))).toBe(true);
    expect(valid(wrap("BUDGET_UPSERT", { month: "2026-13", limit: "1000", carryover: false }))).toBe(false);
  });
});
