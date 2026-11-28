// Debt collection + self-running goals (migration 019, D-025): pure helpers (no I/O) so the rules are unit-tested.

export function formatVnd(n: number | string): string {
  const v = Math.round(Number(n) || 0);
  return `${v.toLocaleString("vi-VN").replace(/,/g, ".")}đ`;
}

/** Vietnam local clock (UTC+7). */
export function vnParts(now: Date = new Date()): { date: string; month: string; hour: number; day: number; lastDay: number } {
  const t = new Date(now.getTime() + 7 * 3_600_000);
  const y = t.getUTCFullYear();
  const m = t.getUTCMonth();
  return {
    date: t.toISOString().slice(0, 10),
    month: t.toISOString().slice(0, 7),
    hour: t.getUTCHours(),
    day: t.getUTCDate(),
    lastDay: new Date(Date.UTC(y, m + 1, 0)).getUTCDate(),
  };
}

/** No pushes 23:00–06:59 (Vietnam); the cron sends what waited once the night is over. */
export function isQuiet(now: Date = new Date()): boolean {
  const h = vnParts(now).hour;
  return h >= 23 || h < 7;
}

/** Reminders to other people only in sociable hours (08:00–20:59). */
export function isSociable(now: Date = new Date()): boolean {
  const h = vnParts(now).hour;
  return h >= 8 && h < 21;
}

/** "05/11" from an ISO date / timestamp. */
export function shortDate(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso.length === 10 ? `${iso}T00:00:00+07:00` : iso);
  const t = new Date(d.getTime() + 7 * 3_600_000);
  return `${String(t.getUTCDate()).padStart(2, "0")}/${String(t.getUTCMonth() + 1).padStart(2, "0")}`;
}

export interface ReminderInfo {
  debt_id: string;
  direction: "RECEIVABLE" | "PAYABLE";
  contact_alias: string;
  remaining: string;
  principal: string;
  note: string | null;
  originated_at: string;
  due_date: string | null;
  overdue_days: number;
  age_days: number;
  memo: string;
  memo_code: string;
  remind_count: number | null;
  last_reminded_at: string | null;
  next_at: string | null;
  learned_days: number | null;
  contact_bank: { bank: string; bin: string | null; account_number: string; holder: string | null } | null;
  version?: number;
}

export type ReminderTone = "first" | "second" | "firm";

export function toneFor(info: Pick<ReminderInfo, "remind_count" | "overdue_days">): ReminderTone {
  const n = info.remind_count ?? 0;
  if (n >= 2 || info.overdue_days >= 14) return "firm";
  if (n === 1 || info.overdue_days > 0) return "second";
  return "first";
}

/** What the money was for, as people say it: "tiền nhà" / "khoản tiền". */
function what(note: string | null): string {
  const n = (note ?? "").trim().replace(/\s+/g, " ");
  if (!n || n.length > 40) return "khoản tiền";
  return /^(tiền|tien)\b/i.test(n) ? n.charAt(0).toLowerCase() + n.slice(1) : `khoản ${n}`;
}

/**
 * Friendly Vietnamese message the owner sends (Zalo / Messenger / SMS) with the QR picture. The tone grows a little
 * firmer with each reminder but stays polite; the memo code lets MoMa settle the debt by itself when the money arrives.
 */
export function reminderMessage(info: ReminderInfo): { tone: ReminderTone; text: string } {
  const tone = toneFor(info);
  const amount = formatVnd(info.remaining);
  const thing = what(info.note);
  const since = shortDate(info.originated_at);
  const memo = info.memo;
  const name = info.contact_alias.trim();
  const text =
    tone === "first"
      ? `Hi ${name}, mình gửi bạn ${thing} ${amount} nhé. Bạn chuyển giúp mình qua mã QR này (nội dung "${memo}") là được nha. Cảm ơn bạn nhiều!`
      : tone === "second"
        ? `${name} ơi, mình nhắc nhẹ ${thing} ${amount} (từ ${since}) nha. Khi nào tiện bạn quét mã QR này chuyển giúp mình nhé, nội dung "${memo}". Cảm ơn bạn!`
        : `${name} ơi, ${thing} ${amount} từ ${since} mình vẫn chưa nhận được. Bạn sắp xếp chuyển giúp mình trong tuần này nhé, quét mã QR là xong (nội dung "${memo}"). Cảm ơn bạn!`;
  return { tone, text };
}

export interface PushText {
  title: string;
  body: string;
}

export interface SettledItem {
  alias: string;
  amount: number;
  note: string | null;
  direction: "RECEIVABLE" | "PAYABLE";
}

export function settledPush(items: SettledItem[]): PushText {
  if (items.length === 1) {
    const s = items[0]!;
    const forWhat = s.note && s.note.trim().length <= 40 ? ` · ${s.note.trim()}` : "";
    return s.direction === "RECEIVABLE"
      ? { title: `${s.alias} đã trả ${formatVnd(s.amount)}${forWhat}`, body: "Đã ghi vào khoản nợ, không tính là thu nhập. Chạm để xem hoặc hoàn tác." }
      : { title: `Đã trả ${s.alias} ${formatVnd(s.amount)}${forWhat}`, body: "Đã gạch vào khoản bạn nợ, không tính là chi tiêu. Chạm để xem hoặc hoàn tác." };
  }
  return {
    title: `Đã ghi ${items.length} khoản trả nợ`,
    body: `${items.map((s) => `${s.alias} ${formatVnd(s.amount)}`).join(", ")} · Chạm để xem hoặc hoàn tác.`,
  };
}

export function suggestedPush(alias: string, amount: number, direction: "RECEIVABLE" | "PAYABLE"): PushText {
  return direction === "RECEIVABLE"
    ? { title: `Có phải ${alias} trả nợ ${formatVnd(amount)}?`, body: "Chạm để xác nhận một lần." }
    : { title: `Có phải bạn vừa trả ${alias} ${formatVnd(amount)}?`, body: "Chạm để xác nhận một lần." };
}

export function remindDuePush(items: { alias: string; remaining: number }[]): PushText {
  if (items.length === 1) {
    const s = items[0]!;
    return { title: `Nhắc ${s.alias} trả ${formatVnd(s.remaining)}?`, body: "Mình đã soạn sẵn tin nhắn kèm mã QR đúng số tiền. Chạm để gửi." };
  }
  return {
    title: `Nhắc nợ ${items.length} người?`,
    body: `${items.map((s) => `${s.alias} ${formatVnd(s.remaining)}`).join(", ")} · Tin nhắn và mã QR đã soạn sẵn.`,
  };
}

export function payableDuePush(items: { alias: string; remaining: number; due_date: string | null }[]): PushText {
  if (items.length === 1) {
    const s = items[0]!;
    return { title: `Sắp đến hạn trả ${s.alias} ${formatVnd(s.remaining)}`, body: `${s.due_date ? `Hạn ${shortDate(s.due_date)} · ` : ""}Chạm để trả ngay.` };
  }
  return { title: `${items.length} khoản sắp đến hạn trả`, body: `${items.map((s) => `${s.alias} ${formatVnd(s.remaining)}`).join(", ")} · Chạm để trả ngay.` };
}

// ---------------------------------------------------------------- goals
export interface GoalPlan {
  id: string;
  name: string;
  target: string;
  allocated: string;
  left_amount: string;
  pct: number;
  due_date: string | null;
  months_left: number | null;
  required_monthly: string | null;
  pace_monthly: string;
  eta: string | null;
  on_track: boolean | null;
  version: number;
}

export interface IncomeFacts {
  tx_id: string;
  kind: string;
  status: string;
  source: string;
  amount: string | null;
  account_id: string | null;
  category_name: string | null;
  avg_monthly_income: string;
  available: string;
}

export const INCOME_MIN = 3_000_000;
const SALARY_WORDS = /\b(luong|thuong|salary|bonus|payroll)\b/;

const fold = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/đ/g, "d")
    .replace(/Đ/g, "D")
    .toLowerCase();

/** Salary / bonus / a large income (≥ 3tr and ≥ 40% of the usual monthly income) starts a goal proposal. */
export function isIncomeTrigger(f: IncomeFacts, note?: string | null): boolean {
  if (f.status !== "POSTED" || !["INCOME", "UNKNOWN_CREDIT"].includes(f.kind)) return false;
  const amount = Number(f.amount ?? 0);
  if (amount < INCOME_MIN) return false;
  const cat = fold(f.category_name ?? "");
  if (cat === "luong" || cat === "thuong") return true;
  if (SALARY_WORDS.test(fold(note ?? ""))) return true;
  const avg = Number(f.avg_monthly_income || 0);
  return amount >= Math.max(INCOME_MIN, 0.4 * avg);
}

const roundUp = (v: number, step: number) => Math.ceil(v / step) * step;
const roundDown = (v: number, step: number) => Math.floor(v / step) * step;

/** The goal that most needs money: behind schedule first, then the nearest due date, then the largest gap. */
export function pickGoal(plans: GoalPlan[]): GoalPlan | null {
  const open = plans.filter((g) => Number(g.left_amount) > 0);
  if (!open.length) return null;
  const rank = (g: GoalPlan) => [g.on_track === false ? 0 : 1, g.due_date ?? "9999-12-31", -Number(g.left_amount)] as const;
  return [...open].sort((a, b) => {
    const x = rank(a);
    const y = rank(b);
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i]! < y[i]! ? -1 : 1;
    return 0;
  })[0]!;
}

/**
 * How much to set aside from an income: the goal's required monthly saving (or 10% of the income when it has no due
 * date), rounded up to 50.000đ, never more than what is left of the goal or free on the account. null when < 50.000đ.
 */
export function incomeProposalAmount(goal: GoalPlan, income: number, available: number): number | null {
  const need = goal.required_monthly ? Number(goal.required_monthly) : income * 0.1;
  let amount = roundUp(need, 50_000);
  amount = Math.min(amount, Number(goal.left_amount), roundDown(available, 10_000));
  return amount >= 50_000 ? amount : null;
}

/** Month-end: put the under-spend (rounded down to 50.000đ) into the goal; null below 100.000đ. */
export function monthEndAmount(surplus: number, available: number, left: number): number | null {
  const amount = roundDown(Math.min(surplus, available, left), 50_000);
  return amount >= 100_000 ? amount : null;
}

/** Month-end proposals are made on the last 2 days of the month, and on the 1st for the month that just ended. */
export function monthEndTarget(now: Date = new Date()): string | null {
  const p = vnParts(now);
  if (p.day >= p.lastDay - 1) return p.month;
  if (p.day === 1) {
    const [y, m] = p.month.split("-").map(Number) as [number, number];
    return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, "0")}`;
  }
  return null;
}

export function incomeGoalPush(incomeLabel: string, income: number, goal: string, amount: number): PushText {
  return { title: `${incomeLabel} về ${formatVnd(income)} 🎉`, body: `Trích ${formatVnd(amount)} vào mục tiêu ${goal}? Chạm để trích ngay.` };
}

export function monthEndPush(month: string, surplus: number, goal: string, amount: number): PushText {
  const m = Number(month.slice(5, 7));
  return { title: `Tháng ${m} bạn chi ít hơn dự kiến ${formatVnd(surplus)}`, body: `Dồn ${formatVnd(amount)} vào mục tiêu ${goal}? Chạm để trích.` };
}

export function milestonePush(name: string, pct: number, allocated: number, target: number): PushText {
  if (pct >= 100) return { title: `🎉 Hoàn thành mục tiêu ${name}!`, body: `Bạn đã để dành đủ ${formatVnd(target)}. Tuyệt vời!` };
  return { title: `🎉 Mục tiêu ${name} đã đạt ${pct}%`, body: `Đã để dành ${formatVnd(allocated)} / ${formatVnd(target)}. Cố lên nhé!` };
}
