import { describe, expect, it } from "vitest";
import { canonicalJson, sha256Hex } from "../../src/shared/canonical";
import { MAX_VND, formatVnd, parseMoney } from "../../src/shared/money";
import { currentVnMonth, monthRangeUtc } from "../../src/shared/report-period";

describe("money", () => {
  it("parses positive integers as bigint", () => {
    expect(parseMoney("65000", { positive: true })).toBe(65000n);
    expect(parseMoney("9000000000000000", { positive: true })).toBe(MAX_VND);
  });
  it("rejects zero, negatives (when positive), decimals, overflow and junk", () => {
    for (const bad of ["0", "-1", "1.5", "1e3", "", " 1", "9000000000000001", "12345678901234567"]) {
      expect(() => parseMoney(bad, { positive: true }), bad).toThrow(RangeError);
    }
  });
  it("allows signed amounts for opening balances", () => {
    expect(parseMoney("-250000", { positive: false })).toBe(-250000n);
    expect(parseMoney("0", { positive: false })).toBe(0n);
  });
  it("formats VND with dot separators", () => {
    expect(formatVnd(1250000n)).toBe("1.250.000 ₫");
    expect(formatVnd(-65000n)).toBe("-65.000 ₫");
    expect(formatVnd(0n)).toBe("0 ₫");
  });
});

describe("canonical hash", () => {
  it("is independent of key order", async () => {
    const a = await sha256Hex(canonicalJson({ b: 1, a: { d: [1, 2], c: "x" } }));
    const b = await sha256Hex(canonicalJson({ a: { c: "x", d: [1, 2] }, b: 1 }));
    expect(a).toBe(b);
  });
  it("changes when content changes", async () => {
    expect(await sha256Hex(canonicalJson({ amount: "1" }))).not.toBe(await sha256Hex(canonicalJson({ amount: "2" })));
  });
});

describe("report period (Asia/Ho_Chi_Minh, half-open)", () => {
  it("maps a month to UTC boundaries", () => {
    expect(monthRangeUtc("2026-11")).toEqual({ from: "2026-10-31T17:00:00.000Z", to: "2026-11-30T17:00:00.000Z" });
  });
  it("rolls over December", () => {
    expect(monthRangeUtc("2026-12").to).toBe("2026-12-31T17:00:00.000Z");
  });
  it("rejects invalid months", () => {
    for (const bad of ["2026-13", "2026-00", "26-11", "2026/11", ""]) expect(() => monthRangeUtc(bad), bad).toThrow();
  });
  it("computes the current Vietnam month across the UTC day boundary", () => {
    expect(currentVnMonth(new Date("2026-11-30T17:30:00Z"))).toBe("2026-12");
    expect(currentVnMonth(new Date("2026-11-30T16:30:00Z"))).toBe("2026-11");
  });
});
