import { normalizeKey } from "./memory";

// Daily routines learned from the ledger: what the owner usually buys in each part of the day (bánh mì 20.000đ ·
// tiền mặt in the morning, cơm trưa 40.000đ...), so a reminder can offer one-tap answers ("Sáng nay bạn ăn gì?
// [Bánh mì 20k] [Cà phê 25k]") and the evening/morning nudge can spot daily items that were not recorded
// ("Hôm qua bạn chưa ghi gửi xe, cà phê như mọi ngày?"). Deterministic; no model call.

export type Slot = "breakfast" | "lunch" | "dinner";

/** Vietnam-local minute windows of each slot (a purchase in the window counts for the slot). */
export const SLOT_WINDOW: Record<Slot, [number, number]> = {
  breakfast: [5 * 60, 10 * 60 + 30],
  lunch: [10 * 60 + 30, 14 * 60 + 30],
  dinner: [17 * 60, 21 * 60 + 30],
};
export const SLOT_QUESTION: Record<Slot, string> = {
  breakfast: "Sáng nay bạn ăn gì?",
  lunch: "Trưa nay bạn ăn gì?",
  dinner: "Tối nay bạn ăn gì?",
};

export interface RoutineTx {
  id: string;
  kind: string;
  status: string;
  amount: string;
  effective_at: string;
  account_id: string;
  category_id?: string | null;
  merchant?: string | null;
  note?: string | null;
}

export interface RoutineOption {
  /** Stable id of the option (normalized label), used in push button ids and POST /v1/ai/routine/record. */
  key: string;
  label: string;
  amount: number;
  account_id: string;
  category_id: string;
  /** Days (of the lookback) this item was bought in the slot. */
  days: number;
  /** Score used for ranking (frequency x recency, weekday/weekend aware). */
  score: number;
}

const VN = 7 * 3_600_000;
const local = (iso: string) => new Date(Date.parse(iso) + VN);
const dayOf = (iso: string) => local(iso).toISOString().slice(0, 10);
const minuteOf = (iso: string) => {
  const d = local(iso);
  return d.getUTCHours() * 60 + d.getUTCMinutes();
};
const weekendOf = (iso: string) => [0, 6].includes(local(iso).getUTCDay());

export function slotOf(iso: string): Slot | null {
  const m = minuteOf(iso);
  for (const s of ["breakfast", "lunch", "dinner"] as Slot[]) {
    const [a, b] = SLOT_WINDOW[s];
    if (m >= a && m < b) return s;
  }
  return null;
}

/** Short human label of a purchase: merchant, else the first words of the note. */
export function labelOf(t: Pick<RoutineTx, "merchant" | "note">): string | null {
  const m = (t.merchant ?? "").trim();
  if (m) return m.slice(0, 40);
  const n = (t.note ?? "").trim().replace(/\s+/g, " ");
  if (!n) return null;
  // Bank-style notes ("CT DEN:123 MBVCB...") are not routines.
  if (/\d{6,}/.test(n) || n.length > 60) return null;
  return n.split(" ").slice(0, 4).join(" ").slice(0, 40);
}

const median = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m]! : Math.round((s[m - 1]! + s[m]!) / 2);
};
const mode = <T>(xs: T[]): T => {
  const c = new Map<T, number>();
  for (const x of xs) c.set(x, (c.get(x) ?? 0) + 1);
  return [...c.entries()].sort((a, b) => b[1] - a[1])[0]![0];
};

/**
 * Top options for a slot from the last `days` days of expenses: items bought on at least `minDays` different days,
 * ranked by how often (recent days weigh more; same weekday/weekend kind as `now` weighs more). Max `limit`.
 */
export function routineOptions(txs: RoutineTx[], slot: Slot, now: Date, opts: { days?: number; minDays?: number; limit?: number } = {}): RoutineOption[] {
  const days = opts.days ?? 30;
  const minDays = opts.minDays ?? 3;
  const limit = opts.limit ?? 3;
  const nowMs = now.getTime();
  const today = dayOf(now.toISOString());
  const weekendNow = weekendOf(now.toISOString());
  const groups = new Map<string, { label: string; amounts: number[]; accounts: string[]; categories: string[]; days: Set<string>; score: number }>();
  for (const t of txs) {
    if (t.status !== "POSTED" || t.kind !== "EXPENSE" || !t.category_id) continue;
    const age = (nowMs - Date.parse(t.effective_at)) / 86_400_000;
    if (age < 0 || age > days) continue;
    if (dayOf(t.effective_at) === today) continue; // today's own purchase does not vote for today's question
    if (slotOf(t.effective_at) !== slot) continue;
    const label = labelOf(t);
    if (!label) continue;
    const key = normalizeKey(label).slice(0, 40);
    if (!key) continue;
    const g = groups.get(key) ?? { label, amounts: [], accounts: [], categories: [], days: new Set<string>(), score: 0 };
    g.amounts.push(Number(t.amount));
    g.accounts.push(t.account_id);
    g.categories.push(t.category_id);
    g.days.add(dayOf(t.effective_at));
    g.score += (1 - age / (days + 1)) * (weekendOf(t.effective_at) === weekendNow ? 1.5 : 1);
    groups.set(key, g);
  }
  return [...groups.entries()]
    .filter(([, g]) => g.days.size >= minDays)
    .map(([key, g]) => ({
      key,
      label: g.label,
      amount: Math.round(median(g.amounts) / 1000) * 1000,
      account_id: mode(g.accounts),
      category_id: mode(g.categories),
      days: g.days.size,
      score: Math.round(g.score * 100) / 100,
    }))
    .filter((o) => o.amount > 0)
    .sort((a, b) => b.score - a.score || b.days - a.days)
    .slice(0, limit);
}

/** "Bánh mì 20k" (button text: short). */
export function shortMoney(n: number): string {
  if (n >= 1_000_000) return `${Math.round(n / 100_000) / 10}tr`.replace(".", ",");
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return `${n}đ`;
}

export function optionText(o: Pick<RoutineOption, "label" | "amount">, max = 22): string {
  const money = shortMoney(o.amount);
  const room = Math.max(4, max - money.length - 1);
  const label = o.label.length > room ? `${o.label.slice(0, room - 1)}…` : o.label;
  return `${label} ${money}`;
}

/** Was something already recorded in this slot today (any source: bank, notification, manual)? */
export function slotRecorded(txs: RoutineTx[], slot: Slot, now: Date): boolean {
  const today = dayOf(now.toISOString());
  return txs.some((t) => t.status === "POSTED" && (t.kind === "EXPENSE" || t.kind === "UNKNOWN_DEBIT") && dayOf(t.effective_at) === today && slotOf(t.effective_at) === slot);
}

/** Usual minute the owner buys in this slot (median), for timing the question just after it; null below 4 samples. */
export function usualMinute(txs: RoutineTx[], slot: Slot, now: Date, days = 30): number | null {
  const mins = txs
    .filter((t) => t.status === "POSTED" && t.kind === "EXPENSE" && slotOf(t.effective_at) === slot && (now.getTime() - Date.parse(t.effective_at)) / 86_400_000 <= days)
    .map((t) => minuteOf(t.effective_at));
  return mins.length >= 4 ? median(mins) : null;
}

/**
 * Daily items (bought on >= 70% of the last 14 days, any time) that were NOT recorded on `day`: the "Hôm qua bạn chưa
 * ghi … như mọi ngày?" nudge. Only strong habits; max 3.
 */
export function missedDaily(txs: RoutineTx[], day: string, now: Date): RoutineOption[] {
  const windowStart = now.getTime() - 15 * 86_400_000;
  const per = new Map<string, { label: string; amounts: number[]; accounts: string[]; categories: string[]; days: Set<string> }>();
  const seenOnDay = new Set<string>();
  for (const t of txs) {
    if (t.status !== "POSTED" || t.kind !== "EXPENSE" || !t.category_id) continue;
    if (Date.parse(t.effective_at) < windowStart) continue;
    const label = labelOf(t);
    if (!label) continue;
    const key = normalizeKey(label).slice(0, 40);
    const d = dayOf(t.effective_at);
    if (d === day) {
      seenOnDay.add(key);
      continue;
    }
    if (d > day) continue;
    const g = per.get(key) ?? { label, amounts: [], accounts: [], categories: [], days: new Set<string>() };
    g.amounts.push(Number(t.amount));
    g.accounts.push(t.account_id);
    g.categories.push(t.category_id);
    g.days.add(d);
    per.set(key, g);
  }
  return [...per.entries()]
    .filter(([key, g]) => g.days.size >= 10 && !seenOnDay.has(key))
    .map(([key, g]) => ({ key, label: g.label, amount: Math.round(median(g.amounts) / 1000) * 1000, account_id: mode(g.accounts), category_id: mode(g.categories), days: g.days.size, score: g.days.size }))
    .sort((a, b) => b.days - a.days)
    .slice(0, 3);
}
