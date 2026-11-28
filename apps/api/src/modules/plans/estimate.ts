// Event cost estimates ("tối thứ 7 đi nhậu với nhóm Nam", "tiệc tốt nghiệp ~30 người") and plan-vs-actual (D-027).
// Pure functions: the owner's own history in (money-out rows with their own share after splits, past event plans with
// actuals), an estimate out (low / likely / high, breakdown, the owner's expected share, stated assumptions).

export type EventKind = "NHAU" | "AN_UONG" | "CAFE" | "TIEC" | "SINH_NHAT" | "DU_LICH" | "KHAC";
export const EVENT_KINDS: EventKind[] = ["NHAU", "AN_UONG", "CAFE", "TIEC", "SINH_NHAT", "DU_LICH", "KHAC"];
export type Transport = "GRAB" | "OWN" | "NONE";

/** One money-out row (pf_plan_spend_rows): amount = money that left, owner_amount = the owner's share after a split. */
export interface SpendRow {
  id: string;
  at: string;
  kind: string;
  amount: number;
  owner_amount: number;
  group_size: number | null;
  category: string | null;
  merchant: string | null;
  note: string | null;
  /** Pre-computed by pf_plan_spend_rows (no Unicode work in the Worker): VN hour, normalised text, flags. */
  hour?: number | undefined;
  norm?: string | undefined;
  ride?: boolean | undefined;
  food?: boolean | undefined;
}

/** A closed earlier plan: what was expected for the owner and what it really cost them. */
export interface PastEvent {
  kind: EventKind;
  estimated_owner: number;
  actual_owner: number;
}

export interface EstimateInput {
  title: string;
  kind?: EventKind | undefined;
  starts_at: string; // ISO
  ends_at?: string | undefined; // ISO
  headcount?: number | undefined; // people in total, the owner included
  owner_pays?: boolean | undefined; // "tôi bao" / the owner hosts
  transport?: Transport | undefined;
}

export interface EstimateItem {
  key: "food" | "drinks" | "food_drinks" | "venue" | "photo" | "stay" | "rides" | "misc";
  label: string;
  amount: number;
}

export interface Estimate {
  kind: EventKind;
  headcount: number;
  owner_pays: boolean;
  transport: Transport;
  /** Whole event (everyone's food, the owner's rides, ...). */
  total: { low: number; likely: number; high: number };
  /** What the owner is expected to pay after splitting with the others. */
  owner: { low: number; likely: number; high: number };
  breakdown: EstimateItem[];
  rides: { count: number; each: number; surge: boolean } | null;
  per_head: number;
  assumptions: string[];
  basis: { samples: number; ride_samples: number; past_events: number; calibration: number; source: "history" | "prior" | "mixed" };
  summary: string;
}

// ---------------------------------------------------------------- text helpers
export function norm(s: string | null | undefined): string {
  return ` ${(s ?? "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/đ/g, "d")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()} `;
}
const has = (t: string, words: string[]) => words.some((w) => t.includes(` ${w} `));

const KIND_WORDS: [EventKind, string[]][] = [
  ["TIEC", ["tot nghiep", "tiec", "lien hoan", "ky yeu", "khai truong", "tan gia", "dam cuoi", "dam hoi", "party", "an mung"]],
  ["SINH_NHAT", ["sinh nhat", "sn", "birthday"]],
  ["DU_LICH", ["du lich", "di choi xa", "phuot", "da lat", "vung tau", "nha trang", "phu quoc", "da nang", "ha long", "sapa", "trip", "nghi duong", "cam trai"]],
  ["NHAU", ["nhau", "bia", "beer", "lai rai", "ruou", "oc", "nuong", "lau", "pub", "bar", "karaoke", "hat"]],
  ["CAFE", ["cafe", "ca phe", "cf", "tra sua", "coffee"]],
  ["AN_UONG", ["an", "an toi", "an trua", "an sang", "an uong", "buffet", "com", "pho", "bun", "nha hang", "dinner", "lunch"]],
];

/** "tối thứ 7 đi nhậu với nhóm Nam" → NHAU. */
export function inferKind(text: string): EventKind {
  const t = norm(text);
  for (const [k, words] of KIND_WORDS) if (has(t, words)) return k;
  return "KHAC";
}

const RIDE_WORDS = ["grab", "be", "xanh sm", "xanhsm", "gojek", "taxi", "xe om", "uber", "vinasun", "mai linh", "grabcar", "grabbike", "gsm"];
const NOT_RIDE = ["xang", "gui xe", "do xe", "bai xe", "rua xe", "sua xe", "ve xe", "ve may bay", "bao duong"];
const FOOD_CATS = ["an uong", "an", "nha hang", "do uong", "giai tri", "nhau", "cafe", "ca phe"];
const FOOD_WORDS = ["nhau", "bia", "beer", "lau", "nuong", "oc", "quan", "nha hang", "buffet", "karaoke", "pub", "bar", "an", "com", "pho", "bun", "cafe", "ca phe", "tra sua", "coffee", "highlands", "phuc long", "katinat", "starbucks"];

// Normalised texts per row, computed once (Workers free plan: 10 ms CPU per request, so no repeated NFD work).
type TextRow = Pick<SpendRow, "category" | "merchant" | "note"> & { norm?: string | undefined; ride?: boolean | undefined; food?: boolean | undefined };
const textCache = new WeakMap<object, { t: string; c: string }>();
function texts(r: TextRow): { t: string; c: string } {
  let v = textCache.get(r);
  if (!v) {
    v = { t: norm(`${r.merchant ?? ""} ${r.note ?? ""}`), c: norm(r.category) };
    textCache.set(r, v);
  }
  return v;
}

export function isRide(r: Pick<SpendRow, "category" | "merchant" | "note" | "amount"> & { ride?: boolean | undefined }): boolean {
  if (typeof r.ride === "boolean") return r.ride;
  const { t, c } = texts(r);
  if (has(t, NOT_RIDE)) return false;
  if (has(t, RIDE_WORDS)) return true;
  return has(c, ["di chuyen"]) && r.amount >= 12_000 && r.amount <= 600_000 && !has(c, NOT_RIDE);
}

export function isFood(r: TextRow): boolean {
  if (typeof r.food === "boolean") return r.food;
  const { t, c } = texts(r);
  return has(c, FOOD_CATS) || has(t, FOOD_WORDS);
}

/** Category + merchant + note, normalised (from the database when available). */
function allText(r: TextRow): string {
  if (typeof r.norm === "string") return r.norm;
  const x = texts(r);
  return `${x.c}${x.t}`;
}

/** History window used for estimates (bounded: the SQL also caps the rows). */
export const HISTORY_DAYS = 120;

// ---------------------------------------------------------------- numbers
export function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}
export function quantile(xs: number[], q: number): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return s[lo]! + (s[hi]! - s[lo]!) * (pos - lo);
}
/** Rounds to a "người thật" amount: 10k steps, 50k steps above 2tr. */
export function roundVnd(n: number): number {
  if (!Number.isFinite(n) || n <= 0) return 0;
  const step = n >= 2_000_000 ? 50_000 : 10_000;
  return Math.max(step, Math.round(n / step) * step);
}
/** "850.000đ" / "1,2tr" style. */
export function vnd(n: number): string {
  return `${Math.round(n).toLocaleString("vi-VN").replace(/,/g, ".")}đ`;
}
export function shortVnd(n: number): string {
  if (n >= 1_000_000_000) return `${trim(n / 1_000_000_000)} tỷ`;
  if (n >= 1_000_000) return `${trim(n / 1_000_000)}tr`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}k`;
  return `${Math.round(n)}đ`;
}
const trim = (x: number) => (Math.round(x * 10) / 10).toString().replace(".", ",");

/** Hour of an ISO time in Vietnam. */
export function vnHour(iso: string): number {
  return new Date(Date.parse(iso) + 7 * 3_600_000).getUTCHours();
}

// ---------------------------------------------------------------- priors (no history)
/** Food + drinks per person (VND) when the owner has no similar history. */
export const PRIOR_PER_HEAD: Record<EventKind, number> = {
  NHAU: 250_000,
  AN_UONG: 150_000,
  CAFE: 55_000,
  TIEC: 300_000,
  SINH_NHAT: 200_000,
  DU_LICH: 1_200_000, // per person per day: stay + food + local travel
  KHAC: 150_000,
};
export const PRIOR_RIDE = 70_000;
/** Late return (≥ 22:00) costs more: night surge. */
export const NIGHT_SURGE = 1.3;
const HOSTED: EventKind[] = ["TIEC", "SINH_NHAT"];

// ---------------------------------------------------------------- history samples
/** Per-person cost of earlier outings like this one (split bills give the group size; otherwise the owner's spend). */
export function diningSamples(rows: SpendRow[], kind: EventKind): number[] {
  const out: number[] = [];
  for (const r of rows) {
    if (isRide(r) || !isFood(r)) continue;
    const h = typeof r.hour === "number" ? r.hour : vnHour(r.at);
    const t = allText(r);
    const evening = h >= 16 || h < 3;
    switch (kind) {
      case "NHAU":
        if (!(has(t, ["nhau", "bia", "beer", "lau", "nuong", "oc", "pub", "bar", "karaoke", "quan"]) || (evening && r.amount >= 150_000))) continue;
        break;
      case "CAFE":
        if (!has(t, ["cafe", "ca phe", "tra sua", "coffee", "highlands", "phuc long", "katinat", "starbucks"])) continue;
        break;
      case "AN_UONG":
      case "SINH_NHAT":
      case "TIEC":
      case "KHAC":
        if (r.amount < 60_000) continue;
        break;
      case "DU_LICH":
        continue; // trips are estimated from priors + past trips (closed plans), not from single meals
    }
    const group = r.group_size && r.group_size > 1 ? r.group_size : null;
    out.push(group ? r.amount / group : r.owner_amount);
  }
  return out.filter((x) => x > 0);
}

export function rideSamples(rows: SpendRow[]): number[] {
  return rows.filter((r) => isRide(r)).map((r) => r.amount).filter((x) => x >= 12_000 && x <= 600_000);
}

/** Ratio actual / estimate of closed plans of the same kind (median, bounded), pulled toward 1 when few. */
export function calibration(past: PastEvent[], kind: EventKind): { factor: number; n: number } {
  const ratios = past
    .filter((p) => p.kind === kind && p.estimated_owner > 0 && p.actual_owner > 0)
    .map((p) => Math.min(2.5, Math.max(0.3, p.actual_owner / p.estimated_owner)));
  if (!ratios.length) return { factor: 1, n: 0 };
  const m = Math.min(1.8, Math.max(0.6, median(ratios)));
  const w = Math.min(1, ratios.length / 3);
  return { factor: 1 + (m - 1) * w, n: ratios.length };
}

// ---------------------------------------------------------------- estimate
export function estimateEvent(input: EstimateInput, rows: SpendRow[], past: PastEvent[] = []): Estimate {
  const kind: EventKind = input.kind && EVENT_KINDS.includes(input.kind) ? input.kind : inferKind(input.title);
  const headcount = Math.min(500, Math.max(1, Math.round(input.headcount ?? (kind === "TIEC" ? 20 : 1))));
  const ownerPays = input.owner_pays ?? HOSTED.includes(kind);
  const transport: Transport = input.transport ?? "GRAB";
  const start = input.starts_at;
  const end = input.ends_at ?? new Date(Date.parse(start) + (kind === "DU_LICH" ? 48 : 4) * 3_600_000).toISOString();
  const days = Math.max(1, Math.ceil((Date.parse(end) - Date.parse(start)) / 86_400_000));
  const title = norm(input.title);
  const assumptions: string[] = [];

  // per-head food + drinks: blend the owner's own median with the prior
  const samples = diningSamples(rows, kind);
  const prior = PRIOR_PER_HEAD[kind];
  const w = samples.length / (samples.length + 2);
  let perHead = samples.length ? w * median(samples) + (1 - w) * prior : prior;
  if (!samples.length) assumptions.push(`Chưa có lịch sử tương tự: lấy mức phổ biến ~${shortVnd(prior)}/người${kind === "DU_LICH" ? "/ngày" : ""}.`);
  else assumptions.push(`Dựa trên ${samples.length} lần tương tự của bạn (~${shortVnd(median(samples))}/người).`);

  const items: EstimateItem[] = [];
  const add = (key: EstimateItem["key"], label: string, amount: number) => {
    const a = roundVnd(amount);
    if (a > 0) items.push({ key, label, amount: a });
  };

  switch (kind) {
    case "NHAU": {
      const food = perHead * headcount;
      add("food", "Đồ ăn", food * 0.55);
      add("drinks", "Bia, nước", food * 0.45);
      break;
    }
    case "CAFE":
      add("drinks", "Đồ uống", perHead * headcount);
      break;
    case "TIEC": {
      add("food_drinks", `Ăn uống ${headcount} người`, perHead * headcount);
      add("venue", "Địa điểm, trang trí", Math.max(1_000_000, 50_000 * headcount));
      if (has(title, ["tot nghiep", "ky yeu", "chup", "anh", "photo"])) {
        add("photo", "Chụp ảnh", 1_500_000);
        assumptions.push("Có thuê chụp ảnh (~1,5tr).");
      }
      assumptions.push(`Bạn là người tổ chức nên trả toàn bộ; địa điểm/trang trí tối thiểu 1tr.`);
      break;
    }
    case "SINH_NHAT":
      add("food_drinks", `Ăn uống ${headcount} người`, perHead * headcount);
      add("venue", "Bánh, trang trí", 400_000);
      break;
    case "DU_LICH":
      add("stay", `Ở + ăn ${days} ngày × ${headcount} người`, perHead * headcount * days);
      assumptions.push("Chưa tính vé máy bay/xe khách đường dài (nếu có, bạn nói thêm để mình cộng vào).");
      break;
    default:
      add("food_drinks", "Ăn uống, chi tiêu", perHead * headcount);
  }

  // rides both ways, with a night surge for a late return
  let rides: Estimate["rides"] = null;
  const rideXs = rideSamples(rows);
  if (transport === "GRAB") {
    const each = rideXs.length >= 3 ? median(rideXs) : rideXs.length ? (median(rideXs) + PRIOR_RIDE) / 2 : PRIOR_RIDE;
    const endHour = vnHour(end);
    const surge = kind !== "DU_LICH" && (endHour >= 22 || endHour < 5);
    const total = each + each * (surge ? NIGHT_SURGE : 1);
    rides = { count: 2, each: roundVnd(each), surge };
    add("rides", `Grab đi-về ~2×${shortVnd(each)}${surge ? " (về khuya giá cao hơn)" : ""}`, total);
    if (!rideXs.length) assumptions.push(`Chưa thấy chuyến Grab/Be nào: ước ~${shortVnd(PRIOR_RIDE)}/chuyến.`);
  } else if (transport === "OWN") {
    assumptions.push("Bạn tự đi xe: không tính tiền Grab.");
  }

  const subtotal = items.reduce((s, i) => s + i.amount, 0);
  add("misc", "Phát sinh", subtotal * (kind === "NHAU" ? 0.12 : 0.08));

  // learn from closed plans of the same kind
  const cal = calibration(past, kind);
  if (cal.n) {
    for (const it of items) it.amount = roundVnd(it.amount * cal.factor);
    assumptions.push(`Đã chỉnh theo ${cal.n} lần trước (thực tế thường ${cal.factor >= 1 ? "cao" : "thấp"} hơn dự toán ~${Math.round(Math.abs(cal.factor - 1) * 100)}%).`);
  }

  const totalLikely = items.reduce((s, i) => s + i.amount, 0);
  // the owner's share: shared costs split by headcount unless they pay; own rides are theirs
  const shared = items.filter((i) => i.key !== "rides").reduce((s, i) => s + i.amount, 0);
  const own = items.find((i) => i.key === "rides")?.amount ?? 0;
  const ownerLikely = ownerPays || headcount === 1 ? totalLikely : roundVnd(shared / headcount + own);
  if (!ownerPays && headcount > 1) assumptions.push(`Chia đều ${headcount} người (bạn tự trả Grab của mình).`);

  // range: the owner's own spread when there is enough history, else a fixed band
  let lowF = 0.75;
  let highF = 1.4;
  if (samples.length >= 4) {
    const m = median(samples);
    lowF = Math.min(0.9, Math.max(0.55, quantile(samples, 0.25) / m));
    highF = Math.max(1.15, Math.min(1.9, quantile(samples, 0.8) / m));
  }
  // likely stays the exact sum of the (already rounded) lines so the card adds up; only the ends are rounded
  const band = (x: number) => ({ low: roundVnd(x * lowF), likely: x, high: roundVnd(x * highF) });
  const est: Estimate = {
    kind,
    headcount,
    owner_pays: ownerPays,
    transport,
    total: band(totalLikely),
    owner: band(ownerLikely),
    breakdown: items,
    rides,
    per_head: roundVnd(perHead),
    assumptions,
    basis: {
      samples: samples.length,
      ride_samples: rideXs.length,
      past_events: cal.n,
      calibration: Math.round(cal.factor * 100) / 100,
      source: samples.length >= 3 ? "history" : samples.length ? "mixed" : "prior",
    },
    summary: "",
  };
  est.summary = estimateSummary(est);
  return est;
}

/** "Dự kiến ~850.000đ (bạn trả ~350.000đ sau khi chia): đồ ăn 330k, bia nước 270k, Grab đi-về ~2×90k, phát sinh 70k". */
export function estimateSummary(e: Pick<Estimate, "total" | "owner" | "breakdown" | "owner_pays" | "headcount">): string {
  const parts = e.breakdown.map((i) => `${i.label.charAt(0).toLowerCase()}${i.label.slice(1)} ${shortVnd(i.amount)}`.replace(/^grab/, "Grab"));
  const share = !e.owner_pays && e.headcount > 1 && e.owner.likely !== e.total.likely ? ` (bạn trả ~${vnd(e.owner.likely)} sau khi chia)` : "";
  return `Dự kiến ~${vnd(e.total.likely)}${share}: ${parts.join(", ")}`;
}

// ---------------------------------------------------------------- plan vs actual
export interface PlanWindow {
  kind: EventKind;
  starts_at: string;
  ends_at: string;
}

export interface Actual {
  total: number; // money that left (everything in the window)
  owner: number; // the owner's own share after splits
  buckets: { food: number; rides: number; other: number };
  tx_ids: string[];
  count: number;
}

/** Collection window: rides from 2 h before to 4 h after (getting there, going home late); the rest ±1 h / +2 h. */
export function actualWindow(p: PlanWindow): { from: string; to: string } {
  const pad = p.kind === "DU_LICH" ? 6 : 2;
  return {
    from: new Date(Date.parse(p.starts_at) - pad * 3_600_000).toISOString(),
    to: new Date(Date.parse(p.ends_at) + (p.kind === "DU_LICH" ? 6 : 4) * 3_600_000).toISOString(),
  };
}

export function collectActual(p: PlanWindow, rows: SpendRow[]): Actual {
  const s = Date.parse(p.starts_at);
  const e = Date.parse(p.ends_at);
  const w = actualWindow(p);
  const out: Actual = { total: 0, owner: 0, buckets: { food: 0, rides: 0, other: 0 }, tx_ids: [], count: 0 };
  for (const r of rows) {
    const t = Date.parse(r.at);
    if (!(t >= Date.parse(w.from) && t < Date.parse(w.to))) continue;
    const ride = isRide(r);
    const core = t >= s - 3_600_000 && t < e + 2 * 3_600_000;
    if (!ride && !core) continue; // a purchase hours later is not part of the outing; a ride home is
    const bucket: keyof Actual["buckets"] = ride ? "rides" : isFood(r) ? "food" : "other";
    out.total += r.amount;
    out.owner += r.owner_amount;
    out.buckets[bucket] += r.owner_amount;
    out.tx_ids.push(r.id);
    out.count++;
  }
  return out;
}

export interface Comparison {
  actual_owner: number;
  estimated_owner: number;
  diff: number;
  pct: number; // +20 = 20 % over
  driver: "food" | "rides" | "other" | null;
  summary: string;
}

const BUCKET_LABEL = { food: "ăn uống", rides: "tiền Grab", other: "khoản phát sinh" } as const;

/** "Thực tế 1.020.000đ, vượt 20% so với dự toán, chủ yếu do ăn uống". */
export function compareActual(est: Pick<Estimate, "owner" | "breakdown" | "owner_pays" | "headcount">, a: Actual): Comparison {
  const expected = est.owner.likely;
  const diff = a.owner - expected;
  const pct = expected > 0 ? Math.round((diff / expected) * 100) : 0;
  // expected owner amount per bucket (shared items split like the estimate did)
  const share = est.owner_pays || est.headcount <= 1 ? 1 : 1 / est.headcount;
  const exp = { food: 0, rides: 0, other: 0 };
  for (const i of est.breakdown) {
    if (i.key === "rides") exp.rides += i.amount;
    else if (i.key === "misc" || i.key === "venue" || i.key === "photo") exp.other += i.amount * share;
    else exp.food += i.amount * share;
  }
  let driver: Comparison["driver"] = null;
  let worst = 0;
  for (const k of ["food", "rides", "other"] as const) {
    const d = diff >= 0 ? a.buckets[k] - exp[k] : exp[k] - a.buckets[k];
    if (d > worst) {
      worst = d;
      driver = k;
    }
  }
  const head = `Thực tế ${vnd(a.owner)}`;
  let summary: string;
  if (!a.count) summary = "Chưa thấy khoản chi nào trong thời gian sự kiện.";
  else if (Math.abs(pct) <= 10) summary = `${head}, đúng dự toán (${pct >= 0 ? "+" : ""}${pct}%).`;
  else if (pct > 0) summary = `${head}, vượt ${pct}% so với dự toán${driver ? `, chủ yếu do ${BUCKET_LABEL[driver]}` : ""}.`;
  else summary = `${head}, thấp hơn dự toán ${-pct}%${driver ? ` (tiết kiệm nhất ở ${BUCKET_LABEL[driver]})` : ""}.`;
  return { actual_owner: a.owner, estimated_owner: expected, diff, pct, driver, summary };
}
