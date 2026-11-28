import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import { personalizeMealPush, routineMissedPush } from "../../src/entrypoints/routes-agent";
import { missedDaily, optionText, routineOptions, slotOf, slotRecorded, usualMinute, type RoutineTx } from "../../src/modules/ai/routine";
import { decidePushes } from "../../src/modules/reminders/schedule";
import { DEFAULT_SETTINGS } from "../../src/modules/reminders/settings";
import type { SessionVerifier } from "../../src/modules/auth/verify-session";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const CASH = U(1);
const MOMO = U(2);
const FOOD = U(10);
const PARK = U(11);
let seq = 100;
/** A purchase at local Vietnam time `hhmm` on `day` (YYYY-MM-DD). */
const buy = (day: string, hhmm: string, label: string, amount: number, account = CASH, category = FOOD, over: Partial<RoutineTx> = {}): RoutineTx => ({
  id: U(seq++), kind: "EXPENSE", status: "POSTED", amount: String(amount),
  effective_at: new Date(Date.parse(`${day}T${hhmm}:00+07:00`)).toISOString(), account_id: account, category_id: category, merchant: null, note: label, ...over,
});
const day = (n: number) => new Date(Date.parse("2026-11-28T00:00:00Z") - n * 86_400_000).toISOString().slice(0, 10);

// 20 days of history: bánh mì almost every morning (cash), cà phê sữa most mornings (MoMo), phở twice,
// cơm trưa every day, gửi xe every day.
const HISTORY: RoutineTx[] = [];
for (let i = 1; i <= 20; i++) {
  HISTORY.push(buy(day(i), "07:10", "Bánh mì", i % 5 === 0 ? 25000 : 20000));
  if (i % 3 !== 0) HISTORY.push(buy(day(i), "07:40", "Cà phê sữa", 25000, MOMO));
  if (i === 4 || i === 11) HISTORY.push(buy(day(i), "08:00", "Phở bò", 50000));
  HISTORY.push(buy(day(i), "12:05", "Cơm trưa", 40000));
  HISTORY.push(buy(day(i), "18:30", "Gửi xe", 5000, CASH, PARK));
}
// A bank row with an opaque note never becomes a routine.
HISTORY.push(buy(day(2), "07:30", "CT DEN:202611270012345 MBVCB", 20000));

const NOW_MORNING = new Date("2026-11-28T01:30:00Z"); // 08:30 Saturday in Vietnam

describe("routine learning", () => {
  it("slots follow Vietnam-local time", () => {
    expect(slotOf("2026-11-28T00:10:00Z")).toBe("breakfast"); // 07:10
    expect(slotOf("2026-11-28T05:05:00Z")).toBe("lunch"); // 12:05
    expect(slotOf("2026-11-28T11:30:00Z")).toBe("dinner"); // 18:30
    expect(slotOf("2026-11-28T16:00:00Z")).toBeNull(); // 23:00
  });

  it("ranks the usual breakfast answers with typical price and account; one-offs and bank rows stay out", () => {
    const o = routineOptions(HISTORY, "breakfast", NOW_MORNING);
    expect(o.map((x) => x.label)).toEqual(["Bánh mì", "Cà phê sữa"]);
    expect(o[0]).toEqual(expect.objectContaining({ amount: 20000, account_id: CASH, category_id: FOOD, days: 20 }));
    expect(o[1]).toEqual(expect.objectContaining({ amount: 25000, account_id: MOMO }));
    expect(routineOptions(HISTORY, "lunch", NOW_MORNING)[0]?.label).toBe("Cơm trưa");
  });

  it("knows when the slot is already recorded today (any source) and the usual time", () => {
    expect(slotRecorded(HISTORY, "breakfast", NOW_MORNING)).toBe(false);
    const withToday = [...HISTORY, buy("2026-11-28", "07:05", "x", 30000, CASH, FOOD, { kind: "UNKNOWN_DEBIT", category_id: null })];
    expect(slotRecorded(withToday, "breakfast", NOW_MORNING)).toBe(true);
    // 20 x bánh mì 07:10, 14 x cà phê 07:40, phở 08:00, bank row 07:30 -> median 07:10.
    expect(usualMinute(HISTORY, "breakfast", NOW_MORNING)).toBe(7 * 60 + 10);
    expect(usualMinute([], "breakfast", NOW_MORNING)).toBeNull();
  });

  it("missed daily items: yesterday without gửi xe / cơm trưa -> nudge; recorded ones are not", () => {
    const yesterday = day(1);
    const partial = HISTORY.filter((t) => !(t.effective_at.startsWith(yesterday) || new Date(Date.parse(t.effective_at) + 7 * 3_600_000).toISOString().startsWith(yesterday)) || t.note === "Bánh mì");
    const m = missedDaily(partial, yesterday, NOW_MORNING);
    expect(m.map((x) => x.label).sort()).toEqual(["Cơm trưa", "Gửi xe"]);
    expect(missedDaily(HISTORY, yesterday, NOW_MORNING)).toEqual([]);
  });

  it("button text stays short", () => {
    expect(optionText({ label: "Bánh mì", amount: 20000 })).toBe("Bánh mì 20k");
    expect(optionText({ label: "Cà phê sữa đá Highlands", amount: 45000 }).length).toBeLessThanOrEqual(22);
  });
});

function fakeGw(txs: RoutineTx[]) {
  return {
    getOwnerId: vi.fn(async () => U(900)),
    readTransactions: vi.fn(async () => [...txs].sort((a, b) => b.effective_at.localeCompare(a.effective_at)).slice(0, 100)),
    readAccounts: vi.fn(async () => [{ id: CASH }, { id: MOMO }]),
    executeCommand: vi.fn(async () => ({ status: "COMMITTED", tx_id: U(777) })),
  } as unknown as FinanceGateway & { executeCommand: ReturnType<typeof vi.fn> };
}

describe("meal push becomes one-tap", () => {
  const base = decidePushes({ now: new Date("2026-11-28T02:40:00Z"), settings: DEFAULT_SETTINGS, status: { date: "2026-11-28", skipped: [], done: { breakfast: false, lunch: false, dinner: false } } });
  const meal = base.find((p) => p.type === "meal")!;

  it("asks 'Sáng nay bạn ăn gì?' with the two usual answers + 'Hôm nay không'", async () => {
    expect(meal.type).toBe("meal");
    if (meal.type !== "meal") return;
    const p = await personalizeMealPush(fakeGw(HISTORY), U(900), meal, NOW_MORNING);
    expect(p.title).toBe("Sáng nay bạn ăn gì?");
    expect(p.body).toContain("Bánh mì 20.000đ");
    expect(p.buttons.map((b) => b.text)).toEqual(["Bánh mì 20k", "Cà phê sữa 25k", "Hôm nay không"]);
    expect(p.buttons[0]!.id).toBe("rt_breakfast_banh-mi");
    expect((p.data.routine as any).options).toHaveLength(2);
  });

  it("keeps the plain reminder when nothing is learned or reading fails; skipped/recorded meals are not pushed at all", async () => {
    if (meal.type !== "meal") return;
    expect(await personalizeMealPush(fakeGw([]), U(900), meal, NOW_MORNING)).toEqual(meal);
    const broken = { readTransactions: vi.fn(async () => Promise.reject(new Error("x"))) } as unknown as FinanceGateway;
    expect(await personalizeMealPush(broken, U(900), meal, NOW_MORNING)).toEqual(meal);
    const status = { date: "2026-11-28", skipped: ["breakfast"], done: { breakfast: false, lunch: false, dinner: false } };
    expect(decidePushes({ now: new Date("2026-11-28T02:40:00Z"), settings: DEFAULT_SETTINGS, status }).some((x) => x.type === "meal")).toBe(false);
    const muted = { ...DEFAULT_SETTINGS, meals: { ...DEFAULT_SETTINGS.meals, breakfast: { enabled: false, time: "09:30" } } };
    expect(decidePushes({ now: new Date("2026-11-28T02:40:00Z"), settings: muted, status: { ...status, skipped: [] } }).some((x) => x.type === "meal")).toBe(false);
  });

  it("morning nudge only in the morning and only for missed daily items", async () => {
    const yesterday = day(1);
    const partial = HISTORY.filter((t) => !new Date(Date.parse(t.effective_at) + 7 * 3_600_000).toISOString().startsWith(yesterday) || t.note !== "Gửi xe");
    const m = await routineMissedPush(fakeGw(partial), U(900), NOW_MORNING);
    expect(m?.key).toBe(`routine_missed:${yesterday}`);
    expect(m?.title).toBe("Hôm qua bạn chưa ghi gửi xe?");
    expect(m?.buttons[0]).toEqual({ id: `rtm_${yesterday}`, text: "Ghi" });
    expect(await routineMissedPush(fakeGw(partial), U(900), new Date("2026-11-28T08:00:00Z"))).toBeNull(); // 15:00
    expect(await routineMissedPush(fakeGw(HISTORY), U(900), NOW_MORNING)).toBeNull();
  });
});

describe("routine endpoints", () => {
  const cfg: Config = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000 };
  const headers = { authorization: "Bearer t", "x-device-id": "44444444-4444-4444-4444-444444444444", "content-type": "application/json" };
  const verifier = { verify: vi.fn(async () => ({ userId: U(900), sessionId: "33333333-3333-3333-3333-333333333333" })) } as unknown as SessionVerifier;

  it("GET returns the slot's options; POST records the tapped one once (same id on a second tap) with its undo", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(NOW_MORNING);
    try {
      const gw = fakeGw(HISTORY);
      const app = buildApp(() => ({ cfg, gw, verifier }) as never);
      const g = (await (await app.request("/v1/ai/routine?slot=now", { headers }, {} as never)).json()) as any;
      expect(g.data.slot).toBe("breakfast");
      expect(g.data.recorded).toBe(false);
      expect(g.data.options.map((o: any) => o.label)).toEqual(["Bánh mì", "Cà phê sữa"]);

      const post = () => app.request("/v1/ai/routine/record", { method: "POST", headers, body: JSON.stringify({ slot: "breakfast", keys: ["banh-mi"] }) }, {} as never);
      const r = (await (await post()).json()) as any;
      expect(r.data.message).toBe("Đã ghi Bánh mì 20.000đ");
      expect(r.data.recorded[0].undo).toEqual({ ops: [{ op: "REVERSE_TX", tx_id: U(777) }] });
      const cmd = (gw.executeCommand.mock.calls[0] as unknown[])[3] as any;
      expect(cmd.payload).toEqual(expect.objectContaining({ kind: "EXPENSE", account_id: CASH, amount: "20000", category_id: FOOD, note: "Bánh mì", source: "AI" }));
      await post();
      expect(((gw.executeCommand.mock.calls[1] as unknown[])[3] as any).command_id).toBe(cmd.command_id);

      const bad = await app.request("/v1/ai/routine/record", { method: "POST", headers, body: JSON.stringify({ slot: "breakfast", keys: ["lau-de"] }) }, {} as never);
      expect(bad.status).toBe(404);
    } finally {
      vi.useRealTimers();
    }
  });
});
