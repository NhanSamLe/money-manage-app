// Self-adjusting budgets (D-026): pure math, no I/O. The proposer turns the owner's real spending into monthly
// limits per main category; pacing turns the month's budgets into "còn N ngày, mỗi ngày nên ~X" and a calm push only
// when spending clearly runs ahead. Amounts are integer VND.

export const ROUND_STEP = 50_000;
/** Below this monthly average a category gets no budget of its own (noise). */
export const MIN_MONTHLY = 30_000;
/** Headroom over the observed pace. */
export const BUFFER = 1.05;
/** History window used by the proposer. */
export const WINDOW_DAYS = 90;
/** A proposal differing from the current limit by at least this share is worth showing as a change. */
export const CHANGE_RATIO = 0.15;
/** "Clearly off": spending at least this much ahead of the even pace. */
export const FAST_RATIO = 0.2;

export interface HistoryRow {
  tx_id?: string;
  day: string; // YYYY-MM-DD (local)
  category_id: string;
  amount: number;
  recurring: boolean;
}

export interface CategoryRef {
  id: string;
  name: string;
  type?: string;
  parent_id?: string | null;
  icon?: string | null;
  archived?: boolean;
}

export interface BudgetNow {
  id: string;
  category_id: string | null;
  category_name: string;
  icon?: string | null;
  limit: number;
  carried: number;
  spent: number;
  carryover?: boolean;
  version: number;
}

/** A past month's budget and what was actually spent against it. */
export interface PastOutcome {
  month: string; // YYYY-MM
  category_id: string | null;
  limit: number;
  spent: number;
}

export type ProposalReason = "new" | "raise" | "lower" | "keep" | "realistic";

export interface Proposal {
  category_id: string | null;
  name: string;
  icon: string | null;
  proposed: number;
  monthly_avg: number;
  current_limit: number | null;
  current_version: number | null;
  reason: ProposalReason;
  note: string;
  excluded_outliers: number;
}

export interface ProposalResult {
  month: string;
  history_days: number;
  items: Proposal[];
  total: Proposal | null;
  /** Categories that went over budget in at least 2 of the last 3 months (the push suggests a realistic limit). */
  chronic: string[];
}

export function roundUpTo(n: number, step = ROUND_STEP): number {
  if (!(n > 0)) return 0;
  return Math.ceil(n / step) * step;
}

export function daysInMonth(month: string): number {
  const [y, m] = month.split("-").map(Number) as [number, number];
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

export function dayDiff(a: string, b: string): number {
  return Math.round((Date.parse(`${a}T00:00:00Z`) - Date.parse(`${b}T00:00:00Z`)) / 86_400_000);
}

export function addDays(date: string, n: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
}

export function prevMonth(month: string, n = 1): string {
  const [y, m] = month.split("-").map(Number) as [number, number];
  const d = new Date(Date.UTC(y, m - 1 - n, 1));
  return d.toISOString().slice(0, 7);
}

export function vnd(n: number): string {
  return `${Math.round(n).toLocaleString("vi-VN").replace(/,/g, ".")}đ`;
}

/** Top-level category of an expense category (budgets of a parent also count its children, like budget_spent). */
export function mainCategory(id: string, byId: Map<string, CategoryRef>): string {
  let cur = byId.get(id);
  for (let i = 0; i < 5 && cur?.parent_id; i++) {
    const parent = byId.get(cur.parent_id);
    if (!parent) break;
    cur = parent;
  }
  return cur?.id ?? id;
}

function median(values: number[]): number {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
}

/**
 * Splits a category's transactions into typical spending and one-off outliers: with 5+ transactions anything above
 * max(3 x median, 1.000.000) is an outlier; with fewer, a single purchase of 10.000.000+ that is most of the total is.
 */
export function splitOutliers(amounts: number[]): { kept: number[]; outliers: number[] } {
  if (amounts.length >= 5) {
    const limit = Math.max(3 * median(amounts), 1_000_000);
    return { kept: amounts.filter((a) => a <= limit), outliers: amounts.filter((a) => a > limit) };
  }
  const total = amounts.reduce((s, a) => s + a, 0);
  const big = amounts.filter((a) => a >= 10_000_000 && a > 0.6 * total);
  return { kept: amounts.filter((a) => !big.includes(a)), outliers: big };
}

/**
 * Monthly budget proposals from the last WINDOW_DAYS of real spending (recurring / fixed costs excluded: they are
 * planned separately and only added to the overall total). Pace = 60% last 30 days + 40% whole window when there is
 * more than a month of history, scaled to the target month, +5% headroom, rounded up to 50.000.
 * A category overspent in 2 of the last 3 months gets a realistic limit instead of the old one (no nagging).
 */
export function proposeBudgets(input: {
  month: string;
  /** Last day of history (usually yesterday). */
  toDay: string;
  rows: HistoryRow[];
  categories: CategoryRef[];
  existing: BudgetNow[];
  past: PastOutcome[];
  /** Fixed monthly costs (recurring rules, owner's share) added to the overall budget. */
  recurringMonthly: number;
}): ProposalResult {
  const { month, toDay } = input;
  const byId = new Map(input.categories.map((c) => [c.id, c]));
  const fromDay = addDays(toDay, -(WINDOW_DAYS - 1));
  const rows = input.rows.filter((r) => r.day >= fromDay && r.day <= toDay && r.amount > 0);
  const out: ProposalResult = { month, history_days: 0, items: [], total: null, chronic: [] };
  if (!rows.length) return out;
  const first = rows.reduce((m, r) => (r.day < m ? r.day : m), rows[0]!.day);
  const historyDays = dayDiff(toDay, first) + 1;
  out.history_days = historyDays;
  if (historyDays < 7) return out;

  const recentFrom = addDays(toDay, -29);
  const recentDays = Math.min(30, historyDays);
  const dim = daysInMonth(month);
  const groups = new Map<string, HistoryRow[]>();
  for (const r of rows) {
    if (r.recurring) continue;
    const main = mainCategory(r.category_id, byId);
    const cat = byId.get(main);
    if (cat?.archived || (cat?.type && cat.type !== "EXPENSE")) continue;
    groups.set(main, [...(groups.get(main) ?? []), r]);
  }

  const existingBy = new Map(input.existing.map((b) => [b.category_id ?? "*", b]));
  const pastBy = new Map<string, PastOutcome[]>();
  for (const p of input.past) pastBy.set(p.category_id ?? "*", [...(pastBy.get(p.category_id ?? "*") ?? []), p]);

  const decide = (key: string, raw: number, avg: number): { proposed: number; reason: ProposalReason; note: string } => {
    const cur = existingBy.get(key);
    const past = (pastBy.get(key) ?? []).filter((p) => p.limit > 0);
    const overs = past.filter((p) => p.spent > p.limit * 1.1);
    if (overs.length >= 2) {
      const realistic = roundUpTo(Math.max(raw, overs.reduce((s, p) => s + p.spent, 0) / overs.length));
      out.chronic.push(key);
      return { proposed: realistic, reason: "realistic", note: `Vượt ngân sách ${overs.length}/${past.length} tháng gần đây, đề xuất mức sát thực tế hơn` };
    }
    if (!cur) return { proposed: raw, reason: "new", note: `Trung bình khoảng ${vnd(avg)}/tháng` };
    const diff = (raw - cur.limit) / cur.limit;
    if (diff >= CHANGE_RATIO) return { proposed: raw, reason: "raise", note: `Bạn đang chi nhiều hơn mức ${vnd(cur.limit)}` };
    if (diff <= -CHANGE_RATIO) return { proposed: raw, reason: "lower", note: `Bạn chi ít hơn mức ${vnd(cur.limit)}, có thể hạ xuống` };
    return { proposed: cur.limit, reason: "keep", note: "Mức hiện tại vẫn hợp lý" };
  };

  for (const [main, list] of groups) {
    const { kept, outliers } = splitOutliers(list.map((r) => r.amount));
    const keptRows = list.filter((r) => kept.includes(r.amount));
    const all = keptRows.reduce((s, r) => s + r.amount, 0) / historyDays;
    const recent = keptRows.filter((r) => r.day >= recentFrom).reduce((s, r) => s + r.amount, 0) / recentDays;
    const rate = historyDays > 30 ? 0.6 * recent + 0.4 * all : all;
    const avg = rate * dim;
    if (avg < MIN_MONTHLY) continue;
    const raw = roundUpTo(avg * BUFFER);
    const cat = byId.get(main);
    const cur = existingBy.get(main);
    const d = decide(main, raw, avg);
    const days = historyDays >= WINDOW_DAYS ? "3 tháng" : `${historyDays} ngày`;
    out.items.push({
      category_id: main,
      name: cat?.name ?? cur?.category_name ?? "Khác",
      icon: cat?.icon ?? cur?.icon ?? null,
      proposed: d.proposed,
      monthly_avg: Math.round(avg),
      current_limit: cur?.limit ?? null,
      current_version: cur?.version ?? null,
      reason: d.reason,
      note: `${d.note} · dựa trên ${days} gần nhất${outliers.length ? `, bỏ qua ${outliers.length} khoản lớn bất thường` : ""}`,
      excluded_outliers: outliers.length,
    });
  }
  out.items.sort((a, b) => b.proposed - a.proposed || a.name.localeCompare(b.name));
  if (out.items.length) {
    const sum = out.items.reduce((s, p) => s + p.proposed, 0) + roundUpTo(Math.max(0, input.recurringMonthly));
    const cur = existingBy.get("*");
    const d = decide("*", sum, sum);
    out.total = {
      category_id: null,
      name: "Tổng chi tiêu",
      icon: null,
      proposed: d.proposed,
      monthly_avg: sum,
      current_limit: cur?.limit ?? null,
      current_version: cur?.version ?? null,
      reason: d.reason,
      note: input.recurringMonthly > 0 ? `Gồm ${vnd(roundUpTo(input.recurringMonthly))} chi cố định hằng tháng` : d.note,
      excluded_outliers: 0,
    };
  }
  return out;
}

/** Monthly equivalent of the owner's enabled recurring expenses (split rules count only the owner's share). */
export function recurringMonthly(items: { kind?: string; amount?: string | number; interval?: string; enabled?: boolean; split?: { owner_share?: string | number | null } | null }[]): number {
  let total = 0;
  for (const r of items ?? []) {
    if (r.kind !== "EXPENSE" || r.enabled === false) continue;
    const share = r.split?.owner_share;
    const amount = Number(share ?? r.amount ?? 0);
    if (!(amount > 0)) continue;
    total += r.interval === "WEEKLY" ? (amount * 52) / 12 : r.interval === "YEARLY" ? amount / 12 : amount;
  }
  return Math.round(total);
}

// ---------------------------------------------------------------- pacing

export type PaceStatus = "ok" | "fast" | "over";

export interface PaceItem {
  budget_id: string;
  category_id: string | null;
  name: string;
  icon: string | null;
  limit: number;
  spent: number;
  today_spent: number;
  remaining: number;
  daily_allowance: number;
  safe_today: number;
  expected_by_now: number;
  ahead_pct: number;
  status: PaceStatus;
}

export interface PacingResult {
  month: string;
  day: number;
  days_in_month: number;
  days_left: number; // including today
  items: PaceItem[];
  overall: PaceItem | null;
}

const floorTo = (n: number, step = 1_000) => Math.max(0, Math.floor(n / step) * step);

/**
 * Daily pacing of the month's budgets. daily_allowance = what is left before today spread over the days left
 * (today included); safe_today = allowance minus what was already spent today. "fast" = at least 20% ahead of the
 * even pace after day 5 and with a quarter of the budget used (one early big purchase is not a trend).
 */
export function pacing(input: { today: string; budgets: BudgetNow[]; todaySpent: Map<string, number>; categories: CategoryRef[] }): PacingResult {
  const month = input.today.slice(0, 7);
  const day = Number(input.today.slice(8, 10));
  const dim = daysInMonth(month);
  const daysLeft = dim - day + 1;
  const byId = new Map(input.categories.map((c) => [c.id, c]));
  const todayByMain = new Map<string, number>();
  let todayTotal = 0;
  for (const [cat, amt] of input.todaySpent) {
    todayTotal += amt;
    const main = mainCategory(cat, byId);
    todayByMain.set(main, (todayByMain.get(main) ?? 0) + amt);
  }
  const item = (b: BudgetNow): PaceItem => {
    const limit = b.limit + (b.carried ?? 0);
    const todaySpent = Math.min(b.spent, b.category_id ? (todayByMain.get(b.category_id) ?? 0) : todayTotal);
    const before = b.spent - todaySpent;
    const allowance = floorTo((limit - before) / daysLeft);
    const expected = (limit * day) / dim;
    const ahead = expected > 0 ? b.spent / expected - 1 : 0;
    const status: PaceStatus = b.spent > limit ? "over" : ahead >= FAST_RATIO && day >= 5 && b.spent >= 0.25 * limit ? "fast" : "ok";
    return {
      budget_id: b.id,
      category_id: b.category_id,
      name: b.category_name,
      icon: b.icon ?? null,
      limit,
      spent: b.spent,
      today_spent: todaySpent,
      remaining: limit - b.spent,
      daily_allowance: allowance,
      safe_today: floorTo(allowance - todaySpent),
      expected_by_now: Math.round(expected),
      ahead_pct: Math.round(ahead * 100),
      status,
    };
  };
  const items = input.budgets.filter((b) => b.category_id && b.limit > 0).map(item);
  items.sort((a, b) => (b.status === "fast" ? 1 : 0) - (a.status === "fast" ? 1 : 0) || b.ahead_pct - a.ahead_pct);
  const total = input.budgets.find((b) => !b.category_id && b.limit > 0);
  return { month, day, days_in_month: dim, days_left: daysLeft, items, overall: total ? item(total) : null };
}

/** Local push window for pacing nudges: 09:00-21:00 (never in the 23:00-06:59 quiet hours). */
export const PACE_FROM_MIN = 9 * 60;
export const PACE_TO_MIN = 21 * 60;

export interface PlannedPacePush {
  key: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
}

/**
 * At most one pacing push per day: the category furthest ahead of its pace. Categories that are chronically over
 * budget are left out (they get one "đặt mức thực tế" suggestion a month instead), and "over" is already covered by
 * the 80% / 100% budget alerts.
 */
export function pacePush(p: PacingResult, opts: { date: string; minutes: number; chronic: ReadonlySet<string> }): PlannedPacePush | null {
  if (opts.minutes < PACE_FROM_MIN || opts.minutes >= PACE_TO_MIN) return null;
  const worst = p.items.find((i) => i.status === "fast" && i.category_id && !opts.chronic.has(i.category_id));
  if (!worst) return null;
  return {
    key: `pace:${opts.date}`,
    title: `${worst.name} đang chi nhanh hơn dự kiến`,
    body: `Đã chi ${vnd(worst.spent)}, nhanh hơn kế hoạch ${worst.ahead_pct}%. Còn ${p.days_left} ngày, mỗi ngày nên khoảng ${vnd(worst.daily_allowance)}.`,
    data: { type: "budget_pace", category_id: worst.category_id, route: "/planning?tab=2" },
  };
}

/** Once a month for a chronically overspent category: suggest the realistic limit instead of nagging every day. */
export function realisticPush(r: ProposalResult, opts: { minutes: number }): PlannedPacePush | null {
  if (opts.minutes < PACE_FROM_MIN || opts.minutes >= PACE_TO_MIN) return null;
  const p = r.items.find((i) => i.reason === "realistic" && i.current_limit !== null && i.proposed > i.current_limit);
  if (!p) return null;
  return {
    key: `budget_fix:${r.month}`,
    title: `${p.name} thường vượt ngân sách`,
    body: `Mấy tháng gần đây bạn hay chi quá ${vnd(p.current_limit!)}. Đặt mức thực tế ${vnd(p.proposed)} cho tháng này nhé?`,
    data: { type: "budget_proposal", category_id: p.category_id, route: "/planning?tab=2&propose=1" },
  };
}
