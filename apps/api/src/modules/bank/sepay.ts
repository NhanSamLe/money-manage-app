import { z } from "zod";

// SePay integration (https://developer.sepay.vn). SePay is the party that verifies a bank account with the bank
// (OTP / SMS link in the SePay dashboard); MoMa only ever links accounts that SePay lists, so an account number
// can never be typed in by hand. Money in/out arrives by webhook and is also polled as a safety net.

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacHex(key: string, message: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(message)));
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

export interface WebhookAuth {
  apiKey?: string | undefined; // SePay "API Key" security: Authorization: Apikey <key>
  hmacSecret?: string | undefined; // SePay "HMAC-SHA256" security: X-SePay-Signature / X-SePay-Timestamp
}

/** True only when the request really comes from the configured SePay webhook (fail closed if nothing is configured). */
export async function verifyWebhook(headers: Headers, rawBody: string, auth: WebhookAuth, nowSec = Math.floor(Date.now() / 1000)): Promise<boolean> {
  if (auth.hmacSecret) {
    const sig = headers.get("x-sepay-signature") ?? "";
    const ts = headers.get("x-sepay-timestamp") ?? "";
    const t = Number(ts);
    if (sig.startsWith("sha256=") && Number.isFinite(t) && Math.abs(nowSec - t) <= 300) {
      const expected = `sha256=${await hmacHex(auth.hmacSecret, `${ts}.${rawBody}`)}`;
      if (safeEqual(sig, expected)) return true;
    }
  }
  if (auth.apiKey) {
    const h = headers.get("authorization") ?? "";
    if (h.startsWith("Apikey ") && safeEqual(h.slice(7), auth.apiKey)) return true;
  }
  return false;
}

const payload = z.object({
  id: z.union([z.number(), z.string()]),
  gateway: z.string().optional(),
  transactionDate: z.string(),
  accountNumber: z.string().min(3).max(40),
  content: z.string().nullish(),
  description: z.string().nullish(),
  transferType: z.enum(["in", "out"]),
  transferAmount: z.number().int().positive().max(999_999_999_999),
  accumulated: z.number().int().nonnegative().optional(),
  referenceCode: z.string().nullish(),
});

export interface BankEvent {
  externalId: string;
  accountNumber: string;
  direction: "in" | "out";
  amount: number;
  atIso: string;
  content: string;
  balance: number | null;
  bankName: string;
}

/** SePay timestamps are Vietnam time without an offset. */
export function vnToIso(s: string): string | null {
  const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})$/.exec(s.trim());
  if (!m) return null;
  const d = new Date(`${m[1]}T${m[2]}+07:00`);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export async function eventKey(provider: string, accountNumber: string, ref: string | null | undefined, direction: string, amount: number, atIso: string, id: string | number): Promise<string> {
  // Webhook ids (integers) and the v2 API ids (UUIDs) differ, so the bank reference decides identity when present.
  if (ref && ref.trim()) return `${provider}:${accountNumber}:${ref.trim()}:${direction}:${amount}`;
  return `${provider}:${accountNumber}:${direction}:${amount}:${atIso}:${id}`;
}

export async function parseWebhook(json: unknown): Promise<BankEvent | null> {
  const p = payload.safeParse(json);
  if (!p.success) return null;
  const at = vnToIso(p.data.transactionDate);
  if (!at) return null;
  const d = p.data;
  return {
    externalId: await eventKey("SEPAY", d.accountNumber, d.referenceCode, d.transferType, d.transferAmount, at, d.id),
    accountNumber: d.accountNumber,
    direction: d.transferType,
    amount: d.transferAmount,
    atIso: at,
    content: (d.content ?? d.description ?? "").trim(),
    balance: d.accumulated && d.accumulated > 0 ? d.accumulated : null,
    bankName: d.gateway ?? "",
  };
}

export interface SepayAccount {
  id: string;
  holder: string;
  number: string;
  balance: number;
  active: boolean;
  bank: string;
  bankFull: string;
  label: string;
  connection: string;
  bin: string;
}

const accountRow = z.object({
  id: z.string(),
  account_holder_name: z.string().nullish(),
  account_number: z.string(),
  accumulated: z.union([z.number(), z.string()]).nullish(),
  active: z.union([z.number(), z.boolean(), z.string()]).nullish(),
  bank_short_name: z.string().nullish(),
  bank_full_name: z.string().nullish(),
  label: z.string().nullish(),
  connection_type: z.string().nullish(),
  bank_bin: z.string().nullish(),
});

const txRow = z.object({
  id: z.string(),
  transaction_date: z.string(),
  account_number: z.string(),
  transfer_type: z.enum(["in", "out"]),
  amount_in: z.union([z.number(), z.string()]),
  amount_out: z.union([z.number(), z.string()]),
  accumulated: z.union([z.number(), z.string()]).nullish(),
  transaction_content: z.string().nullish(),
  reference_number: z.string().nullish(),
  bank_brand_name: z.string().nullish(),
});

const ACCOUNTS_TTL_MS = 60_000;
const accountsCache = new Map<string, { at: number; value: SepayAccount[] }>();
const accountsInflight = new Map<string, Promise<SepayAccount[]>>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Test hook: forget cached SePay account lists. */
export function resetSepayCache(): void {
  accountsCache.clear();
  accountsInflight.clear();
}

export class SepayClient {
  constructor(
    private readonly token: string,
    // Wrapped so the platform fetch is never called as a method of this object (Workers: "Illegal invocation").
    private readonly fetchImpl: typeof fetch = (input, init) => fetch(input, init),
    private readonly base = "https://userapi.sepay.vn/v2",
  ) {}

  /** GET with SePay's 3-requests-per-second limit handled: on 429 wait for the reset window and retry (max 2). */
  private async get(path: string): Promise<unknown> {
    for (let attempt = 0; ; attempt++) {
      const res = await this.fetchImpl(`${this.base}${path}`, {
        headers: { authorization: `Bearer ${this.token}`, accept: "application/json", "user-agent": "MoMa/1.0 (+https://moma-api.superaicore.indevs.in)" },
        signal: AbortSignal.timeout(12_000),
      });
      if (res.status === 429) {
        if (attempt >= 2) throw new Error("SEPAY_RATE_LIMITED");
        const reset = Number(res.headers.get("x-ratelimit-reset") ?? res.headers.get("retry-after") ?? "1");
        await sleep(Math.min(3000, Math.max(400, (Number.isFinite(reset) ? reset : 1) * 1000 + 150 + attempt * 300)));
        continue;
      }
      if (!res.ok) throw new Error(`SEPAY_HTTP_${res.status}:${(await res.text().catch(() => "")).slice(0, 120)}`);
      return res.json();
    }
  }

  /**
   * Linked bank accounts. Cached per token for 60 s and shared by concurrent callers, so the many screens that
   * show bank info (accounts, receive QR, widgets, notification capture) cost SePay one call, not one each.
   */
  async accounts(): Promise<SepayAccount[]> {
    const hit = accountsCache.get(this.token);
    const now = Date.now();
    if (hit && now - hit.at < ACCOUNTS_TTL_MS) return hit.value;
    const pending = accountsInflight.get(this.token);
    if (pending) return pending;
    const p = this.fetchAccounts()
      .then((value) => {
        accountsCache.set(this.token, { at: Date.now(), value });
        return value;
      })
      .finally(() => accountsInflight.delete(this.token));
    accountsInflight.set(this.token, p);
    return p;
  }

  private async fetchAccounts(): Promise<SepayAccount[]> {
    const j = (await this.get("/bank-accounts?per_page=100")) as { data?: unknown[] };
    const out: SepayAccount[] = [];
    for (const r of j.data ?? []) {
      const p = accountRow.safeParse(r);
      if (!p.success) continue;
      const a = p.data;
      out.push({
        id: a.id,
        holder: a.account_holder_name ?? "",
        number: a.account_number,
        balance: Math.max(0, Math.trunc(Number(a.accumulated ?? 0)) || 0),
        active: a.active === 1 || a.active === true || a.active === "1" || a.active === "true",
        bank: a.bank_short_name ?? "",
        bankFull: a.bank_full_name ?? "",
        label: a.label ?? "",
        connection: a.connection_type ?? "",
        bin: a.bank_bin ?? "",
      });
    }
    return out;
  }

  /** New transactions of one bank account after [sinceId] (ascending). */
  async transactions(bankAccountId: string, sinceId: string | null): Promise<BankEvent[]> {
    const q = new URLSearchParams({ bank_account_id: bankAccountId, per_page: "100", transaction_date_sort: "asc" });
    if (sinceId) q.set("since_id", sinceId);
    const j = (await this.get(`/transactions?${q.toString()}`)) as { data?: unknown[] };
    const out: (BankEvent & { rawId: string })[] = [];
    for (const r of j.data ?? []) {
      const p = txRow.safeParse(r);
      if (!p.success) continue;
      const t = p.data;
      const amount = Math.trunc(Number(t.transfer_type === "in" ? t.amount_in : t.amount_out));
      const at = vnToIso(t.transaction_date);
      if (!at || !(amount > 0)) continue;
      out.push({
        rawId: t.id,
        externalId: await eventKey("SEPAY", t.account_number, t.reference_number, t.transfer_type, amount, at, t.id),
        accountNumber: t.account_number,
        direction: t.transfer_type,
        amount,
        atIso: at,
        content: (t.transaction_content ?? "").trim(),
        balance: Number(t.accumulated) > 0 ? Math.trunc(Number(t.accumulated)) : null,
        bankName: t.bank_brand_name ?? "",
      });
    }
    return out;
  }
}

// ---- classification fallback: simple, transparent keyword rules (the AI classifier runs first when enabled)
const RULES: [RegExp, string][] = [
  [/grab|be\s?group|gojek|xang|xăng|petrolimex|taxi|bus|ve\s?xe|vé xe/i, "Di chuyển"],
  [/an\s?uong|ăn|com\b|cơm|pho\b|phở|cafe|ca phe|cà phê|highlands|starbucks|trà sữa|tra sua|nha hang|nhà hàng|shopeefood|grabfood|baemin/i, "Ăn uống"],
  [/shopee|lazada|tiki|tiktok shop|mua sam|mua sắm/i, "Mua sắm"],
  [/dien\b|điện|nuoc\b|nước|internet|wifi|fpt|viettel|vnpt|hoa don|hóa đơn|evn/i, "Hóa đơn"],
  [/luong|lương|salary|payroll/i, "Lương"],
  [/benh vien|bệnh viện|thuoc|thuốc|pharmacity|long chau|phòng khám|phong kham/i, "Sức khỏe"],
  [/hoc phi|học phí|khoa hoc|khóa học|udemy|sach|sách/i, "Giáo dục"],
  [/netflix|spotify|youtube|cgv|game|steam|giai tri|giải trí/i, "Giải trí"],
  [/thue nha|thuê nhà|tien nha|tiền nhà|chung cu|chung cư/i, "Nhà ở"],
];

export function ruleCategory(content: string, direction: "in" | "out", categories: { id: string; name: string; type: string }[]): string | undefined {
  const want = direction === "in" ? "INCOME" : "EXPENSE";
  const pool = categories.filter((c) => c.type === want);
  for (const [re, name] of RULES) {
    if (!re.test(content)) continue;
    const hit = pool.find((c) => c.name === name);
    if (hit) return hit.id;
  }
  return (pool.find((c) => c.name === "Khác") ?? pool[0])?.id;
}
