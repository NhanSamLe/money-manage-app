// Life-plan projections ("mua căn hộ 2,5 tỷ, trả trước 30%": when can I afford it?) — pure math (D-027).
// Inputs: the owner's real monthly income / expense (robust medians, so one-off months don't skew it), what they have
// now, and the plan's assumptions. Market assumptions (price inflation, CPI, deposit / loan rates) come from a
// provider so a live market-data module can replace the defaults later.

import { roundVnd, shortVnd } from "./estimate";

export type LifeKind = "HOUSE" | "CAR" | "TRAVEL" | "WEDDING" | "EDUCATION" | "OTHER";
export const LIFE_KINDS: LifeKind[] = ["HOUSE", "CAR", "TRAVEL", "WEDDING", "EDUCATION", "OTHER"];

/** Market assumptions; DEFAULT_MARKET until a live provider (gold / CPI / bank rates feed) is plugged in. */
export interface MarketAssumptions {
  /** Yearly price change of this kind of purchase (%). */
  priceInflationPct(kind: LifeKind): number;
  /** Yearly consumer inflation applied to the owner's spending (%). */
  cpiPct(): number;
  /** Yearly return on money saved for the plan (bank savings, %). */
  depositRatePct(): number;
  /** Typical yearly loan rate for this purchase (%). */
  loanRatePct(kind: LifeKind): number;
  source: string;
}

export const DEFAULT_MARKET: MarketAssumptions = {
  priceInflationPct: (k) => ({ HOUSE: 6, CAR: 1.5, TRAVEL: 4, WEDDING: 5, EDUCATION: 6, OTHER: 3.5 })[k],
  cpiPct: () => 3.5,
  depositRatePct: () => 4.5,
  loanRatePct: (k) => (k === "HOUSE" ? 9 : k === "CAR" ? 9.5 : 12),
  source: "Giả định mặc định (chưa có dữ liệu thị trường trực tiếp)",
};

export interface MonthRow {
  month: string; // YYYY-MM
  income: number;
  expense: number;
  partial?: boolean;
}

export interface Wealth {
  assets: number;
  liabilities: number;
  receivable: number;
  payable: number;
  goals: { id: string; name: string; target: number; allocated: number }[];
}

export interface Baseline {
  monthly_income: number;
  monthly_expense: number;
  monthly_saving: number;
  months_used: number;
  /** Money free for new plans now: known assets − liabilities − payables − money already set aside for goals. */
  available: number;
}

/** Median income / expense of the last complete months (up to 6), which ignores a single huge one-off month. */
export function savingsBaseline(months: MonthRow[], wealth: Wealth): Baseline {
  const full = months.filter((m) => !m.partial && (m.income > 0 || m.expense > 0)).slice(-6);
  const pick = full.length ? full : months.filter((m) => m.income > 0 || m.expense > 0).slice(-1);
  const med = (xs: number[]) => {
    if (!xs.length) return 0;
    const s = [...xs].sort((a, b) => a - b);
    const m = Math.floor(s.length / 2);
    return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
  };
  const income = med(pick.map((m) => m.income));
  const expense = med(pick.map((m) => m.expense));
  const reserved = wealth.goals.reduce((s, g) => s + Math.max(0, g.allocated), 0);
  return {
    monthly_income: Math.round(income),
    monthly_expense: Math.round(expense),
    monthly_saving: Math.round(income - expense),
    months_used: pick.length,
    available: Math.max(0, Math.round(wealth.assets - wealth.liabilities - wealth.payable - reserved)),
  };
}

export interface LifePlanInput {
  name: string;
  kind: LifeKind;
  price: number; // today's price
  down_pct: number; // 30 = 30 % paid from savings; 100 = no loan
  loan_rate_pct?: number | null;
  loan_years?: number | null;
  inflation_pct?: number | null; // null = market default for the kind
  income_growth_pct?: number | null; // yearly
  extra_saving?: number | null; // per month on top of the current rate (can be negative)
  /** Money already set aside for this plan (its goal's allocation); null = use the owner's free money. */
  saved_now?: number | null;
}

export interface Projection {
  reachable: boolean;
  months: number | null; // from now
  reach_month: string | null; // YYYY-MM
  price_then: number;
  needed_then: number; // down payment at that time
  saved_now: number;
  monthly_saving: number; // used now (current rate + extra)
  loan_amount: number;
  monthly_payment: number;
  payment_to_income: number | null; // share of monthly income at that time (0..1)
  timeline: { month: string; saved: number; needed: number }[]; // yearly points
  what_if: { label: string; reach_month: string | null; months: number | null }[];
  assumptions: string[];
  summary: string;
}

/** Monthly payment of an annuity loan. */
export function loanPayment(principal: number, yearlyRatePct: number, years: number): number {
  if (principal <= 0 || years <= 0) return 0;
  const n = Math.round(years * 12);
  const r = yearlyRatePct / 100 / 12;
  if (r === 0) return principal / n;
  return (principal * r) / (1 - Math.pow(1 + r, -n));
}

export function addMonths(ym: string, n: number): string {
  const [y, m] = ym.split("-").map(Number) as [number, number];
  const t = y * 12 + (m - 1) + n;
  return `${Math.floor(t / 12)}-${String((t % 12) + 1).padStart(2, "0")}`;
}

/** "T9/2035". */
export function monthLabel(ym: string | null): string {
  if (!ym) return "chưa xác định";
  const [y, m] = ym.split("-");
  return `T${Number(m)}/${y}`;
}

const MAX_MONTHS = 600;

interface Sim {
  months: number | null;
  priceThen: number;
  neededThen: number;
  incomeThen: number;
  timeline: { month: string; saved: number; needed: number }[];
}

interface SimParams {
  kind: LifeKind;
  price: number;
  down_pct: number;
  loan_rate_pct: number;
  loan_years: number;
  inflation_pct: number;
  income_growth_pct: number;
  extra_saving: number;
  saved_now: number;
}

function simulate(p: SimParams, b: Baseline, mk: MarketAssumptions, nowMonth: string): Sim {
  const g = p.income_growth_pct / 100;
  const cpi = mk.cpiPct() / 100;
  const dep = mk.depositRatePct() / 100 / 12;
  const infl = p.inflation_pct / 100;
  let saved = p.saved_now;
  const timeline: Sim["timeline"] = [];
  for (let n = 0; n <= MAX_MONTHS; n++) {
    const years = n / 12;
    const price = p.price * Math.pow(1 + infl, years);
    const needed = (price * p.down_pct) / 100;
    if (n % 12 === 0) timeline.push({ month: addMonths(nowMonth, n), saved: Math.round(saved), needed: Math.round(needed) });
    if (saved >= needed) {
      if (n % 12 !== 0) timeline.push({ month: addMonths(nowMonth, n), saved: Math.round(saved), needed: Math.round(needed) });
      return { months: n, priceThen: price, neededThen: needed, incomeThen: b.monthly_income * Math.pow(1 + g, years), timeline };
    }
    // income grows with the plan's growth; spending grows with consumer inflation
    const income = b.monthly_income * Math.pow(1 + g, years);
    const expense = b.monthly_expense * Math.pow(1 + cpi, years);
    const monthly = income - expense + p.extra_saving;
    saved = saved * (1 + dep) + Math.max(0, monthly);
    if (monthly <= 0 && n > 24 && saved < needed && infl >= dep * 12) break; // never catching up
  }
  const price = p.price * Math.pow(1 + infl, MAX_MONTHS / 12);
  return { months: null, priceThen: price, neededThen: (price * p.down_pct) / 100, incomeThen: 0, timeline };
}

export function projectPlan(input: LifePlanInput, b: Baseline, now: Date = new Date(), mk: MarketAssumptions = DEFAULT_MARKET): Projection {
  const nowMonth = new Date(now.getTime() + 7 * 3_600_000).toISOString().slice(0, 7);
  const kind = input.kind;
  const down = Math.min(100, Math.max(1, input.down_pct || 100));
  const loanYears = down >= 100 ? 0 : (input.loan_years ?? (kind === "HOUSE" ? 20 : kind === "CAR" ? 6 : 3));
  const loanRate = down >= 100 ? 0 : (input.loan_rate_pct ?? mk.loanRatePct(kind));
  const p: SimParams = {
    kind,
    price: Math.max(1, input.price),
    down_pct: down,
    loan_rate_pct: loanRate,
    loan_years: loanYears,
    inflation_pct: input.inflation_pct ?? mk.priceInflationPct(kind),
    // unknown growth: income keeps pace with consumer inflation (real income flat), never a shrinking saving rate
    income_growth_pct: input.income_growth_pct ?? mk.cpiPct(),
    extra_saving: input.extra_saving ?? 0,
    saved_now: Math.max(0, input.saved_now ?? b.available),
  };
  const sim = simulate(p, b, mk, nowMonth);
  const reach = sim.months === null ? null : addMonths(nowMonth, sim.months);
  const loan = Math.max(0, sim.priceThen - sim.neededThen);
  const payment = loanPayment(loan, p.loan_rate_pct, p.loan_years);
  const variants: { label: string; patch: Partial<SimParams> }[] = [
    { label: "Tiết kiệm thêm 1tr/tháng", patch: { extra_saving: p.extra_saving + 1_000_000 } },
    { label: "Tiết kiệm thêm 2tr/tháng", patch: { extra_saving: p.extra_saving + 2_000_000 } },
    { label: "Thu nhập tăng 7%/năm", patch: { income_growth_pct: 7 } },
  ];
  if (kind === "HOUSE" || kind === "CAR") variants.push({ label: "Trả trước 20% (vay nhiều hơn)", patch: { down_pct: 20 } });
  const what_if = variants
    .filter((v) => JSON.stringify({ ...p, ...v.patch }) !== JSON.stringify(p))
    .map((v) => {
      const s = simulate({ ...p, ...v.patch }, b, mk, nowMonth);
      return { label: v.label, months: s.months, reach_month: s.months === null ? null : addMonths(nowMonth, s.months) };
    });

  const assumptions = [
    `Tích lũy hiện tại ~${shortVnd(Math.max(0, b.monthly_saving))}/tháng (trung vị ${b.months_used} tháng gần nhất: thu ${shortVnd(b.monthly_income)}, chi ${shortVnd(b.monthly_expense)}).`,
    `Giá ${input.name.toLowerCase()} tăng ${p.inflation_pct}%/năm; chi tiêu tăng theo lạm phát ${mk.cpiPct()}%/năm; tiền để dành sinh lãi ${mk.depositRatePct()}%/năm.`,
    input.income_growth_pct === null || input.income_growth_pct === undefined
      ? `Thu nhập tăng theo lạm phát ${p.income_growth_pct}%/năm (bạn chỉnh được).`
      : p.income_growth_pct
        ? `Thu nhập tăng ${p.income_growth_pct}%/năm.`
        : "Thu nhập giữ nguyên.",
    down < 100 ? `Trả trước ${down}%, vay ${100 - down}% trong ${p.loan_years} năm, lãi ${p.loan_rate_pct}%/năm.` : "Trả đủ 100%, không vay.",
    `Nguồn giả định: ${mk.source}.`,
  ];
  const monthlyNow = Math.round(b.monthly_saving + p.extra_saving);
  const head = `Với tốc độ tích lũy ~${shortVnd(Math.max(0, monthlyNow))}/tháng`;
  const target = down < 100 ? `${input.name} ${shortVnd(p.price)} (trả trước ${down}% ≈ ${shortVnd(sim.neededThen)})` : `${input.name} ${shortVnd(p.price)}`;
  let summary: string;
  if (sim.months === null) {
    summary = monthlyNow <= 0
      ? `Hiện chi tiêu đang bằng hoặc hơn thu nhập nên chưa tích lũy được cho ${input.name.toLowerCase()}. Bắt đầu để dành ~1–2tr/tháng là có lộ trình.`
      : `${head}, ${target} khó đạt trong 50 năm tới — cần tăng tiết kiệm hoặc giảm mục tiêu.`;
  } else if (sim.months === 0) {
    summary = `Bạn đã đủ tiền cho ${target} ngay bây giờ.`;
  } else {
    summary = `${head}, ${target} dự kiến đạt vào ~${monthLabel(reach)}.`;
    const best = what_if.find((w) => w.label.startsWith("Tiết kiệm thêm 2tr") && w.reach_month);
    if (best && best.reach_month !== reach) summary += ` Nếu tiết kiệm thêm 2tr/tháng → ${monthLabel(best.reach_month)}.`;
    if (payment > 0) summary += ` Khoản vay ~${shortVnd(loan)}, trả ~${shortVnd(payment)}/tháng.`;
  }
  return {
    reachable: sim.months !== null,
    months: sim.months,
    reach_month: reach,
    price_then: roundVnd(sim.priceThen),
    needed_then: roundVnd(sim.neededThen),
    saved_now: Math.round(p.saved_now),
    monthly_saving: monthlyNow,
    loan_amount: roundVnd(loan),
    monthly_payment: roundVnd(payment),
    payment_to_income: payment > 0 && sim.incomeThen > 0 ? Math.round((payment / sim.incomeThen) * 100) / 100 : null,
    timeline: sim.timeline,
    what_if,
    assumptions,
    summary,
  };
}

/** Defaults for a new plan of a kind (price is the owner's). */
export function lifeDefaults(kind: LifeKind, price: number): { down_pct: number; loan_years: number } {
  if (kind === "HOUSE") return { down_pct: 30, loan_years: 20 };
  if (kind === "CAR") return price >= 300_000_000 ? { down_pct: 30, loan_years: 6 } : { down_pct: 100, loan_years: 0 };
  return { down_pct: 100, loan_years: 0 };
}

/** "mua nhà" → HOUSE. */
export function inferLifeKind(text: string): LifeKind {
  const t = ` ${text.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/đ/g, "d")} `;
  if (/\b(nha|can ho|chung cu|dat|bat dong san)\b/.test(t)) return "HOUSE";
  if (/\b(xe|oto|o to|xe may|car)\b/.test(t)) return "CAR";
  if (/\b(du lich|di choi|chau au|nhat|han quoc|trip)\b/.test(t)) return "TRAVEL";
  if (/\b(cuoi|dam cuoi|wedding)\b/.test(t)) return "WEDDING";
  if (/\b(hoc|du hoc|thac si|khoa hoc|education)\b/.test(t)) return "EDUCATION";
  return "OTHER";
}
