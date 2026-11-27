import type { ReminderSettings } from "./settings";
import { formatVnd } from "../push/onesignal";

// Pure scheduling decisions for the 15-minute cron. No I/O: given the local clock, settings, today's status and the
// keys already claimed, returns the pushes that are due. The runner claims each key (pf_push_log_claim) before sending,
// so every reminder goes out at most once even if runs overlap.

export const VN_OFFSET_MS = 7 * 3_600_000;
export type Meal = "breakfast" | "lunch" | "dinner";
export type Period = "DAY" | "WEEK" | "MONTH";
export const MEALS: Meal[] = ["breakfast", "lunch", "dinner"];
/** Meals and the cash check are not sent later than this after their time (e.g. first run after a long outage). */
export const LATE_GRACE_MIN = 180;
/** Budget alerts only in waking hours (local). */
const ALERT_FROM_MIN = 7 * 60;
const ALERT_TO_MIN = 22 * 60;

export interface LocalClock {
  date: string; // YYYY-MM-DD local
  minutes: number; // minutes since local midnight
  weekday: number; // 1 = Monday ... 7 = Sunday
  month: string; // YYYY-MM
  lastDayOfMonth: boolean;
}

export function localClock(now: Date): LocalClock {
  const v = new Date(now.getTime() + VN_OFFSET_MS);
  const date = v.toISOString().slice(0, 10);
  const wd = v.getUTCDay();
  return {
    date,
    minutes: v.getUTCHours() * 60 + v.getUTCMinutes(),
    weekday: wd === 0 ? 7 : wd,
    month: date.slice(0, 7),
    lastDayOfMonth: addDays(date, 1).slice(8, 10) === "01",
  };
}

export function addDays(date: string, n: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
}
export function dayDiff(a: string, b: string): number {
  return Math.round((Date.parse(`${a}T00:00:00Z`) - Date.parse(`${b}T00:00:00Z`)) / 86_400_000);
}
export function isoWeekday(date: string): number {
  const d = new Date(`${date}T00:00:00Z`).getUTCDay();
  return d === 0 ? 7 : d;
}
export function weekStart(date: string): string {
  return addDays(date, 1 - isoWeekday(date));
}
export function daysInMonth(month: string): number {
  const [y, m] = month.split("-").map(Number) as [number, number];
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}
export function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number) as [number, number];
  return h * 60 + m;
}

export interface DayStatus {
  date: string;
  skipped: string[];
  done: Record<Meal, boolean>;
  has_accounts?: boolean;
}

export interface BudgetRow {
  id: string;
  category_name: string;
  limit_amount: string;
  carried?: string;
  spent: string;
}

export interface PushButton {
  id: string;
  text: string;
}

export type PlannedPush =
  | { key: string; type: "meal"; meal: Meal; title: string; body: string; data: Record<string, unknown>; buttons: PushButton[] }
  | { key: string; type: "cash_check"; title: string; body: string; data: Record<string, unknown> }
  | { key: string; type: "review"; period: Period; anchor: string }
  | { key: string; type: "budget"; title: string; body: string; data: Record<string, unknown>; alsoClaim: string[] };

const MEAL_TEXT: Record<Meal, { title: string; body: string }> = {
  breakfast: { title: "Bạn ăn sáng chưa?", body: "Ghi lại bữa sáng để sổ chi tiêu luôn chính xác." },
  lunch: { title: "Bạn ăn trưa chưa?", body: "Ghi lại bữa trưa để sổ chi tiêu luôn chính xác." },
  dinner: { title: "Bạn ăn tối chưa?", body: "Ghi lại bữa tối để sổ chi tiêu luôn chính xác." },
};

/** Due within the grace window today (time passed, not too late). */
function dueNow(clock: LocalClock, time: string, graceMin: number | null): boolean {
  const t = toMinutes(time);
  if (clock.minutes < t) return false;
  return graceMin === null || clock.minutes < t + graceMin;
}

export function reviewKey(period: Period, anchor: string): string {
  if (period === "DAY") return `review:day:${anchor}`;
  if (period === "WEEK") return `review:week:${weekStart(anchor)}`;
  return `review:month:${anchor.slice(0, 7)}`;
}

export function decidePushes(input: {
  now: Date;
  settings: ReminderSettings;
  status: DayStatus;
  claimed?: ReadonlySet<string>;
  budgets?: BudgetRow[];
}): PlannedPush[] {
  const { settings: s, status } = input;
  const clock = localClock(input.now);
  const claimed = input.claimed ?? new Set<string>();
  // Nothing to remind about before the owner has set up a single account.
  if (status.has_accounts === false) return [];
  const out: PlannedPush[] = [];
  const add = (p: PlannedPush) => {
    if (!claimed.has(p.key)) out.push(p);
  };

  for (const meal of MEALS) {
    const cfg = s.meals[meal];
    if (!cfg.enabled || !dueNow(clock, cfg.time, LATE_GRACE_MIN)) continue;
    if (status.done[meal] || status.skipped.includes(meal)) continue;
    add({
      key: `meal:${meal}:${clock.date}`,
      type: "meal",
      meal,
      ...MEAL_TEXT[meal],
      data: { type: "reminder", kind: meal, date: clock.date, route: "/quick-entry" },
      buttons: [
        { id: `skip_${meal}`, text: "Hôm nay không ăn" },
        { id: "log", text: "Ghi ngay" },
      ],
    });
  }

  if (s.cash_check.enabled && dueNow(clock, s.cash_check.time, LATE_GRACE_MIN)) {
    add({
      key: `cash_check:${clock.date}`,
      type: "cash_check",
      title: "Kiểm tra tiền mặt cuối ngày",
      body: "Đếm lại ví và cập nhật số dư tiền mặt nếu có chênh lệch.",
      data: { type: "reminder", kind: "cash_check", date: clock.date, route: "/accounts" },
    });
  }

  if (s.daily_review.enabled && dueNow(clock, s.daily_review.time, null)) {
    add({ key: reviewKey("DAY", clock.date), type: "review", period: "DAY", anchor: clock.date });
  }
  if (s.weekly_review.enabled && clock.weekday === s.weekly_review.weekday && dueNow(clock, s.weekly_review.time, null)) {
    // A Monday review looks back at the week that just ended; any other day reviews the current week so far.
    const anchor = clock.weekday === 1 ? addDays(clock.date, -1) : clock.date;
    add({ key: reviewKey("WEEK", anchor), type: "review", period: "WEEK", anchor });
  }
  if (s.monthly_review.enabled && clock.lastDayOfMonth && dueNow(clock, s.monthly_review.time, null)) {
    add({ key: reviewKey("MONTH", clock.date), type: "review", period: "MONTH", anchor: clock.date });
  }

  if (s.budget_alerts.enabled && clock.minutes >= ALERT_FROM_MIN && clock.minutes < ALERT_TO_MIN) {
    for (const b of input.budgets ?? []) {
      const limit = Number(b.limit_amount) + Number(b.carried ?? 0);
      const spent = Number(b.spent);
      if (!(limit > 0) || !Number.isFinite(spent)) continue;
      const pct = Math.floor((spent / limit) * 100);
      const k80 = `budget:${b.id}:80:${clock.month}`;
      const k100 = `budget:${b.id}:100:${clock.month}`;
      const name = b.category_name;
      const [y, m] = clock.month.split("-");
      if (pct >= 100) {
        add({
          key: k100,
          type: "budget",
          title: `Vượt ngân sách ${name}`,
          body: `Đã chi ${formatVnd(spent)} đ / ${formatVnd(limit)} đ (${pct}%) trong tháng ${m}/${y}.`,
          data: { type: "budget", budget_id: b.id, threshold: 100, route: "/budgets" },
          alsoClaim: [k80],
        });
      } else if (pct >= 80 && !claimed.has(k100)) {
        add({
          key: k80,
          type: "budget",
          title: `Sắp hết ngân sách ${name}`,
          body: `Đã dùng ${pct}% ngân sách tháng ${m}/${y}, còn ${formatVnd(limit - spent)} đ.`,
          data: { type: "budget", budget_id: b.id, threshold: 80, route: "/budgets" },
          alsoClaim: [],
        });
      }
    }
  }
  return out;
}
