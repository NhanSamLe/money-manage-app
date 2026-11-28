import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { buildApp } from "../../src/entrypoints/http";
import type { AttachmentBucket } from "../../src/entrypoints/routes-attachments";
import { SessionVerifier } from "../../src/modules/auth/verify-session";
import { SupabaseFinanceGateway } from "../../src/modules/ledger/supabase-gateway";
import { startHarness, type Harness } from "./harness";

// Data lifecycle (migration 022) against the real API code, PostgREST and Postgres: core truth survives, detail that
// served its purpose is compacted / rolled up / deleted in bounded batches, monthly stats are distilled from the ledger,
// re-runs are idempotent, and the footprint per transaction is measured before and after the policy.
const DEVICE = "44444444-4444-4444-4444-444444444444";
const SESSION = "33333333-3333-3333-3333-333333333333";
const SECRET = "cron-secret-e2e";
const N = 1000;

let h: Harness;
let app: ReturnType<typeof buildApp>;
let jwt = "";
let owner = "";
let account = "";
let catA = "";
let catB = "";
const expected: Record<string, { sum: number; count: number }> = {};
const store = new Map<string, { size: number; uploaded: Date }>();
const deleted: string[] = [];
const bucket: AttachmentBucket = {
  put: async (k, v) => void store.set(k, { size: v.byteLength, uploaded: new Date() }),
  get: async () => null,
  delete: async (k) => {
    deleted.push(k);
    store.delete(k);
  },
  list: async ({ prefix, cursor, limit }) => {
    const keys = [...store.keys()].filter((k) => !prefix || k.startsWith(prefix)).sort();
    const start = cursor ? Number(cursor) : 0;
    const page = keys.slice(start, start + (limit ?? 100));
    const next = start + page.length;
    return { objects: page.map((key) => ({ key, uploaded: store.get(key)!.uploaded })), truncated: next < keys.length, ...(next < keys.length ? { cursor: String(next) } : {}) };
  },
};
const env = { ATTACHMENTS: bucket } as never;

async function json(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await app.request(
    path,
    { method, headers: { "content-type": "application/json", "x-device-id": DEVICE, authorization: `Bearer ${jwt}`, ...headers }, body: body === undefined ? null : JSON.stringify(body) },
    env,
  );
  return { status: res.status, json: (await res.json()) as { data?: any; error?: { code: string } } };
}
async function cmd(type: string, payload: unknown) {
  const id = crypto.randomUUID();
  const r = await json("POST", "/v1/commands", { command_id: id, command_type: type, schema_version: 1, payload }, { "idempotency-key": id });
  expect(r.status).toBe(200);
  return r.json.data;
}
const q = async (sql: string, args: unknown[] = []) => (await h.db.query(sql, args)).rows;
const one = async (sql: string, args: unknown[] = []) => (await q(sql, args))[0];
const TABLES = ["pf_tx", "pf_journal", "pf_entry", "pf_command", "pf_change", "pf_audit", "pf_tx_classification", "pf_inbound_event"];
async function footprint(): Promise<number> {
  const r = await one(`select sum(pg_total_relation_size(('public.' || t)::regclass))::bigint as b from unnest($1::text[]) t`, [TABLES]);
  return Number(r.b);
}
/** First day (YYYY-MM-01) of the Vietnam-time month `back` months before the current one. */
function vnMonth(back: number): string {
  const v = new Date(Date.now() + 7 * 3_600_000);
  const d = new Date(Date.UTC(v.getUTCFullYear(), v.getUTCMonth() - back, 1));
  return d.toISOString().slice(0, 10);
}

beforeAll(async () => {
  h = await startHarness();
  const cfg = { supabaseUrl: h.baseUrl, publishableKey: "pk", serviceRoleKey: "sb_secret_e2e", ownerEmail: "owner@example.test", dbTimeoutMs: 20_000, cronSecret: SECRET } as Config;
  app = buildApp(() => ({ cfg, gw: new SupabaseFinanceGateway(cfg), verifier: new SessionVerifier(cfg) }));
  const start = await app.request("/v1/setup/start", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: "owner@example.test" }) }, env);
  expect(start.status).toBe(200);
  owner = (await one("select id from auth.users where email = 'owner@example.test'")).id;
  jwt = await h.mintUserJwt(owner, SESSION);
  expect((await json("POST", "/v1/setup/claim", { display_name: "Chủ sở hữu" })).status).toBe(200);
  expect((await json("POST", "/v1/devices/register", { device_id: DEVICE, label: "E2E" })).status).toBe(200);
  account = (await cmd("ACCOUNT_CREATE", { kind: "CASH", institution: "Tiền mặt", name: "Ví", opening_amount: "900000000", baseline_at: new Date(Date.UTC(2000, 0, 1)).toISOString() })).account_id;
  const cats = (await json("GET", "/v1/categories")).json.data as any[];
  const exp = cats.filter((c) => c.type === "EXPENSE");
  catA = exp[0].id;
  catB = exp[1].id;
}, 240_000);

afterAll(async () => {
  await h?.stop();
}, 60_000);

describe("data lifecycle", () => {
  let before = 0;
  let after = 0;

  it(`measures the footprint of ${N} realistic transactions`, async () => {
    const base = await footprint();
    // 1000 TX_CREATE through the real command path (journal, entries, idempotency row, change feed), spread over the
    // two previous closed months, two categories, realistic amounts and notes.
    const m2 = vnMonth(2);
    const m1 = vnMonth(1);
    await h.db.query(
      `do $$
       declare i integer; amt bigint; cat uuid; mon date; cid uuid; at timestamptz;
       begin
         for i in 1..${N} loop
           amt := 15000 + (i % 37) * 5000;
           cat := case when i % 3 = 0 then '${catB}'::uuid else '${catA}'::uuid end;
           mon := case when i % 2 = 0 then '${m2}'::date else '${m1}'::date end;
           at := ((mon + ((i % 27) || ' days')::interval + interval '12 hours')::timestamp at time zone 'Asia/Ho_Chi_Minh');
           cid := gen_random_uuid();
           perform public.pf_execute_command('${owner}'::uuid, '${SESSION}'::uuid, null, cid, md5(cid::text),
             jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1, 'payload',
               jsonb_build_object('kind', 'EXPENSE', 'account_id', '${account}', 'amount', amt::text, 'effective_at', at,
                                  'category_id', cat, 'note', 'Cà phê sữa đá Highlands quận ' || (i % 12) || ', thanh toán MoMo')));
         end loop;
       end $$;`,
    );
    for (let i = 1; i <= N; i++) {
      const key = `${i % 2 === 0 ? vnMonth(2) : vnMonth(1)}|${i % 3 === 0 ? catB : catA}`;
      expected[key] ??= { sum: 0, count: 0 };
      expected[key].sum += 15000 + (i % 37) * 5000;
      expected[key].count += 1;
    }
    // Two of them get bank events with full payloads (compaction target).
    const txs = await q("select id from public.pf_tx where owner_id = $1 and kind = 'EXPENSE' order by created_at limit 2", [owner]);
    for (const [i, t] of txs.entries()) {
      await h.db.query(
        `insert into public.pf_inbound_event(owner_id, provider, external_id, state, tx_id, payload, received_at)
         values ($1, 'SEPAY', $2, 'APPLIED', $3, $4, now() - interval '120 days')`,
        [owner, `ev-${i}`, t.id, { id: 9000 + i, gateway: "Vietcombank", transactionDate: "2026-07-01 12:00:00", accountNumber: "1026746096", content: "MOMO 1234567890 THANH TOAN ".repeat(20), transferType: "out", transferAmount: 45000, accumulated: 12345678, referenceCode: `FT2618${i}000111`, description: "x".repeat(500), subAccount: null, code: null }],
      );
    }
    await h.db.query("vacuum analyze");
    before = await footprint();
    const perTx = (before - base) / N;
    console.log(JSON.stringify({ op: "footprint", phase: "before", bytes: before - base, per_tx: Math.round(perTx) }));
    expect(perTx).toBeGreaterThan(200);
    expect(perTx).toBeLessThan(10_000);
  }, 300_000);

  it("seeds aged detail rows that the policy must clean", async () => {
    await h.db.query("update public.pf_command set created_at = now() - interval '90 days' where owner_id = $1", [owner]);
    await h.db.query("update public.pf_change set created_at = now() - interval '45 days' where owner_id = $1", [owner]);
    await h.db.query(`insert into public.pf_push_log(owner_id, key, sent_at) values ($1, 'old:1', now() - interval '100 days'), ($1, 'new:1', now())`, [owner]);
    await h.db.query(
      `insert into public.pf_job(owner_id, type, job_key, state, due_at) values
        ($1, 'x', 'job-old-done', 'DONE', now() - interval '30 days'), ($1, 'x', 'job-old-queued', 'QUEUED', now() - interval '30 days'),
        ($1, 'x', 'job-new-done', 'DONE', now())`,
      [owner],
    );
    await h.db.query(
      `insert into public.pf_notification(owner_id, type, title, created_at, read_at) values
        ($1, 'general', 'old read', now() - interval '200 days', now() - interval '199 days'),
        ($1, 'general', 'old unread', now() - interval '200 days', null),
        ($1, 'general', 'new read', now(), now())`,
      [owner],
    );
    await h.db.query(`insert into public.pf_rate_limit(bucket_hash, window_start, count, expires_at) values ('b1', now() - interval '2 hours', 3, now() - interval '1 hour'), ('b2', now(), 1, now() + interval '1 hour')`);
    const old = vnMonth(5);
    const cur = new Date().toISOString().slice(0, 7) + "-01";
    await h.db.query(
      `insert into public.pf_ai_usage(owner_id, period, provider, model, reserved_micro_usd, spent_micro_usd, state, created_at, feature) values
        ($1, $2, 'deepseek', 'deepseek-flash', 900, 700, 'SETTLED', now() - interval '150 days', 'classify'),
        ($1, $2, 'deepseek', 'deepseek-flash', 900, 500, 'SETTLED', now() - interval '150 days', 'classify'),
        ($1, $2, 'deepseek', 'deepseek-flash', 900, 900, 'UNKNOWN_CHARGE', now() - interval '150 days', 'agent'),
        ($1, $3, 'deepseek', 'deepseek-flash', 900, 300, 'SETTLED', now(), 'agent')`,
      [owner, old, cur],
    );
    await h.db.query(`insert into public.pf_audit(owner_id, actor, action, created_at) select $1, 'system', 'TEST_ACTION', now() - interval '400 days' from generate_series(1, 5)`, [owner]);
    await h.db.query(`insert into public.pf_audit(owner_id, actor, action, created_at) values ($1, 'system', 'RECENT', now())`, [owner]);
    const t = await one("select id from public.pf_tx where owner_id = $1 and kind = 'EXPENSE' order by created_at desc limit 1", [owner]);
    await h.db.query(
      `insert into public.pf_tx_classification(tx_id, owner_id, status, category_id, confidence, method, reason, updated_at)
       values ($1, $2, 'APPLIED', $3, 0.9, 'AI', 'Highlands là quán cà phê', now() - interval '200 days')`,
      [t.id, owner, catA],
    );
    // Feature tagging through the 6-argument reserve (migration 022).
    const r = await one("select public.pf_ai_reserve($1, 1000, 1000000000, 'deepseek', 'deepseek-flash', 'bill') as r", [owner]);
    expect((await one("select feature from public.pf_ai_usage where id = $1", [r.r.id])).feature).toBe("bill");
  });

  it("cleans in bounded batches until done, keeping every piece of core truth", async () => {
    const ledgerBefore = await one("select count(*)::int as tx, (select count(*)::int from public.pf_journal) as j, (select count(*)::int from public.pf_entry) as e from public.pf_tx");
    // The user-facing button: one bounded batch.
    const first = await json("POST", "/v1/system/cleanup");
    expect(first.status).toBe(200);
    expect(first.json.data.passes).toBe(1);
    // The GitHub Actions job: all batches.
    const denied = await json("POST", "/v1/internal/maintenance", undefined, { "x-cron-secret": "wrong" });
    expect(denied.status).toBe(401);
    const run = await json("POST", "/v1/internal/maintenance", undefined, { "x-cron-secret": SECRET });
    expect(run.status).toBe(200);
    expect(run.json.data.lifecycle.more).toBe(false);

    // core truth untouched, ledger still balanced
    const ledgerAfter = await one("select count(*)::int as tx, (select count(*)::int from public.pf_journal) as j, (select count(*)::int from public.pf_entry) as e from public.pf_tx");
    expect(ledgerAfter).toEqual(ledgerBefore);
    expect((await one("select coalesce(sum(signed_amount::numeric), 0)::text as s from public.pf_entry")).s).toBe("0");
    expect((await one("select count(*)::int as n from public.pf_account where owner_id = $1", [owner])).n).toBe(1);

    // deleted detail
    expect((await one("select count(*)::int as n from public.pf_command where owner_id = $1 and created_at < now() - interval '60 days'", [owner])).n).toBe(0);
    expect((await one("select count(*)::int as n from public.pf_change where owner_id = $1 and created_at < now() - interval '30 days'", [owner])).n).toBe(0);
    expect((await q("select key from public.pf_push_log where owner_id = $1 order by key", [owner])).map((r) => r.key)).not.toContain("old:1");
    expect((await q("select key from public.pf_push_log where owner_id = $1", [owner])).map((r) => r.key)).toContain("new:1");
    expect((await q("select job_key from public.pf_job order by job_key")).map((r) => r.job_key)).toEqual(["job-new-done", "job-old-queued"]);
    expect((await q("select title from public.pf_notification where owner_id = $1 and title in ('old read', 'old unread', 'new read') order by title", [owner])).map((r) => r.title)).toEqual(["new read", "old unread"]);
    expect((await q("select bucket_hash from public.pf_rate_limit where bucket_hash in ('b1', 'b2')")).map((r) => r.bucket_hash)).toEqual(["b2"]);

    // compacted bank payloads keep what pairing reads (reference) and drop the rest
    const ev = await one("select payload from public.pf_inbound_event where external_id = 'ev-0'");
    expect(ev.payload._compacted).toBe(true);
    expect(ev.payload.reference).toBe("FT26180000111");
    expect(ev.payload.last4).toBe("6096");
    expect(ev.payload.content.length).toBeLessThanOrEqual(200);
    expect(ev.payload.description).toBeUndefined();
    expect(ev.payload.accountNumber).toBeUndefined();

    // AI usage rolled up per month / model / feature; this month's detail stays
    const roll = await q("select feature, calls, spent_micro_usd::int as spent, unknown_calls from public.pf_ai_usage_month where owner_id = $1 order by feature", [owner]);
    expect(roll).toEqual([
      { feature: "agent", calls: 1, spent: 900, unknown_calls: 1 },
      { feature: "classify", calls: 2, spent: 1200, unknown_calls: 0 },
    ]);
    expect((await one("select count(*)::int as n from public.pf_ai_usage where owner_id = $1", [owner])).n).toBe(2); // current month: agent + bill

    // audit detail older than a year -> monthly counts
    expect((await one("select count(*)::int as n from public.pf_audit where action = 'TEST_ACTION'")).n).toBe(0);
    expect((await one("select sum(n)::int as n from public.pf_audit_month where action = 'TEST_ACTION'")).n).toBe(5);
    expect((await one("select count(*)::int as n from public.pf_audit where action = 'RECENT'")).n).toBe(1);

    // classification keeps the decision, drops the explanation
    const cl = await one("select status, category_id, reason from public.pf_tx_classification where owner_id = $1", [owner]);
    expect(cl).toEqual({ status: "APPLIED", category_id: catA, reason: null });
  }, 300_000);

  it("distils closed months into pf_month_stat (owner share, reversals netted)", async () => {
    const rows = await q("select month::text as month, category_id, tx_count, total::bigint as total, avg::bigint as avg from public.pf_month_stat where owner_id = $1 and type = 'EXPENSE' and category_id is not null", [owner]);
    for (const [key, e] of Object.entries(expected)) {
      const [month, cat] = key.split("|");
      const r = rows.find((x) => x.month === month && x.category_id === cat);
      expect(r, key).toBeDefined();
      expect(Number(r.total)).toBe(e.sum);
      expect(r.tx_count).toBe(e.count);
      expect(Number(r.avg)).toBe(Math.round(e.sum / e.count));
    }
    const totals = await q("select month::text as month, total::bigint as total from public.pf_month_stat where owner_id = $1 and type = 'EXPENSE' and category_id is null order by month", [owner]);
    expect(totals.map((t) => Number(t.total))).toEqual(
      [vnMonth(2), vnMonth(1)].map((m) => Object.entries(expected).filter(([k]) => k.startsWith(m)).reduce((s, [, v]) => s + v.sum, 0)),
    );
    // A reversed transaction in a closed month nets to zero.
    const t = await one("select id, version, amount::bigint as amount, effective_at from public.pf_tx where owner_id = $1 and kind = 'EXPENSE' and status = 'POSTED' order by effective_at limit 1", [owner]);
    await cmd("TX_REVERSE", { tx_id: t.id, reason: "test", expected_version: t.version });
    const month = (await one("select date_trunc('month', $1::timestamptz at time zone 'Asia/Ho_Chi_Minh')::date::text as m", [t.effective_at])).m;
    const beforeTotal = Number((await one("select total from public.pf_month_stat where owner_id = $1 and month = $2 and type = 'EXPENSE' and category_id is null", [owner, month])).total);
    await h.db.query("select pf_private.lc_month_stat($1, $2)", [owner, month]);
    const afterTotal = Number((await one("select total from public.pf_month_stat where owner_id = $1 and month = $2 and type = 'EXPENSE' and category_id is null", [owner, month])).total);
    expect(beforeTotal - afterTotal).toBe(Number(t.amount));
  });

  it("re-runs are idempotent", async () => {
    const snap = async () => q("select month::text, type, category_id, tx_count, total::text from public.pf_month_stat where owner_id = $1 order by 1, 2, 3", [owner]);
    const s1 = await snap();
    const again = await json("POST", "/v1/internal/maintenance", undefined, { "x-cron-secret": SECRET });
    expect(again.status).toBe(200);
    expect(again.json.data.lifecycle.totals).toEqual({});
    expect(await snap()).toEqual(s1);
    expect((await one("select count(*)::int as n from public.pf_ai_usage_month where owner_id = $1", [owner])).n).toBe(2);
  });

  it("measures the footprint after the policy", async () => {
    // Supabase's autovacuum makes dead rows reusable; VACUUM FULL here measures the live data the policy keeps.
    for (const t of TABLES) await h.db.query(`vacuum full public.${t}`);
    after = await footprint();
    console.log(JSON.stringify({ op: "footprint", phase: "after", before, after, saved_pct: Math.round((100 * (before - after)) / before) }));
    expect(after).toBeLessThan(before);
  });

  it("capacity: weekly snapshot, report with projection and AI cost by feature, 60/80% warnings re-arm", async () => {
    const rec = await one("select public.pf_capacity_record($1, $2) as r", [owner, 500 * 1024 * 1024]);
    expect(rec.r.db_bytes).toBeGreaterThan(0);
    expect(rec.r.warn).toBe(0);
    // A tiny limit crosses 80% at once: warned once, not twice.
    expect((await one("select public.pf_capacity_record($1, 1000) as r", [owner])).r.warn).toBe(80);
    expect((await one("select public.pf_capacity_record($1, 1000) as r", [owner])).r.warn).toBe(0);
    // back under 55% re-arms
    await one("select public.pf_capacity_record($1, $2) as r", [owner, 10_000_000_000]);
    expect((await one("select warned_level from public.pf_lifecycle_state where owner_id = $1", [owner])).warned_level).toBe(0);

    // older weekly snapshots for a projection
    await h.db.query(
      `insert into public.pf_capacity_snapshot(owner_id, week, db_bytes) values
        ($1, current_date - 28, 40000000), ($1, current_date - 21, 41000000), ($1, current_date - 14, 42000000), ($1, current_date - 7, 43000000)
       on conflict do nothing`,
      [owner],
    );
    const r = await json("GET", "/v1/system/capacity");
    expect(r.status).toBe(200);
    const d = r.json.data;
    expect(d.db_limit_bytes).toBe(500 * 1024 * 1024);
    expect(d.tx_count).toBeGreaterThanOrEqual(N);
    expect(d.top.length).toBeGreaterThan(0);
    expect(d.ai.by_feature.map((f: any) => f.feature).sort()).toEqual(["agent", "bill"]);
    expect(d.ai.months.length).toBeGreaterThanOrEqual(2); // rollup month + this month
    expect(typeof d.projection.label).toBe("string");
    expect(d.last_run_at).toBeTruthy();
  });

  it("R2 orphan sweep deletes only unreferenced, settled objects under the owner prefix", async () => {
    const t = await one("select id from public.pf_tx where owner_id = $1 and status = 'POSTED' limit 1", [owner]);
    const kept = `${owner}/${t.id}/kept.jpg`;
    await h.db.query("insert into public.pf_tx_attachment(owner_id, tx_id, object_key, content_type, size_bytes) values ($1, $2, $3, 'image/jpeg', 1000)", [owner, t.id, kept]);
    store.set(kept, { size: 1000, uploaded: new Date(Date.now() - 3 * 86_400_000) });
    store.set(`${owner}/${t.id}/orphan-old.jpg`, { size: 1000, uploaded: new Date(Date.now() - 3 * 86_400_000) });
    store.set(`${owner}/${t.id}/orphan-new.jpg`, { size: 1000, uploaded: new Date() });
    store.set(`someone-else/x/y.jpg`, { size: 1000, uploaded: new Date(Date.now() - 3 * 86_400_000) });
    const r = await json("POST", "/v1/internal/maintenance", undefined, { "x-cron-secret": SECRET });
    expect(r.status).toBe(200);
    expect(deleted).toEqual([`${owner}/${t.id}/orphan-old.jpg`]);
    expect(r.json.data.r2.done).toBe(true);
    expect((await one("select r2_swept_at from public.pf_lifecycle_state where owner_id = $1", [owner])).r2_swept_at).toBeTruthy();
  });
});
