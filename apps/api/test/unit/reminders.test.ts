import { describe, expect, it, vi } from "vitest";
import { sendPush } from "../../src/modules/push/onesignal";
import { decidePushes, localClock, reviewKey, type DayStatus } from "../../src/modules/reminders/schedule";
import { DEFAULT_SETTINGS, ReminderSettingsPatch, resolveSettings } from "../../src/modules/reminders/settings";

// Local time = UTC+7. 2026-11-28 is a Saturday; 2026-11-29 a Sunday; 2026-11-30 the last day of November (Monday).
const at = (local: string) => new Date(`${local}:00+07:00`);
const status = (over: Partial<DayStatus> = {}): DayStatus => ({
  date: "2026-11-28",
  skipped: [],
  done: { breakfast: false, lunch: false, dinner: false },
  has_accounts: true,
  ...over,
});
const keys = (p: { key: string }[]) => p.map((x) => x.key);

describe("local clock", () => {
  it("converts to Asia/Ho_Chi_Minh", () => {
    expect(localClock(new Date("2026-11-28T17:30:00Z"))).toMatchObject({ date: "2026-11-29", minutes: 30, weekday: 7, month: "2026-11", lastDayOfMonth: false });
    expect(localClock(at("2026-11-30T20:00")).lastDayOfMonth).toBe(true);
  });
});

describe("settings", () => {
  it("defaults when nothing is stored", () => {
    expect(resolveSettings(null)).toEqual(DEFAULT_SETTINGS);
    expect(DEFAULT_SETTINGS.meals.breakfast).toEqual({ enabled: true, time: "09:30" });
    expect(DEFAULT_SETTINGS.weekly_review).toEqual({ enabled: true, weekday: 7, time: "20:00" });
  });
  it("merges partial stored documents and patches, ignores unknown keys", () => {
    const s = resolveSettings({ meals: { lunch: { time: "12:15" } }, extra: 1 }, { cash_check: { enabled: false } });
    expect(s.meals.lunch).toEqual({ enabled: true, time: "12:15" });
    expect(s.cash_check.enabled).toBe(false);
    expect(s).not.toHaveProperty("extra");
  });
  it("falls back to defaults when the stored document is corrupt", () => {
    expect(resolveSettings({ meals: { lunch: { time: "25:99" } } }).meals.lunch.time).toBe("13:00");
  });
  it("validates times and weekdays", () => {
    expect(ReminderSettingsPatch.safeParse({ meals: { dinner: { time: "7:00" } } }).success).toBe(false);
    expect(ReminderSettingsPatch.safeParse({ weekly_review: { weekday: 8 } }).success).toBe(false);
    expect(ReminderSettingsPatch.safeParse({ weekly_review: { weekday: 1, time: "08:00" } }).success).toBe(true);
  });
});

describe("decidePushes", () => {
  it("sends nothing before the reminder time", () => {
    expect(decidePushes({ now: at("2026-11-28T09:00"), settings: DEFAULT_SETTINGS, status: status() })).toEqual([]);
  });

  it("reminds about breakfast with action buttons once the time has passed", () => {
    const p = decidePushes({ now: at("2026-11-28T09:45"), settings: DEFAULT_SETTINGS, status: status() });
    expect(p).toHaveLength(1);
    expect(p[0]).toMatchObject({
      key: "meal:breakfast:2026-11-28",
      title: "Bạn ăn sáng chưa?",
      body: "Ghi lại bữa sáng để sổ chi tiêu luôn chính xác.",
      data: { type: "reminder", kind: "breakfast", route: "/quick-entry" },
      buttons: [{ id: "skip_breakfast", text: "Hôm nay không ăn" }, { id: "log", text: "Ghi ngay" }],
    });
  });

  it("skips meals that are already logged, skipped, claimed or disabled", () => {
    const now = at("2026-11-28T13:30");
    expect(keys(decidePushes({ now, settings: DEFAULT_SETTINGS, status: status() }))).toEqual(["meal:lunch:2026-11-28"]); // breakfast too late (grace)
    expect(decidePushes({ now, settings: DEFAULT_SETTINGS, status: status({ done: { breakfast: false, lunch: true, dinner: false } }) })).toEqual([]);
    expect(decidePushes({ now, settings: DEFAULT_SETTINGS, status: status({ skipped: ["lunch"] }) })).toEqual([]);
    expect(decidePushes({ now, settings: DEFAULT_SETTINGS, status: status(), claimed: new Set(["meal:lunch:2026-11-28"]) })).toEqual([]);
    const off = resolveSettings(null, { meals: { lunch: { enabled: false } } });
    expect(decidePushes({ now, settings: off, status: status() })).toEqual([]);
  });

  it("is quiet when the owner has no accounts yet", () => {
    expect(decidePushes({ now: at("2026-11-28T22:30"), settings: DEFAULT_SETTINGS, status: status({ has_accounts: false }) })).toEqual([]);
  });

  it("plans cash check, dinner and the daily review in the evening", () => {
    const p = decidePushes({ now: at("2026-11-28T22:05"), settings: DEFAULT_SETTINGS, status: status() });
    expect(keys(p)).toEqual(["meal:dinner:2026-11-28", "cash_check:2026-11-28", "review:day:2026-11-28"]);
    expect(p[1]).toMatchObject({ title: "Kiểm tra tiền mặt cuối ngày", data: { route: "/accounts" } });
    expect(p[2]).toMatchObject({ type: "review", period: "DAY", anchor: "2026-11-28" });
  });

  it("plans the weekly review on the configured weekday and the monthly review on the last day", () => {
    const sun = decidePushes({ now: at("2026-11-29T20:10"), settings: DEFAULT_SETTINGS, status: status({ date: "2026-11-29", done: { breakfast: true, lunch: true, dinner: true } }) });
    expect(keys(sun)).toContain("review:week:2026-11-23");
    const sat = decidePushes({ now: at("2026-11-28T20:10"), settings: DEFAULT_SETTINGS, status: status({ done: { breakfast: true, lunch: true, dinner: true } }) });
    expect(keys(sat).some((k) => k.startsWith("review:week"))).toBe(false);
    const last = decidePushes({ now: at("2026-11-30T20:10"), settings: DEFAULT_SETTINGS, status: status({ date: "2026-11-30", done: { breakfast: true, lunch: true, dinner: true } }) });
    expect(keys(last)).toContain("review:month:2026-11");
    // A Monday weekly review looks back at the week that just ended.
    const mon = resolveSettings(null, { weekly_review: { weekday: 1, time: "08:00" } });
    const p = decidePushes({ now: at("2026-11-30T08:05"), settings: mon, status: status({ date: "2026-11-30" }) });
    expect(p.find((x) => x.type === "review")).toMatchObject({ key: "review:week:2026-11-23", anchor: "2026-11-29" });
    expect(reviewKey("MONTH", "2026-11-30")).toBe("review:month:2026-11");
  });

  it("alerts budgets at 80% and 100% once per month, in waking hours only", () => {
    const budgets = [
      { id: "b1", category_name: "Ăn uống", limit_amount: "1000000", carried: "0", spent: "850000" },
      { id: "b2", category_name: "Tổng chi tiêu", limit_amount: "5000000", carried: "0", spent: "5200000" },
      { id: "b3", category_name: "Di chuyển", limit_amount: "1000000", carried: "0", spent: "100000" },
    ];
    const settings = resolveSettings(null, { meals: { breakfast: { enabled: false } } });
    const p = decidePushes({ now: at("2026-11-28T10:00"), settings, status: status(), budgets });
    expect(p).toHaveLength(2);
    expect(p[0]).toMatchObject({ key: "budget:b1:80:2026-11", title: "Sắp hết ngân sách Ăn uống" });
    expect(p[1]).toMatchObject({ key: "budget:b2:100:2026-11", title: "Vượt ngân sách Tổng chi tiêu", alsoClaim: ["budget:b2:80:2026-11"] });
    expect((p[1] as { body: string }).body).toBe("Đã chi 5.200.000 đ / 5.000.000 đ (104%) trong tháng 11/2026.");
    expect(decidePushes({ now: at("2026-11-28T23:30"), settings, status: status(), budgets }).filter((x) => x.type === "budget")).toEqual([]);
    const off = resolveSettings(null, { budget_alerts: { enabled: false }, meals: { breakfast: { enabled: false } } });
    expect(decidePushes({ now: at("2026-11-28T10:00"), settings: off, status: status(), budgets })).toEqual([]);
  });
});

describe("OneSignal action buttons", () => {
  it("sends `buttons` only when given (max 3)", async () => {
    const bodies: any[] = [];
    const f = vi.fn(async (_u: unknown, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    const cfg = { onesignalAppId: "app", onesignalRestKey: "k" };
    await sendPush(cfg, f, { ownerId: "o", title: "T", body: "B", buttons: [{ id: "a", text: "A" }, { id: "b", text: "B" }, { id: "c", text: "C" }, { id: "d", text: "D" }] });
    await sendPush(cfg, f, { ownerId: "o", title: "T", body: "B" });
    expect(bodies[0].buttons).toEqual([{ id: "a", text: "A" }, { id: "b", text: "B" }, { id: "c", text: "C" }]);
    expect(bodies[1]).not.toHaveProperty("buttons");
  });
});
