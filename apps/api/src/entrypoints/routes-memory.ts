import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Config } from "../bootstrap/config";
import type { FinanceGateway } from "../modules/ledger/ports";
import { MODEL, MONTHLY_CAP_MICRO, actualMicro, buildRequestBody, estimateMicro, parseModelJson, type ProviderCall } from "../modules/ai/assistant";
import {
  MEMORY_KINDS,
  REFLECT_MAX_OUTPUT_TOKENS,
  buildReflectionMessages,
  clean,
  describeMemory,
  memorySection,
  normalizeKey,
  parseLearned,
  parseReflectionNotes,
  personsFromPlan,
  reflectionEntries,
  requestTerms,
  type MemoryEntry,
  type MemoryWrite,
} from "../modules/ai/memory";
import { SupabaseMemoryGateway, type MemoryGateway } from "../modules/ai/memory-gateway";
import { DomainError } from "../shared/errors";

// Assistant memory (migration 009): HTTP routes, the read-before-acting / write-after-acting hooks used by the agent
// and /v1/commands, and the nightly reflection run from runScheduled(). Memory failures never break the main path.

export interface MemoryDeps {
  cfg: Config;
  gw: FinanceGateway;
  ai?: ProviderCall;
  /** Injectable for tests; defaults to the Supabase RPC gateway. */
  mg?: MemoryGateway;
}

export const mgOf = (d: MemoryDeps): MemoryGateway => d.mg ?? new SupabaseMemoryGateway(d.cfg);

function ok(c: Context<any>, data: unknown) {
  return c.json({ data, meta: { request_id: (c as any).get("rid") } });
}
const ownerOf = (c: Context<any>): string => (c as any).get("owner");
const withText = (m: MemoryEntry) => ({ ...m, weight: Number(m.weight), text: describeMemory(m) });

function parseOr<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new DomainError("VALIDATION_FAILED");
  return r.data;
}

function logFailure(step: string, e: unknown) {
  console.log(JSON.stringify({ op: "ai_memory", step, outcome: "error", code: e instanceof DomainError ? e.code : (e as Error)?.name ?? "Error" }));
}

/** Runs after the response on Workers (waitUntil); awaited inline when there is no execution context (tests). */
export async function background(c: Context<any>, p: Promise<unknown>): Promise<void> {
  const safe = p.then(() => undefined, (e) => logFailure("background", e));
  let ctx: { waitUntil(p: Promise<unknown>): void } | undefined;
  try {
    ctx = c.executionCtx; // Hono throws when there is no execution context
  } catch {
    ctx = undefined;
  }
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(safe);
  else await safe;
}

const OwnerMemory = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("ALIAS"), key: z.string().trim().min(1).max(40), value: z.string().trim().min(1).max(80) }),
  z.object({ kind: z.literal("NOTE"), key: z.string().trim().max(60).optional(), value: z.string().trim().min(2).max(160) }),
  z.object({ kind: z.literal("PREFERENCE"), key: z.string().trim().max(60).optional(), value: z.string().trim().min(2).max(160) }),
]);

/** Owner-added entry -> memory write, or null when it cannot be stored (no usable key). */
export function ownerMemoryWrite(body: z.infer<typeof OwnerMemory>): MemoryWrite | null {
  const value = clean(body.value, 160);
  if (body.kind === "ALIAS") {
    const key = normalizeKey(body.key);
    if (!key || !normalizeKey(value) || key === normalizeKey(value)) return null;
    return { kind: "ALIAS", key, value: { from: clean(body.key, 40), to: value }, source: "user" };
  }
  const key = normalizeKey(body.key || value).slice(0, 80).trim();
  if (!key) return null;
  return { kind: body.kind, key, value: { text: value }, source: "user" };
}

export function registerMemoryRoutes(app: Hono<any>, getDeps: (env: any) => MemoryDeps, auth: (c: Context<any>, next: () => Promise<void>) => Promise<unknown>) {
  app.get("/v1/ai/memory", auth, async (c) => {
    const q = parseOr(z.object({ kind: z.enum(MEMORY_KINDS).optional(), limit: z.coerce.number().int().min(1).max(500).default(200) }), c.req.query());
    const rows = await mgOf(getDeps(c.env)).list(ownerOf(c), q.kind ?? null, q.limit ?? 200);
    return ok(c, rows.map(withText));
  });

  app.post("/v1/ai/memory", auth, async (c) => {
    const body = parseOr(OwnerMemory, await c.req.json().catch(() => null));
    const w = ownerMemoryWrite(body);
    if (!w) throw new DomainError("VALIDATION_FAILED");
    const m = await mgOf(getDeps(c.env)).upsert(ownerOf(c), w);
    if (!m) throw new DomainError("VALIDATION_FAILED");
    return ok(c, withText(m));
  });

  app.delete("/v1/ai/memory/:id", auth, async (c) => {
    const id = parseOr(z.string().uuid(), c.req.param("id"));
    await mgOf(getDeps(c.env)).remove(ownerOf(c), id);
    return ok(c, { id, deleted: true });
  });
}

// ---------------------------------------------------------------- agent hooks
/** Read before acting: the memory relevant to this request as a compact prompt section ("" on any failure). */
export async function agentMemory(d: MemoryDeps, owner: string, text: string): Promise<string> {
  try {
    const rows = await mgOf(d).relevant(owner, requestTerms(text), 24);
    return memorySection(rows);
  } catch (e) {
    logFailure("relevant", e);
    return "";
  }
}

/** Write after acting: aliases / people / preferences the turn revealed (validated). Returns what was written. */
export function turnLearnings(text: string, raw: unknown, plan: Record<string, unknown>[]): MemoryWrite[] {
  const out = parseLearned(raw, text);
  for (const p of personsFromPlan(plan)) if (!out.some((o) => o.kind === p.kind && o.key === p.key)) out.push(p);
  return out.slice(0, 6);
}

export async function afterAgentTurn(c: Context<any>, d: MemoryDeps, owner: string, text: string, raw: unknown, plan: Record<string, unknown>[]): Promise<void> {
  const items = turnLearnings(text, raw, plan);
  if (!items.length) return;
  await background(c, mgOf(d).upsertMany(owner, items));
}

const OBSERVED = new Set(["TX_ANNOTATE", "TX_CORRECT", "TX_REVERSE"]);

/** After a committed command: lets the database learn from edits/reversals of assistant-created transactions. */
export async function observeCommand(c: Context<any>, d: MemoryDeps, owner: string, command: { command_type: string; payload: unknown }, result: Record<string, unknown>): Promise<void> {
  if (result?.status !== "COMMITTED" || !OBSERVED.has(command.command_type)) return;
  if (command.command_type === "TX_ANNOTATE" && !(command.payload as Record<string, unknown>)?.category_id) return;
  await background(c, mgOf(d).observe(owner, command.command_type, command.payload, result));
}

// ---------------------------------------------------------------- nightly reflection
export const REFLECT_FROM_MIN = 23 * 60;

/** Reflection for one owner: confirm kept AI entries, recompute habits / preferences, optional AI notes, decay. */
export async function runReflection(d: MemoryDeps, owner: string): Promise<{ confirmed: number; habits: number; preferences: number; notes: number; dropped: number }> {
  const mg = mgOf(d);
  const out = { confirmed: 0, habits: 0, preferences: 0, notes: 0, dropped: 0 };
  try {
    out.confirmed = await mg.confirmRecent(owner);
  } catch (e) {
    logFailure("confirm", e);
  }
  try {
    const stats = await mg.reflectStats(owner, 30);
    const { habits, preferences } = reflectionEntries(stats);
    out.habits = await mg.replace(owner, "HABIT", "reflection", habits);
    out.preferences = await mg.replace(owner, "PREFERENCE", "reflection", preferences);
    const facts = [...habits, ...preferences].map((h) => String(h.value.text ?? "")).filter(Boolean);
    if (d.ai && facts.length >= 2) {
      const notes = await aiNotes(d, owner, facts);
      if (notes && notes.length) out.notes = await mg.replace(owner, "NOTE", "reflection", notes);
    }
  } catch (e) {
    logFailure("reflect", e);
  }
  try {
    out.dropped = (await mg.decay(owner)).dropped;
  } catch (e) {
    logFailure("decay", e);
  }
  return out;
}

/** DeepSeek through the monthly budget guard; any failure (budget, provider, invalid output) -> null. */
async function aiNotes(d: MemoryDeps, owner: string, facts: string[]) {
  if (!d.ai) return null;
  try {
    const { messages, bytes } = buildReflectionMessages(facts);
    const { id: reservation } = await d.gw.aiReserve(owner, estimateMicro(bytes, REFLECT_MAX_OUTPUT_TOKENS), MONTHLY_CAP_MICRO, "deepseek", MODEL, "reflect");
    let out;
    try {
      out = await d.ai({ ...buildRequestBody(messages, REFLECT_MAX_OUTPUT_TOKENS), temperature: 0.2 });
    } catch {
      await d.gw.aiMarkUnknown(owner, reservation).catch(() => undefined);
      return null;
    }
    await d.gw.aiSettle(owner, reservation, actualMicro(out.usage)).catch(() => undefined);
    return parseReflectionNotes(parseModelJson(out.content), facts);
  } catch (e) {
    logFailure("notes", e);
    return null;
  }
}
