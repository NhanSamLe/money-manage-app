import { DomainError } from "../../shared/errors";

// Bill splitting + recurring-rule matching (migration 016, D-022). Pure functions only: the share math used by every
// path (automatic recurring match, bill photo, the assistant, the app's preview mirrors it), the matcher that decides
// whether a new expense is "this month's rent", and the Vietnamese push texts.

export type ShareMode = "EQUAL" | "FIXED" | "PERCENT";
export type Rounding = 0 | 1000 | 5000 | 10000;
export const ROUNDINGS: readonly Rounding[] = [0, 1000, 5000, 10000];

/** One person in a split. Either an existing contact (contact_id) or a new person by name (created when applied). */
export interface Participant {
  contact_id?: string | null;
  name?: string | null;
  /** EQUAL (default): same share as everyone in the equal group; FIXED: exact amount; PERCENT: % of the total. */
  mode?: ShareMode;
  /** FIXED: VND; PERCENT: 0-100. Ignored for EQUAL. */
  value?: number | null;
}

export interface ComputedShare {
  contact_id: string | null;
  name: string;
  amount: number;
}

export interface SplitResult {
  total: number;
  shares: ComputedShare[];
  /** What the owner keeps paying (total - everyone else). */
  owner_amount: number;
}

export function roundUp(x: number, step: Rounding | number): number {
  if (step <= 0) return Math.ceil(x);
  return Math.ceil(x / step) * step;
}

/**
 * Shares of the other people for a bill of `total` VND.
 * - FIXED shares are exact; PERCENT shares are rounded up to `rounding`.
 * - EQUAL: what remains after fixed/percent is divided by (number of EQUAL people + the owner when ownerShare),
 *   each other person's share rounded UP to `rounding`; the owner keeps the remainder.
 *   1.600.000 / 3 with 5.000 -> 535.000 + 535.000, owner 530.000.
 * - When rounding up would make the others pay more than the bill (owner not included), the last equal share absorbs
 *   the excess. Throws SPLIT_INVALID when fixed/percent shares exceed the bill.
 */
export function computeShares(
  total: number,
  participants: Participant[],
  opts: { ownerShare?: boolean; rounding?: number } = {},
): SplitResult {
  const ownerShare = opts.ownerShare ?? true;
  const rounding = opts.rounding ?? 5000;
  if (!Number.isFinite(total) || total <= 0 || !Number.isInteger(total)) throw new DomainError("VALIDATION_FAILED");
  if (participants.length > 20) throw new DomainError("VALIDATION_FAILED");
  const shares: (ComputedShare & { mode: ShareMode })[] = participants.map((p) => ({
    contact_id: p.contact_id ?? null,
    name: (p.name ?? "").trim(),
    amount: 0,
    mode: p.mode ?? "EQUAL",
  }));
  let fixed = 0;
  participants.forEach((p, i) => {
    const s = shares[i]!;
    if (s.mode === "FIXED") {
      const v = Math.round(Number(p.value ?? 0));
      if (!(v >= 0)) throw new DomainError("VALIDATION_FAILED");
      s.amount = v;
    } else if (s.mode === "PERCENT") {
      const v = Number(p.value ?? 0);
      if (!(v >= 0 && v <= 100)) throw new DomainError("VALIDATION_FAILED");
      s.amount = Math.min(total, roundUp((total * v) / 100, rounding));
    }
    fixed += s.amount;
  });
  if (fixed > total) throw new DomainError("SPLIT_INVALID");
  const equal = shares.filter((s) => s.mode === "EQUAL");
  const people = equal.length + (ownerShare ? 1 : 0);
  if (equal.length > 0 && people > 0) {
    const remaining = total - fixed;
    const each = roundUp(remaining / people, rounding);
    for (const s of equal) s.amount = each;
    let excess = shares.reduce((a, s) => a + s.amount, 0) - total;
    // Rounding up overshot the bill: take it back from the equal shares, last first.
    for (let i = equal.length - 1; i >= 0 && excess > 0; i--) {
      const cut = Math.min(excess, equal[i]!.amount);
      equal[i]!.amount -= cut;
      excess -= cut;
    }
  }
  const sum = shares.reduce((a, s) => a + s.amount, 0);
  if (sum > total) throw new DomainError("SPLIT_INVALID");
  return { total, shares: shares.map(({ mode: _m, ...s }) => s), owner_amount: total - sum };
}

// ---------------------------------------------------------------- matching a new expense to a recurring rule

export interface RuleOccurrence {
  id: string;
  due_date: string; // YYYY-MM-DD
}

export interface SplitRule {
  id: string;
  name: string;
  amount: string;
  account_id: string;
  interval: "WEEKLY" | "MONTHLY" | "YEARLY";
  category_id: string | null;
  window_start: number | null;
  window_end: number | null;
  tolerance_pct: number;
  payee_keywords: string[];
  rounding: number;
  owner_share: boolean;
  auto_apply: boolean;
  participants: (Participant & { name?: string })[];
  occurrences: RuleOccurrence[];
}

export interface SplitTx {
  id: string;
  kind: string;
  status: string;
  amount: string;
  account_id: string | null;
  effective_at: string;
  note: string | null;
  merchant: string | null;
  category_id: string | null;
  source?: string;
}

export interface SplitContext {
  tx: SplitTx;
  live: { id: string; state: string } | null;
  matched_occurrence: boolean;
  dismissed_rules: string[];
  rules: SplitRule[];
}

export interface RuleMatch {
  rule: SplitRule;
  occurrence: RuleOccurrence;
  score: number;
  hints: string[];
  decision: "AUTO" | "PROPOSE";
}

export const AUTO_SCORE = 0.8;
export const PROPOSE_SCORE = 0.5;
/** Days a payment may come before / after the window (people pay a little early or late). */
const SLACK_BEFORE = 3;
const SLACK_AFTER = 3;

/** Lower-case, no Vietnamese diacritics, single spaces. */
export function fold(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/đ/g, "d")
    .replace(/Đ/g, "d")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Calendar date (YYYY-MM-DD) in Vietnam for an instant. */
export function vnDate(iso: string): string {
  const t = new Date(new Date(iso).getTime() + 7 * 3_600_000);
  return t.toISOString().slice(0, 10);
}

function addDays(date: string, days: number): string {
  const t = new Date(`${date}T00:00:00Z`);
  t.setUTCDate(t.getUTCDate() + days);
  return t.toISOString().slice(0, 10);
}

function lastDay(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** [from, to] (inclusive, local dates) in which an occurrence's payment is expected. */
export function occurrenceWindow(rule: Pick<SplitRule, "interval" | "window_start" | "window_end">, due: string): [string, string] {
  if (rule.interval === "MONTHLY" && rule.window_start && rule.window_end) {
    const [y, m] = due.split("-").map(Number) as [number, number];
    const ld = lastDay(y, m);
    const pad = (n: number) => String(n).padStart(2, "0");
    const start = `${y}-${pad(m)}-${pad(Math.min(rule.window_start, ld))}`;
    const end = `${y}-${pad(m)}-${pad(Math.min(rule.window_end, ld))}`;
    return [addDays(start, -SLACK_BEFORE), addDays(end, SLACK_AFTER)];
  }
  return [addDays(due, -SLACK_BEFORE), addDays(due, SLACK_AFTER)];
}

/**
 * Best rule for a new expense, or null. Required: posted money-out, not split / matched yet, amount within the rule's
 * tolerance and date inside an expected occurrence's window. Score: amount closeness, same account, payee keywords
 * (or the rule's name) in the bank content. AUTO when confident and the rule allows it; otherwise PROPOSE.
 */
export function matchRule(ctx: SplitContext): RuleMatch | null {
  const { tx } = ctx;
  if (tx.status !== "POSTED" || !["EXPENSE", "UNKNOWN_DEBIT"].includes(tx.kind)) return null;
  if (ctx.live || ctx.matched_occurrence) return null;
  const amount = Number(tx.amount);
  if (!(amount > 0)) return null;
  const day = vnDate(tx.effective_at);
  const text = fold(`${tx.note ?? ""} ${tx.merchant ?? ""}`);
  const found: RuleMatch[] = [];
  for (const rule of ctx.rules) {
    if (ctx.dismissed_rules.includes(rule.id)) continue;
    const expected = Number(rule.amount);
    if (!(expected > 0)) continue;
    const diff = Math.abs(amount - expected) / expected;
    // A plain recurring item (no window / split settings, e.g. "Netflix 70.000đ") is a much weaker signal than a rule
    // the owner described: it must match the amount (±1%) AND the account or its name — otherwise every 65.000đ
    // coffee would be "Có phải Netflix?".
    const plain = !rule.window_start || !rule.window_end;
    const tol = plain ? 0.01 : Math.max(0, rule.tolerance_pct ?? 10) / 100;
    if (diff > tol + 1e-9) continue;
    const occurrence = rule.occurrences.find((o) => {
      const [from, to] = occurrenceWindow(rule, o.due_date);
      return day >= from && day <= to;
    });
    if (!occurrence) continue;
    const hints: string[] = [];
    let score = 0.45;
    if (diff <= 0.005) {
      score += 0.25;
      hints.push("Đúng số tiền");
    } else {
      score += tol > 0 ? 0.25 * (1 - diff / tol) : 0;
      hints.push("Gần đúng số tiền");
    }
    const sameAccount = !!tx.account_id && tx.account_id === rule.account_id;
    if (sameAccount) {
      score += 0.15;
      hints.push("Đúng tài khoản");
    }
    const words = [...(rule.payee_keywords ?? []), rule.name].map(fold).filter((w) => w.length >= 3);
    const named = !!text && words.some((w) => text.includes(w));
    if (named) {
      score += 0.2;
      hints.push("Nội dung khớp");
    }
    if (plain && !sameAccount && !named) continue;
    found.push({ rule, occurrence, score: Math.min(1, Math.round(score * 1000) / 1000), hints, decision: "PROPOSE" });
  }
  if (!found.length) return null;
  found.sort((a, b) => b.score - a.score);
  const best = found[0]!;
  if (best.score < PROPOSE_SCORE) return null;
  const ambiguous = found.length > 1 && found[0]!.score - found[1]!.score < 0.05;
  best.decision = best.score >= AUTO_SCORE && best.rule.auto_apply && !ambiguous ? "AUTO" : "PROPOSE";
  return best;
}

/** The rule's participants turned into shares of this bill's actual amount. */
export function sharesForRule(rule: SplitRule, total: number): SplitResult {
  return computeShares(total, rule.participants ?? [], { ownerShare: rule.owner_share, rounding: rule.rounding });
}

// ---------------------------------------------------------------- texts

/** 1600000 -> "1.600.000đ" */
export function vnd(n: number | string): string {
  const v = Math.round(Number(n));
  return `${String(Math.abs(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ".")}đ`;
}

export function sharesLine(shares: { name: string; amount: number | string }[]): string {
  return shares.map((s) => `${s.name} nợ ${vnd(s.amount)}`).join(", ");
}

export function appliedPush(name: string, total: number | string, shares: { name: string; amount: number | string }[]) {
  return {
    title: `Đã ghi ${name} ${vnd(total)}`,
    body: shares.length ? `${sharesLine(shares)} · Chạm để xem hoặc hoàn tác` : "Đã khớp khoản định kỳ · Chạm để xem hoặc hoàn tác",
  };
}

export function proposedPush(name: string, total: number | string, shares: { name: string; amount: number | string }[]) {
  return {
    title: `Có phải ${name}? ${vnd(total)}`,
    body: shares.length ? `Chia: ${shares.map((s) => `${s.name} ${vnd(s.amount)}`).join(", ")} · Chạm để xác nhận` : "Chạm để xác nhận",
  };
}

export function missedPush(name: string, dueDate: string, windowStart: number, windowEnd: number) {
  const month = Number(dueDate.slice(5, 7));
  return {
    title: `Chưa thấy khoản ${name} tháng ${month}`,
    body: `Thường trả ngày ${windowStart}–${windowEnd}. Nếu đã trả, mở MoMa để ghi nhận.`,
  };
}

// ---------------------------------------------------------------- names -> contacts

export interface ContactRef {
  id: string;
  alias: string;
}

/** Contact for a name read from a bill or said in chat: exact folded match, then a unique first-word / contained match. */
export function matchContact(name: string, contacts: ContactRef[]): ContactRef | null {
  const n = fold(name);
  if (!n) return null;
  const exact = contacts.filter((c) => fold(c.alias) === n);
  if (exact.length === 1) return exact[0]!;
  const loose = contacts.filter((c) => {
    const a = fold(c.alias);
    return a.split(" ").includes(n) || n.split(" ").includes(a) || (a.length >= 3 && n.includes(a));
  });
  return loose.length === 1 ? loose[0]! : null;
}
