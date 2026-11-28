import { computeShares, type SplitResult } from "../split/split";
import { normalizeKey } from "./memory";

// Bill photos read in chat: what the bill is (personal necessity vs eating out / entertainment), how many people it
// looks like, and whether to ask "Chia hóa đơn?". Deterministic from the OCR text; the model never does this maths.
// Also the split arithmetic (equal shares incl. the owner, rounding of the others' shares, per-person extras).
// The equal-share arithmetic is the shared one (modules/split/split.ts computeShares); this adds per-person extras.

export type BillPurpose = "PERSONAL" | "EATOUT" | "ENTERTAINMENT" | "HOUSEHOLD" | "OTHER";

export interface BillItem {
  name: string;
  qty: number;
  amount: number | null;
}

export interface BillAnalysis {
  total: number | null;
  merchant: string | null;
  purpose: BillPurpose;
  items: BillItem[];
  /** Best estimate of how many people the bill is for (1 = solo). */
  people: number;
  /** Where `people` came from: printed guest count, combo size, item counts, amount, or default. */
  basis: "pax" | "combo" | "items" | "amount" | "default";
  /** Ask "Chia hóa đơn?" (group + eating out / entertainment, and the owner has not taught "không chia" for it). */
  ask: boolean;
  /** One short Vietnamese sentence for the card. */
  reason: string;
  /** Owner's category names worth trying, most specific first. */
  categoryHints: string[];
}

const PURPOSE_WORDS: [BillPurpose, string[]][] = [
  ["ENTERTAINMENT", ["karaoke", "cgv", "lotte cinema", "galaxy cinema", "bhd", "rap phim", "ve xem phim", "bowling", "bida", "billiard", "game", "escape", "khu vui choi", "vincom ice", "beta cinemas"]],
  ["PERSONAL", ["sieu thi", "bach hoa xanh", "winmart", "coopmart", "co op", "lotte mart", "aeon", "mega market", "go!", "tap hoa", "nha thuoc", "pharmacity", "long chau", "an khang", "guardian", "watsons", "hasaki", "dien may", "the gioi di dong"]],
  ["HOUSEHOLD", ["tien dien", "dien luc", "evn", "tien nuoc", "cap nuoc", "internet", "wifi", "fpt telecom", "vnpt", "viettel", "tien nha", "phi quan ly", "gas"]],
  ["EATOUT", ["nha hang", "quan", "lau", "nuong", "bbq", "buffet", "nhau", "bia", "beer", "pizza", "kfc", "lotteria", "jollibee", "mcdonald", "com", "pho", "bun", "mi", "tra sua", "cafe", "ca phe", "coffee", "highlands", "phuc long", "katinat", "starbucks", "the coffee house", "gong cha", "dimsum", "sushi", "oc", "hai san", "an vat", "banh"]],
];

const DRINK = /\b(tra sua|tra dao|tra|ca phe|cafe|coffee|bac xiu|nuoc ngot|coca|pepsi|7up|sting|sinh to|nuoc ep|nuoc suoi|da chanh|soda|latte|cappuccino|americano|espresso|matcha|cacao)\b/;
const BEER = /\b(bia|beer|tiger|heineken|saigon|333|larue|budweiser|sapporo|ha noi|hanoi)\b/;
const MAIN = /\b(com|pho|bun|mi|mien|hu tieu|chao|suat|phan|burger|banh mi|my y|spaghetti)\b/;
/** Dishes a table shares: they say nothing about how many people ate. */
const SHARED = /\b(canh|lau|rau|dia|trai cay|nom|goi|khai vi|nuong|lau|xao|chien|lau thai|hai san|bo|ga|ca|tom|muc|oc)\b/;
const MONEY = /(\d{1,3}(?:[.,]\d{3})+|\d{4,9})(?:\s*(?:d|đ|vnd|₫))?/gi;
const TOTAL_LINE = /(tong cong|tong tien|tong thanh toan|thanh toan|can thanh toan|khach phai tra|total|tong|thanh tien)/;

function money(s: string): number | null {
  const v = Number(s.replace(/[.,]/g, ""));
  return Number.isFinite(v) && v >= 1000 && v <= 999_999_999 ? v : null;
}

function amountsIn(line: string): number[] {
  const out: number[] = [];
  for (const m of line.matchAll(MONEY)) {
    const v = money(m[1] ?? "");
    if (v !== null) out.push(v);
  }
  return out;
}

function purposeOf(text: string): BillPurpose {
  for (const [p, words] of PURPOSE_WORDS) {
    if (words.some((w) => new RegExp(`(^|\\s)${w.replace(/[!]/g, "\\$&")}(\\s|$)`).test(text))) return p;
  }
  return "OTHER";
}

const CATEGORY_HINTS: Record<BillPurpose, string[]> = {
  EATOUT: ["Ăn uống", "Ăn ngoài", "Cà phê"],
  ENTERTAINMENT: ["Giải trí", "Vui chơi", "Ăn uống"],
  PERSONAL: ["Đi chợ", "Siêu thị", "Mua sắm", "Sức khỏe", "Y tế"],
  HOUSEHOLD: ["Hóa đơn", "Điện nước", "Nhà cửa", "Tiền nhà"],
  OTHER: [],
};

/** Usual price per person: when nothing else says how many people, a large total for the venue suggests a group. */
const PER_HEAD: Partial<Record<BillPurpose, number>> = { EATOUT: 180_000, ENTERTAINMENT: 200_000 };

export interface BillHabits {
  /** Purposes the owner usually does NOT split (learned from "không chia" answers). */
  noSplit?: ReadonlySet<BillPurpose>;
}

/** Reads one OCR'd bill. `text` may still carry the chat photo prefix. */
export function analyzeBill(text: string, habits: BillHabits = {}): BillAnalysis {
  const rawLines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  const lines = rawLines.map((l) => normalizeKey(l));
  const all = lines.join(" \n ");
  const purpose = purposeOf(` ${lines.join(" ")} `);

  // Total: the amount on a "Tổng cộng / Thanh toán" line (last one wins), else the largest amount on the bill.
  let total: number | null = null;
  for (let i = 0; i < lines.length; i++) {
    if (!TOTAL_LINE.test(lines[i] ?? "")) continue;
    const here = amountsIn(rawLines[i] ?? "");
    const next = here.length ? here : amountsIn(rawLines[i + 1] ?? "");
    if (next.length) total = next[next.length - 1] ?? total;
  }
  if (total === null) {
    const every = rawLines.flatMap(amountsIn);
    total = every.length ? Math.max(...every) : null;
  }

  // Merchant: first line with letters that is not a header word.
  const merchant = rawLines.find((l, i) => /[a-zA-ZÀ-ỹ]{3}/.test(l) && !/(hoa don|phieu|bill|receipt|dia chi|dc:|sdt|tel|ngay|gio)/.test(lines[i] ?? "")) ?? null;

  // Items: "<name> <qty> <price> <amount>" or "<qty> x <name> ... <amount>".
  const items: BillItem[] = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i] ?? "";
    if (TOTAL_LINE.test(l) || /(so khach|pax|ban so|thu ngan|nhan vien|giam gia|vat|phi dich vu|tien mat|chuyen khoan|tien thua)/.test(l)) continue;
    const amounts = amountsIn(rawLines[i] ?? "");
    if (!amounts.length || !/[a-z]{2}/.test(l)) continue;
    const qtyMatch = l.match(/(?:^|\s)(?:x\s*)?(\d{1,2})(?:\s*x)?(?=\s)/) ?? l.match(/\bsl\s*:?\s*(\d{1,2})\b/);
    const qty = Math.min(30, Math.max(1, Number(qtyMatch?.[1] ?? 1)));
    const name = (rawLines[i] ?? "").replace(MONEY, "").replace(/(?:^|\s)x?\s*\d{1,2}\s*x?(?=\s|$)/g, " ").replace(/\s+/g, " ").trim();
    if (name.length < 2) continue;
    items.push({ name: name.slice(0, 60), qty, amount: amounts[amounts.length - 1] ?? null });
  }

  // How many people.
  let people = 1;
  let basis: BillAnalysis["basis"] = "default";
  const pax = all.match(/(?:so khach|sl khach|khach|pax|guests?|so nguoi)\s*:?\s*(\d{1,2})\b/);
  const combo = all.match(/(?:combo|set|lau|suat)\s*(?:cho\s*)?(\d{1,2})\s*(?:nguoi|ng|pax)\b/);
  if (pax && Number(pax[1]) >= 1) {
    people = Number(pax[1]);
    basis = "pax";
  } else if (combo && Number(combo[1]) >= 2) {
    people = Number(combo[1]);
    basis = "combo";
  } else if (items.length) {
    const count = (re: RegExp) => items.filter((it) => re.test(normalizeKey(it.name))).reduce((a, it) => a + it.qty, 0);
    const drinks = count(DRINK);
    const beers = count(BEER);
    const mains = items
      .filter((it) => {
        const n = normalizeKey(it.name);
        return MAIN.test(n) && !SHARED.test(n.replace(MAIN, " ")) && !DRINK.test(n) && !BEER.test(n);
      })
      .reduce((a, it) => a + it.qty, 0);
    const est = Math.max(drinks, mains, beers ? Math.ceil(beers / 3) : 0);
    if (est >= 2) {
      people = Math.min(12, est);
      basis = "items";
    } else if (est === 1) {
      basis = "items";
    }
  }
  const perHead = PER_HEAD[purpose];
  if (basis === "default" && perHead && total && total >= perHead * 1.8) {
    people = Math.min(8, Math.max(2, Math.round(total / perHead)));
    basis = "amount";
  }
  if (purpose === "PERSONAL") people = 1;

  const group = people >= 2;
  const splitty = purpose === "EATOUT" || purpose === "ENTERTAINMENT" || (purpose === "OTHER" && group && basis !== "amount");
  const ask = group && splitty && !(habits.noSplit?.has(purpose) ?? false);

  const reason = reasonText(purpose, people, basis, items, habits.noSplit?.has(purpose) ?? false);
  return { total, merchant: merchant ? merchant.slice(0, 80) : null, purpose, items: items.slice(0, 30), people, basis, ask, reason, categoryHints: CATEGORY_HINTS[purpose] };
}

const PURPOSE_LABEL: Record<BillPurpose, string> = {
  PERSONAL: "đồ dùng/nhu cầu cá nhân",
  EATOUT: "ăn uống bên ngoài",
  ENTERTAINMENT: "vui chơi giải trí",
  HOUSEHOLD: "hóa đơn sinh hoạt",
  OTHER: "khoản chi",
};

function reasonText(p: BillPurpose, n: number, basis: BillAnalysis["basis"], items: BillItem[], muted: boolean): string {
  if (p === "PERSONAL") return "Hóa đơn mua sắm nhu cầu cá nhân, ghi cho riêng bạn.";
  if (n < 2) return `Có vẻ chỉ mình bạn (${PURPOSE_LABEL[p]}).`;
  const top = items
    .filter((it) => it.qty >= 2)
    .slice(0, 2)
    .map((it) => `${it.qty} ${it.name.toLowerCase()}`)
    .join(", ");
  const why =
    basis === "pax" ? `hóa đơn ghi ${n} khách` : basis === "combo" ? `có combo cho ${n} người` : basis === "items" ? (top ? `hóa đơn có ${top}` : "nhiều món giống nhau") : "tổng tiền khá lớn cho một người";
  return `${why[0]?.toUpperCase()}${why.slice(1)} → có vẻ đi ${n} người${muted ? " (bạn thường không chia loại này)" : ""}.`;
}

// ---------------------------------------------------------------- split maths
export interface SplitShare {
  /** null = the owner. */
  who: string | null;
  amount: number;
}

/**
 * Equal split of `total` between `people` (+ the owner when `includeOwner`), each other person's share rounded UP to
 * `rounding` (0 = exact), the owner absorbing the difference. `extras` (name -> amount) are added to that person's
 * share on top of the equal part (e.g. "Huy gọi thêm bia 60k"). Sum of shares always equals `total`.
 */
export function computeSplit(total: number, people: string[], opts: { includeOwner?: boolean; rounding?: number; extras?: Record<string, number> } = {}): SplitShare[] {
  const includeOwner = opts.includeOwner ?? true;
  const rounding = Math.max(0, Math.floor(opts.rounding ?? 5000));
  const extras = opts.extras ?? {};
  const extraSum = Object.values(extras).reduce((a, v) => a + Math.max(0, v), 0);
  const names = [...new Set(people.map((p) => p.trim()).filter(Boolean))];
  if (!names.length || total <= 0 || !Number.isInteger(total) || extraSum > total) return [];
  // The equal part uses the shared split maths (modules/split/split.ts); extras sit on top of a person's share.
  let r: SplitResult;
  try {
    r = computeShares(total - extraSum, names.map((n) => ({ name: n, mode: "EQUAL" as const })), { ownerShare: includeOwner, rounding });
  } catch {
    return [];
  }
  const shares: SplitShare[] = r.shares.map((s) => ({ who: s.name, amount: s.amount + Math.max(0, extras[s.name] ?? 0) }));
  if (includeOwner) shares.push({ who: null, amount: r.owner_amount });
  return shares;
}
// ---------------------------------------------------------------- names
/** Fuzzy contact match: exact normalized alias, then alias containing / contained in the name (>= 2 chars). */
export function matchContact<T extends { id: string; alias: string }>(name: string, contacts: T[]): T | undefined {
  const k = normalizeKey(name);
  if (!k) return undefined;
  const exact = contacts.find((c) => normalizeKey(c.alias) === k);
  if (exact) return exact;
  const loose = contacts.filter((c) => {
    const a = normalizeKey(c.alias);
    return a.length >= 2 && (a.split(" ").includes(k) || k.split(" ").includes(a));
  });
  return loose.length === 1 ? loose[0] : undefined;
}

/** Memory key of a group of people who split together (order-insensitive). */
export function groupKey(names: string[]): string {
  return `chia bill ${[...new Set(names.map((n) => normalizeKey(n)).filter(Boolean))].sort().join(" ")}`.slice(0, 80);
}
export const NO_SPLIT_KEY = (p: BillPurpose) => `khong chia ${p.toLowerCase()}`;
export const ROUNDING_KEY = "lam tron phan chia";
