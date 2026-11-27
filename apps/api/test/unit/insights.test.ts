import { describe, expect, it } from "vitest";
import {
  budgetTarget,
  changePct,
  computeNumbers,
  ensureLimitSuggestion,
  forecast,
  historyBuckets,
  median,
  parseAiText,
  periodBounds,
  ruleText,
  suggestLimit,
  type PeriodStats,
} from "../../src/modules/insights/analysis";

const stats = (expense: number, income = 0, by: [string, number][] = [], daily: [string, number][] = []): PeriodStats => ({
  income: String(income),
  expense: String(expense),
  by_category: by.map(([name, amount]) => ({ category_id: `id-${name}`, name, amount: String(amount) })),
  daily: daily.map(([day, e]) => ({ day, income: "0", expense: String(e) })),
});

describe("period bounds", () => {
  it("week in progress: Monday start, same elapsed days last week, 4 weeks of history", () => {
    const b = periodBounds("WEEK", "2026-11-28", "2026-11-28");
    expect(b).toMatchObject({ start: "2026-11-23", end: "2026-11-29", asOf: "2026-11-28", elapsed: 6, total: 7, inProgress: true });
    expect(b).toMatchObject({ prevStart: "2026-11-16", prevEnd: "2026-11-21", histStart: "2026-10-26", histEnd: "2026-11-22" });
  });
  it("month: previous month to the same day, 3 full months of history", () => {
    const b = periodBounds("MONTH", "2026-03-30", "2026-03-30");
    expect(b).toMatchObject({ start: "2026-03-01", end: "2026-03-31", elapsed: 30, total: 31, prevStart: "2026-02-01", prevEnd: "2026-02-28", histStart: "2025-12-01", histEnd: "2026-02-28" });
  });
  it("finished week is not in progress", () => {
    expect(periodBounds("WEEK", "2026-11-22", "2026-11-28")).toMatchObject({ start: "2026-11-16", asOf: "2026-11-22", elapsed: 7, inProgress: false });
  });
  it("day compares with yesterday and keeps 14 days of history", () => {
    const b = periodBounds("DAY", "2026-11-28", "2026-11-28");
    expect(b).toMatchObject({ start: "2026-11-28", end: "2026-11-28", prevStart: "2026-11-27", histStart: "2026-11-14", histEnd: "2026-11-27" });
    expect(historyBuckets(b, [])).toHaveLength(14);
  });
});

describe("math", () => {
  it("median, change and linear forecast", () => {
    expect(median([])).toBeNull();
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(changePct(150, 100)).toBe(50);
    expect(changePct(1, 3)).toBe(-66.7);
    expect(changePct(5, 0)).toBeNull();
    expect(forecast(600_000, 6, 7, true)).toBe(700_000);
    expect(forecast(600_000, 7, 7, false)).toBe(600_000);
  });

  it("suggested limit = median of tracked periods, moved halfway toward a lower budget, rounded up to 10k", () => {
    expect(suggestLimit([1_000_000, 1_200_000, 0, 1_100_000], null)).toBe(1_100_000);
    expect(suggestLimit([1_000_000, 1_200_000, 1_100_000, 1_300_000], 900_000)).toBe(1_030_000); // (1.15M + 0.9M)/2 = 1.025M -> 1.03M
    expect(suggestLimit([500_000, 600_000], 900_000)).toBe(550_000); // under budget: keep the habit
    expect(suggestLimit([0, 0], 812_345)).toBe(820_000); // no history: budget target
    expect(suggestLimit([], null)).toBeNull();
  });

  it("budget target scales the month budget to the period", () => {
    const b = [{ category_id: null, limit_amount: "6000000", spent: "0" }, { category_id: "c", limit_amount: "1000000", spent: "0" }];
    expect(budgetTarget("MONTH", b, "2026-11")).toBe(6_000_000);
    expect(budgetTarget("WEEK", b, "2026-11")).toBe(1_400_000);
    expect(budgetTarget("DAY", b, "2026-11")).toBe(200_000);
    expect(budgetTarget("MONTH", [{ category_id: "c", limit_amount: "1000000", spent: "0" }], "2026-11")).toBe(1_000_000);
    expect(budgetTarget("MONTH", [], "2026-11")).toBeNull();
  });

  it("computes the insight numbers as integer strings", () => {
    const b = periodBounds("WEEK", "2026-11-28", "2026-11-28");
    const hist = stats(0, 0, [], [["2026-10-27", 1_000_000], ["2026-11-03", 1_200_000], ["2026-11-10", 900_000], ["2026-11-17", 1_100_000]]);
    const n = computeNumbers(b, stats(1_200_000, 3_000_000, [["Ăn uống", 800_000], ["Di chuyển", 400_000]]), stats(1_000_000, 0, [["Ăn uống", 500_000], ["Giải trí", 500_000]]), hist, []);
    expect(n).toMatchObject({ income: "3000000", expense: "1200000", net: "1800000", prev_expense: "1000000", change_pct: 20, forecast_expense: "1400000", suggested_limit: "1050000", daily_avg: "200000" });
    expect(n.by_category[0]).toEqual({ category_id: "id-Ăn uống", name: "Ăn uống", amount: "800000", prev_amount: "500000", change_pct: 60 });
    expect(n.by_category.find((c) => c.name === "Giải trí")).toMatchObject({ amount: "0", prev_amount: "500000", change_pct: -100 });
  });
});

describe("text", () => {
  const b = periodBounds("WEEK", "2026-11-28", "2026-11-28");
  const n = computeNumbers(
    b,
    stats(1_200_000, 300_000, [["Ăn uống", 800_000], ["Di chuyển", 400_000]]),
    stats(1_000_000, 0, [["Ăn uống", 500_000]]),
    stats(0, 0, [], [["2026-10-27", 1_000_000], ["2026-11-03", 1_200_000]]),
    [],
  );

  it("rule-based fallback is deterministic Vietnamese with 2-4 suggestions incl. the limit", () => {
    const t = ruleText(b, n, "2026-11-28", [{ category_id: null, category_name: "Tổng chi tiêu", limit_amount: "4000000", spent: "3500000" }]);
    expect(t.title).toBe("Tuần này: đã chi 1.200.000 đ");
    expect(t.summary).toBe(
      "Bạn đã chi 1.200.000 đ và thu 300.000 đ trong tuần này. Chi tiêu tăng 20% so với cùng kỳ tuần trước. Nếu giữ nhịp này, cả kỳ sẽ chi khoảng 1.400.000 đ.",
    );
    expect(t.highlights[0]).toBe("Chi nhiều nhất: Ăn uống 800.000 đ (67%).");
    expect(t.highlights).toContain("Ăn uống tăng 60% (500.000 đ lên 800.000 đ).");
    expect(t.highlights).toContain("Chi vượt thu 900.000 đ.");
    expect(t.suggestions[0]).toBe("Tuần sau nên giữ chi tiêu dưới 1.100.000 đ.");
    expect(t.suggestions.length).toBeGreaterThanOrEqual(2);
    expect(t.suggestions.length).toBeLessThanOrEqual(4);
    expect(JSON.stringify(t)).not.toMatch(/\p{Extended_Pictographic}/u);
  });

  it("an empty period still produces text", () => {
    const e = computeNumbers(periodBounds("DAY", "2026-11-28", "2026-11-28"), stats(0), stats(0), stats(0), []);
    const t = ruleText(periodBounds("DAY", "2026-11-28", "2026-11-28"), e, "2026-11-28");
    expect(t.title).toBe("Hôm nay: chưa có khoản chi nào");
    expect(t.suggestions.length).toBeGreaterThanOrEqual(1);
  });

  it("AI wording is validated, cleaned of emoji and always carries the computed limit", () => {
    const t = parseAiText({ title: "Tuần ổn 👍", summary: "Chi tăng nhẹ.", highlights: ["Ăn uống tăng"], suggestions: ["Nấu ăn ở nhà 2 bữa"] }, n, "Tuần sau");
    expect(t).toEqual({ title: "Tuần ổn", summary: "Chi tăng nhẹ.", highlights: ["Ăn uống tăng"], suggestions: ["Tuần sau nên giữ chi tiêu dưới 1.100.000 đ.", "Nấu ăn ở nhà 2 bữa"] });
    expect(parseAiText({ title: "x" }, n, "Tuần sau")).toBeNull();
    const kept = ensureLimitSuggestion({ title: "a", summary: "b", highlights: ["c"], suggestions: ["Giữ dưới 1.100.000 đ"] }, n, "Tuần sau");
    expect(kept.suggestions).toEqual(["Giữ dưới 1.100.000 đ"]);
  });
});
