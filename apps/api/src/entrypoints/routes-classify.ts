import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import { MODEL, MONTHLY_CAP_MICRO, actualMicro, buildRequestBody, estimateMicro, parseModelJson, type ProviderCall } from "../modules/ai/assistant";
import {
  buildClassifyMessages,
  buildHistory,
  classifyDeterministic,
  contentSignature,
  CLASSIFY_MAX_OUTPUT_TOKENS,
  isFallbackCategory,
  merchantFor,
  parseClassifyOutput,
  shouldApply,
  type ClassifyContext,
  type ClassifyExample,
  type ClassifyInput,
  type ClassifyResult,
} from "../modules/ai/classify";
import { SupabaseClassifyGateway, type ClassifyCandidate, type ClassifyGateway } from "../modules/ai/classify-gateway";
import { normalizeKey } from "../modules/ai/memory";
import { SupabaseMemoryGateway, type MemoryGateway } from "../modules/ai/memory-gateway";
import type { FinanceGateway } from "../modules/ledger/ports";
import { formatVnd, sendPush } from "../modules/push/onesignal";
import { SupabaseRemindersGateway, type RemindersGateway } from "../modules/reminders/gateway";
import { DomainError } from "../shared/errors";

// Automatic categorization (migration 015, D-020): runs after captured money arrives (notification TX_CREATE,
// SePay webhook / sync), in the 15-minute cron for leftovers, and learns from every category the owner picks.
// Everything here is best effort: a failure never breaks the command or the webhook that triggered it.

export interface ClassifyDeps {
  cfg: Config;
  gw: FinanceGateway;
  ai?: ProviderCall;
  mg?: MemoryGateway;
  cg?: ClassifyGateway;
  pushFetch?: typeof fetch;
  rg?: RemindersGateway;
}

export const cgOf = (d: ClassifyDeps): ClassifyGateway => d.cg ?? new SupabaseClassifyGateway(d.cfg);
const mgOf = (d: ClassifyDeps): MemoryGateway => d.mg ?? new SupabaseMemoryGateway(d.cfg);

export const SWEEP_BATCH = 8;

function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "ai_classify", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

/** Runs after the response on Workers (waitUntil); awaited inline when there is no execution context (tests). */
async function background(c: Context<any> | null, p: Promise<unknown>): Promise<void> {
  const safe = p.then(() => undefined, (e) => logFailure("background", e));
  let ctx: { waitUntil(p: Promise<unknown>): void } | undefined;
  try {
    ctx = c?.executionCtx; // Hono throws when there is no execution context
  } catch {
    ctx = undefined;
  }
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(safe);
  else await safe;
}

// ---------------------------------------------------------------- context + one classification
export interface LoadedContext extends ClassifyContext {
  examples: ClassifyExample[];
  /** AI answers reused within one context (a sweep often meets the same merchant several times): one call each. */
  memo?: Map<string, ClassifyResult | null>;
}

export async function loadContext(d: ClassifyDeps, owner: string): Promise<LoadedContext> {
  const [categories, rules, examples] = await Promise.all([
    d.gw.readCategories(owner) as Promise<{ id: string; name: string; type: string; archived?: boolean }[]>,
    mgOf(d).list(owner, "CATEGORY_RULE", 500).catch((e) => (logFailure("rules", e), [])),
    cgOf(d).examples(owner, 400).catch((e) => (logFailure("examples", e), [] as ClassifyExample[])),
  ]);
  return {
    categories: categories.filter((c) => !c.archived).map((c) => ({ id: c.id, name: c.name, type: c.type })),
    rules: rules.map((r) => ({ key: r.key, value: r.value, weight: Number(r.weight) })),
    history: buildHistory(examples),
    examples,
  };
}

/** Deterministic layers, then (when allowed and available) DeepSeek. Never throws. */
export async function classifyInput(d: ClassifyDeps, owner: string, input: ClassifyInput, ctx: LoadedContext, allowAi: boolean): Promise<ClassifyResult | null> {
  const det = classifyDeterministic(input, ctx);
  if (det && (det.confidence >= 0.8 || !allowAi || !d.ai)) return det;
  if (!allowAi || !d.ai || input.text.trim().length < 3) return det;
  const sig = contentSignature(input.merchant || input.text);
  const memoKey = sig ? `${input.direction}|${sig}` : null;
  if (memoKey && ctx.memo?.has(memoKey)) {
    const hit = ctx.memo.get(memoKey) ?? null;
    return hit && (!det || hit.confidence > det.confidence) ? hit : det;
  }
  const result = await classifyWithAi(d, owner, input, ctx, det);
  if (memoKey) (ctx.memo ??= new Map()).set(memoKey, result && result.method === "AI" ? result : null);
  return result;
}

async function classifyWithAi(d: ClassifyDeps, owner: string, input: ClassifyInput, ctx: LoadedContext, det: ClassifyResult | null): Promise<ClassifyResult | null> {
  if (!d.ai) return det;
  try {
    const messages = buildClassifyMessages(input, ctx, ctx.examples);
    const bytes = new TextEncoder().encode(messages.map((m) => m.content).join("\n")).length;
    const est = estimateMicro(bytes, CLASSIFY_MAX_OUTPUT_TOKENS);
    let reservation: string | null = null;
    try {
      reservation = (await d.gw.aiReserve(owner, est, MONTHLY_CAP_MICRO, "deepseek", MODEL, "classify")).id;
    } catch (e) {
      // Usage is recorded, never capped (D-015): missing accounting must not stop classification.
      logFailure("reserve", e);
    }
    let out;
    try {
      out = await d.ai(buildRequestBody(messages, CLASSIFY_MAX_OUTPUT_TOKENS));
    } catch (e) {
      if (reservation) await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined);
      logFailure("provider", e);
      return det;
    }
    if (reservation) await d.gw.aiSettle(owner, reservation, actualMicro(out.usage)).catch(() => undefined);
    const ai = parseClassifyOutput(parseModelJson(out.content), input, ctx);
    if (!ai) return det;
    // A weaker deterministic guess that agrees with the model is strong evidence.
    if (det && det.categoryId === ai.categoryId) return { ...det, confidence: Math.max(det.confidence, Math.min(0.9, ai.confidence + 0.1)) };
    if (det && det.confidence >= ai.confidence) return det;
    return { ...ai, merchant: ai.merchant ?? det?.merchant ?? merchantFor(input.text, input.direction) };
  } catch (e) {
    logFailure("ai", e);
    return det;
  }
}

const directionOf = (kind: string): "in" | "out" => (kind === "INCOME" || kind === "UNKNOWN_CREDIT" ? "in" : "out");

/** Classifies one candidate and records the decision (applied in place or suggested). */
export async function classifyCandidate(d: ClassifyDeps, owner: string, t: ClassifyCandidate, ctx: LoadedContext, allowAi = true): Promise<string> {
  const text = [t.note, t.merchant].filter(Boolean).join(" ").trim();
  const input: ClassifyInput = { text, direction: directionOf(t.kind), amount: Number(t.amount), merchant: t.merchant };
  const r = text ? await classifyInput(d, owner, input, ctx, allowAi) : null;
  const res = await cgOf(d).record(owner, {
    tx: t.id,
    categoryId: r?.categoryId ?? null,
    merchant: r?.merchant ?? null,
    confidence: r?.confidence ?? 0,
    method: r?.method ?? "AI",
    reason: r?.reason ?? "Chưa đủ thông tin để phân loại",
    apply: shouldApply(r, ctx.categories),
  });
  return res.status;
}

/** Classifies one freshly created transaction if it is still a candidate (pairing/dedupe may have voided it). */
export async function classifyTx(d: ClassifyDeps, owner: string, txId: string, now = new Date()): Promise<string | null> {
  const [t] = await cgOf(d).candidates(owner, 1, txId);
  if (!t) return null;
  const ctx = await loadContext(d, owner);
  const s = await classifyCandidate(d, owner, t, ctx);
  if (s === "SUGGESTED") await notifyUnclear(d, owner, now, "live");
  return s;
}

/** Cron: a bounded batch of leftovers (arrived while the hook failed, older captures). Never throws. */
export async function runClassifySweep(
  d: ClassifyDeps,
  owner: string,
  limit = SWEEP_BATCH,
  now = new Date(),
  notify = true,
): Promise<{ checked: number; applied: number; suggested: number } | null> {
  try {
    const list = await cgOf(d).candidates(owner, limit);
    const out = { checked: 0, applied: 0, suggested: 0 };
    if (list.length === 0) return out;
    const ctx = await loadContext(d, owner);
    for (const t of list) {
      try {
        const s = await classifyCandidate(d, owner, t, ctx);
        out.checked++;
        if (s === "APPLIED") out.applied++;
        else if (s === "SUGGESTED") out.suggested++;
      } catch (e) {
        logFailure("sweep_item", e);
      }
    }
    return out;
  } catch (e) {
    logFailure("sweep", e);
    return null;
  } finally {
    // Unclear items that were not pushed yet (several in a short time become one notification).
    if (notify) await notifyUnclear(d, owner, now, "cron");
  }
}

// ---------------------------------------------------------------- "chưa rõ loại" push (batched)
const rgOf = (d: ClassifyDeps): RemindersGateway => d.rg ?? new SupabaseRemindersGateway(d.cfg);
const vnParts = (d: Date) => {
  const v = new Date(d.getTime() + 7 * 3_600_000);
  const two = (n: number) => String(n).padStart(2, "0");
  return { hour: v.getUTCHours(), hm: `${two(v.getUTCHours())}:${two(v.getUTCMinutes())}`, day: v.toISOString().slice(0, 10) };
};

export interface PendingItem {
  id: string;
  kind: string;
  amount: string;
  effective_at: string;
  note: string | null;
  merchant: string | null;
  version: number;
  category_id: string | null;
  account_id: string;
  account_name: string | null;
  institution: string | null;
  suggested_category_id: string | null;
  confidence: number | string;
  reason: string | null;
  suggested_merchant: string | null;
  notified_at: string | null;
}

/** Text of the push for still-unclear items (newest first). */
export function unclearMessage(items: Pick<PendingItem, "kind" | "amount" | "effective_at" | "account_name" | "institution">[]): { title: string; body: string } {
  const first = items[0]!;
  const sign = first.kind === "UNKNOWN_CREDIT" || first.kind === "INCOME" ? "+" : "-";
  const where = first.institution || first.account_name || "tài khoản";
  const what = `${sign}${formatVnd(Number(first.amount))}đ ở ${where} lúc ${vnParts(new Date(first.effective_at)).hm}`;
  if (items.length === 1) return { title: `Khoản ${what} chưa rõ loại`, body: "Chạm để chọn loại, chỉ một chạm là xong." };
  return { title: `${items.length} khoản chưa rõ loại`, body: `Gần nhất: ${what}. Chạm để chọn nhanh.` };
}

/**
 * One push (+ inbox item) for unclear items not pushed yet. "live": right after a capture, at most once per 10
 * minutes (later ones in the window wait for the cron and arrive together). "cron": every tick picks up the rest.
 * Quiet at night (23:00-06:59 Vietnam time): items wait for the first morning tick. Never throws.
 */
export async function notifyUnclear(d: ClassifyDeps, owner: string, now: Date, mode: "live" | "cron"): Promise<number> {
  try {
    const p = vnParts(now);
    if (p.hour >= 23 || p.hour < 7) return 0;
    const r = (await cgOf(d).pending(owner, 20, true)) as { items: PendingItem[] };
    if (!r.items.length) return 0;
    const bucket = Math.floor(now.getTime() / (mode === "live" ? 600_000 : 840_000));
    if (!(await rgOf(d).pushClaim(owner, `classify:${mode}:${bucket}`))) return 0;
    const m = unclearMessage(r.items);
    await sendPush(d.cfg, d.pushFetch ?? fetch, {
      ownerId: owner,
      title: m.title,
      body: m.body,
      data: { type: "classify", route: "/classify", count: r.items.length },
      androidGroup: "moma_classify",
    });
    await cgOf(d).markNotified(owner, r.items.map((i) => i.id));
    return r.items.length;
  } catch (e) {
    logFailure("notify", e);
    return 0;
  }
}

// ---------------------------------------------------------------- hooks
const UNKNOWN = new Set(["UNKNOWN_DEBIT", "UNKNOWN_CREDIT"]);

/** After a committed command: classify captured money (TX_CREATE UNKNOWN_*) and learn from the owner's choices. */
export async function classifyAfterCommand(c: Context<any> | null, d: ClassifyDeps, owner: string, command: { command_type: string; payload: unknown }, result: Record<string, unknown>): Promise<void> {
  if (result?.status !== "COMMITTED") return;
  const p = (command.payload ?? {}) as Record<string, unknown>;
  if (command.command_type === "TX_CREATE" && UNKNOWN.has(String(p.kind)) && typeof result.tx_id === "string") {
    await background(c, classifyTx(d, owner, result.tx_id));
    return;
  }
  const learnTx =
    command.command_type === "TX_ANNOTATE" && p.category_id ? String(p.tx_id) : command.command_type === "TX_CORRECT" && typeof result.tx_id === "string" ? result.tx_id : null;
  if (learnTx) await background(c, learnCategory(d, owner, learnTx));
}

/** After SePay ingested a bank event: record how it was categorized, or classify it further when it is parked. */
export async function classifyAfterIngest(c: Context<any> | null, d: ClassifyDeps, owner: string, txId: string, pre: ClassifyResult | null): Promise<void> {
  await background(
    c,
    (async () => {
      if (pre?.categoryId && shouldApply(pre, (await loadContext(d, owner)).categories)) {
        await cgOf(d).record(owner, { tx: txId, categoryId: pre.categoryId, merchant: pre.merchant, confidence: pre.confidence, method: pre.method, reason: pre.reason, apply: true });
        return;
      }
      await classifyTx(d, owner, txId);
    })(),
  );
}

/** Rule key for a transaction: known merchant, else the description signature. */
export function learnKey(note: string | null, merchant: string | null, type: string | null): { key: string; phrase: string } | null {
  const direction = type === "INCOME" ? "in" : "out";
  const text = [merchant, note].filter(Boolean).join(" ");
  const known = merchantFor(text, direction);
  if (known) return { key: normalizeKey(known), phrase: known };
  const sig = contentSignature(merchant) ?? contentSignature(note);
  if (!sig) return null;
  return { key: sig, phrase: (merchant?.trim() || sig).slice(0, 60) };
}

/** The owner picked / changed a category: "this merchant -> this category" becomes a learned rule. */
export async function learnCategory(d: ClassifyDeps, owner: string, txId: string): Promise<boolean> {
  const t = await cgOf(d).txFacts(owner, txId);
  // Assistant-created transactions already teach through pf_ai_observe_command (migration 009).
  if (!t.category_id || !t.category || t.source === "AI" || !["INCOME", "EXPENSE"].includes(t.kind)) return false;
  const k = learnKey(t.note, t.merchant, t.category_type);
  if (!k) return false;
  await mgOf(d).upsert(owner, {
    kind: "CATEGORY_RULE",
    key: k.key,
    value: { phrase: k.phrase, category_id: t.category_id, category: t.category, type: t.category_type },
    source: "correction",
  });
  return true;
}

/**
 * Up to 4 categories to offer as one-tap chips: the classifier's suggestion, the deterministic guess, then the
 * owner's most used categories of that type. Fallback categories ("Khác") are left to the "Khác…" picker.
 */
export function suggestionsFor(i: Pick<PendingItem, "kind" | "note" | "merchant" | "amount" | "suggested_category_id" | "confidence" | "reason">, ctx: LoadedContext, max = 4) {
  const direction = directionOf(i.kind);
  const want = direction === "in" ? "INCOME" : "EXPENSE";
  const cats = new Map(ctx.categories.filter((c) => c.type === want && !isFallbackCategory(c.name)).map((c) => [c.id, c]));
  const out: { category_id: string; name: string; confidence: number; reason: string }[] = [];
  const add = (id: string | null | undefined, confidence: number, reason: string) => {
    const c = id ? cats.get(id) : undefined;
    if (!c || out.some((o) => o.category_id === c.id) || out.length >= max) return;
    out.push({ category_id: c.id, name: c.name, confidence: Math.round(confidence * 1000) / 1000, reason });
  };
  add(i.suggested_category_id, Number(i.confidence) || 0, i.reason ?? "Gợi ý của Trợ lý");
  const text = [i.note, i.merchant].filter(Boolean).join(" ");
  if (text) {
    const det = classifyDeterministic({ text, direction, amount: Number(i.amount), merchant: i.merchant }, ctx);
    if (det) add(det.categoryId, det.confidence, det.reason);
  }
  const used = new Map<string, number>();
  for (const e of ctx.examples) used.set(e.category_id, (used.get(e.category_id) ?? 0) + 1);
  for (const [id] of [...used.entries()].sort((a, b) => b[1] - a[1])) add(id, 0, "Bạn hay dùng");
  for (const id of cats.keys()) add(id, 0, "");
  return out;
}

// ---------------------------------------------------------------- routes
function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}

const SuggestBody = z.object({
  text: z.string().trim().min(1).max(300),
  direction: z.enum(["in", "out"]).default("out"),
  amount: z.number().int().positive().max(1e13).optional(),
  ai: z.boolean().default(true),
});

export function registerClassifyRoutes(
  app: Hono<any>,
  getDeps: (env: any) => ClassifyDeps,
  auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>,
) {
  // Live suggestion while typing (quick entry): deterministic first, the model only when nothing matched.
  app.post("/v1/ai/classify/suggest", auth, async (c) => {
    const parsed = SuggestBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) throw new DomainError("VALIDATION_FAILED");
    const d = getDeps(c.env);
    const owner = (c as any).get("owner") as string;
    const ctx = await loadContext(d, owner);
    const b = parsed.data;
    const r = await classifyInput(d, owner, { text: b.text, direction: b.direction, ...(b.amount ? { amount: b.amount } : {}) }, ctx, b.ai && b.text.length >= 4);
    if (!r?.categoryId) return ok(c, null);
    return ok(c, { category_id: r.categoryId, merchant: r.merchant, confidence: r.confidence, method: r.method, reason: r.reason });
  });

  // "Chọn loại nhanh": unclear items with up to 4 one-tap suggestions each (no extra model calls here).
  app.get("/v1/ai/classify/pending", auth, async (c) => {
    const d = getDeps(c.env);
    const owner = (c as any).get("owner") as string;
    const [r, ctx] = await Promise.all([cgOf(d).pending(owner, 50) as Promise<{ total: number; items: PendingItem[] }>, loadContext(d, owner)]);
    return ok(c, { total: r.total, items: r.items.map((i) => ({ ...i, suggestions: suggestionsFor(i, ctx) })) });
  });

  // "Phân loại ngay": the app's pull-to-refresh on the review list runs one sweep immediately.
  app.post("/v1/ai/classify/run", auth, async (c) => {
    const d = getDeps(c.env);
    const r = await runClassifySweep(d, (c as any).get("owner"), 10);
    return ok(c, r ?? { checked: 0, applied: 0, suggested: 0 });
  });
}
