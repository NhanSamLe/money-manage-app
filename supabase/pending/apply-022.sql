-- MoMa migration 022: data lifecycle (retention + distillation) and capacity monitoring. Free tiers only (D-028):
-- the whole app must live inside Supabase Free (500 MB) for years, so detail that has served its purpose is compacted
-- or deleted, while everything that makes the app smarter is kept or distilled first.
--
-- KEEP forever: the ledger (pf_tx / pf_journal / pf_entry, append-only), accounts, categories, contacts, debts and
--   payments, goals, budgets, recurring rules, splits, learned AI memory, owner classification decisions, rejected
--   pair decisions (so nothing is suggested twice), attachment metadata, monthly stats and capacity snapshots.
-- COMPACT: bank event payloads (essential fields only), classifier explanations, AI usage (monthly rollup),
--   audit detail (monthly counts).
-- DELETE: idempotency results past the client retry window, the sync change feed, push dedupe keys, finished jobs,
--   read notifications, expired rate-limit buckets, day-level insights, past meal skips, old capacity snapshots.
--
-- The policy is a table (pf_private.retention_policy): a table created later (4Life lf_*, knowledge kn_*) is covered
-- by inserting a row; a policy whose table or columns do not exist yet is skipped, never an error. Every run is a
-- bounded batch per table (LIMIT), so it fits the Worker cron and can be repeated by the GitHub Actions maintenance job
-- until "more" is false. Idempotent.
-- Server role only.
begin;

-- ---------------------------------------------------------------- policy
create table pf_private.retention_policy (
  tbl text primary key check (tbl ~ '^[a-z_][a-z0-9_]*$'),
  action text not null check (action in ('DELETE', 'COMPACT', 'ROLLUP', 'KEEP')),
  ts_col text check (ts_col is null or ts_col ~ '^[a-z_][a-z0-9_]*$'),
  keep_for interval,
  extra_where text,        -- trusted SQL predicate written in migrations only (never from requests)
  batch integer not null default 500 check (batch between 1 and 5000),
  why text not null
);

insert into pf_private.retention_policy(tbl, action, ts_col, keep_for, extra_where, batch, why) values
  -- idempotency: the app outbox holds offline commands for at most 30 days; 60 days leaves a full margin
  ('pf_command', 'DELETE', 'created_at', '60 days', null, 1000, 'Kết quả lệnh chỉ cần trong cửa sổ gửi lại (outbox ≤ 30 ngày)'),
  ('pf_change', 'DELETE', 'created_at', '30 days', null, 2000, 'Nhật ký đồng bộ: app làm mới toàn bộ khi thiếu, không ai đọc lịch sử'),
  ('pf_push_log', 'DELETE', 'sent_at', '90 days', null, 1000, 'Khóa chống gửi trùng theo ngày/tuần/tháng; cửa sổ dài nhất < 90 ngày'),
  ('pf_job', 'DELETE', 'due_at', '14 days', $$state in ('DONE', 'DEAD')$$, 1000, 'Việc nền đã xong'),
  ('pf_notification', 'DELETE', 'created_at', '120 days', 'read_at is not null', 1000, 'Thông báo đã đọc; vẫn giữ giới hạn 500 mục'),
  ('pf_rate_limit', 'DELETE', 'expires_at', '0 days', null, 2000, 'Bộ đếm giới hạn tốc độ đã hết hạn'),
  ('pf_reminder_skip', 'DELETE', 'created_at', '60 days', null, 1000, 'Lựa chọn "hôm nay không" chỉ có ý nghĩa trong ngày'),
  ('pf_insight', 'DELETE', 'created_at', '180 days', $$period = 'DAY'$$, 500, 'Nhận xét theo ngày; tuần/tháng giữ lại, số liệu đã chưng cất vào pf_month_stat'),
  ('pf_capacity_snapshot', 'DELETE', 'created_at', '730 days', null, 500, 'Ảnh chụp dung lượng giữ 2 năm'),
  ('pf_goal_proposal', 'DELETE', 'created_at', '180 days', $$state = 'DISMISSED'$$, 500, 'Đề xuất trích tiền đã bỏ qua'),
  ('pf_inbound_event', 'COMPACT', 'received_at', '90 days', null, 500, 'Sự kiện ngân hàng: chỉ giữ trường cốt lõi (mã tham chiếu, số tiền, thời điểm, nội dung ≤ 200 ký tự)'),
  ('pf_tx_classification', 'COMPACT', 'updated_at', '180 days', $$status in ('APPLIED', 'SUGGESTED')$$, 1000, 'Giữ quyết định phân loại, bỏ lời giải thích'),
  ('pf_ai_usage', 'ROLLUP', 'created_at', '90 days', null, 1000, 'Chi phí AI gộp theo tháng/model rồi xóa chi tiết'),
  ('pf_audit', 'ROLLUP', 'created_at', '365 days', null, 1000, 'Nhật ký kiểm toán gộp số lượng theo tháng rồi xóa chi tiết'),
  -- future tables: active as soon as they exist
  ('kn_item', 'DELETE', 'valid_until', '0 days', null, 1000, 'Tri thức đã hết hạn (4Life/MoMa, chưa có bảng)'),
  -- explicit KEEP rows document the core truth (the runner ignores them)
  ('pf_tx', 'KEEP', null, null, null, 1, 'Sổ cái: giao dịch (bất biến)'),
  ('pf_journal', 'KEEP', null, null, null, 1, 'Sổ cái: bút toán (bất biến)'),
  ('pf_entry', 'KEEP', null, null, null, 1, 'Sổ cái: dòng bút toán (bất biến)'),
  ('pf_ai_memory', 'KEEP', null, null, null, 1, 'Những gì Trợ lý đã học'),
  ('pf_transfer_pair', 'KEEP', null, null, null, 1, 'Quyết định ghép/không ghép, chống đề xuất lại'),
  ('pf_same_payment', 'KEEP', null, null, null, 1, 'Quyết định gộp/không trùng, chống đề xuất lại'),
  ('pf_split_application', 'KEEP', null, null, null, 1, 'Chia hóa đơn và nợ phát sinh'),
  ('pf_tx_attachment', 'KEEP', null, null, null, 1, 'Ảnh chứng từ (ảnh nằm trên R2)');

-- ---------------------------------------------------------------- distilled / summary tables
-- Monthly per-category totals from the ledger (owner share for split bills, reversals netted). category_id null =
-- the month's total for that type.
create table public.pf_month_stat (
  owner_id uuid not null references public.pf_owner(user_id),
  month date not null check (extract(day from month) = 1),
  type text not null check (type in ('EXPENSE', 'INCOME')),
  category_id uuid references public.pf_category(id),
  tx_count integer not null default 0,
  total numeric(20, 0) not null default 0,
  avg numeric(20, 0) not null default 0,
  p50 numeric(20, 0) not null default 0,
  computed_at timestamptz not null default now()
);
create unique index pf_month_stat_uq on public.pf_month_stat(owner_id, month, type, coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table public.pf_ai_usage_month (
  owner_id uuid not null references public.pf_owner(user_id),
  period date not null check (extract(day from period) = 1),
  model text not null,
  feature text not null default 'other',
  calls integer not null default 0,
  spent_micro_usd bigint not null default 0,
  unknown_calls integer not null default 0,
  primary key (owner_id, period, model, feature)
);

-- Which part of the app made each AI call (agent, classify, bill, insight, reflect, plan, knowledge...).
alter table public.pf_ai_usage add column if not exists feature text check (feature is null or feature ~ '^[a-z_]{1,20}$');

-- Same guard as 006, plus the feature tag. The 5-argument version stays for callers that do not tag.
create function public.pf_ai_reserve(p_owner uuid, p_estimate bigint, p_cap bigint, p_provider text, p_model text, p_feature text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare res jsonb;
begin
  res := public.pf_ai_reserve(p_owner, p_estimate, p_cap, p_provider, p_model);
  if p_feature ~ '^[a-z_]{1,20}$' then
    update public.pf_ai_usage set feature = p_feature where id = (res->>'id')::uuid;
  end if;
  return res;
end $$;

create table public.pf_audit_month (
  owner_id uuid not null references public.pf_owner(user_id),
  month date not null check (extract(day from month) = 1),
  action text not null,
  n integer not null default 0,
  primary key (owner_id, month, action)
);

create table public.pf_capacity_snapshot (
  owner_id uuid not null references public.pf_owner(user_id),
  week date not null,                       -- Monday (ISO week) in Vietnam time
  db_bytes bigint not null,
  r2_bytes bigint not null default 0,
  attachments integer not null default 0,
  tx_count bigint not null default 0,
  top jsonb not null default '[]'::jsonb,   -- [{table, bytes, rows}] largest relations
  ai_micro_usd bigint not null default 0,   -- AI spend of the snapshot's month so far
  created_at timestamptz not null default now(),
  primary key (owner_id, week)
);

create table public.pf_lifecycle_state (
  owner_id uuid primary key references public.pf_owner(user_id),
  last_run_at timestamptz,
  last_result jsonb not null default '{}'::jsonb,
  runs integer not null default 0,
  r2_cursor text,
  r2_swept_at timestamptz,
  month_stat_through date,                  -- last closed month already distilled (empty months included)
  warned_level integer not null default 0   -- 0 / 60 / 80: highest capacity warning already sent
);

alter table public.pf_month_stat enable row level security;
alter table public.pf_ai_usage_month enable row level security;
alter table public.pf_audit_month enable row level security;
alter table public.pf_capacity_snapshot enable row level security;
alter table public.pf_lifecycle_state enable row level security;
revoke all on table public.pf_month_stat, public.pf_ai_usage_month, public.pf_audit_month, public.pf_capacity_snapshot,
  public.pf_lifecycle_state from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
create function pf_private.lc_has_col(p_tbl text, p_col text) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = p_tbl and column_name = p_col)
$$;

-- Bank payload reduced to what anything still reads (transfer_refs uses 'reference') + what a human may want later.
create function pf_private.lc_compact_payload(p jsonb) returns jsonb
language sql immutable set search_path = pg_catalog as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'reference', coalesce(p->>'reference', p->>'referenceCode'),
    'amount', coalesce(p->>'amount', p->>'transferAmount'),
    'type', p->>'transferType',
    'at', coalesce(p->>'transactionDate', p->>'at'),
    'gateway', p->>'gateway',
    'last4', right(nullif(regexp_replace(coalesce(p->>'accountNumber', ''), '[^0-9]', '', 'g'), ''), 4),
    'content', left(coalesce(p->>'content', p->>'description'), 200),
    '_compacted', true))
$$;

-- One bounded step for one policy. Returns the number of rows touched.
create function pf_private.lc_apply(p_owner uuid, p pf_private.retention_policy) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare n integer := 0; owned boolean; cutoff timestamptz; w text;
begin
  if p.action = 'KEEP' or to_regclass('public.' || p.tbl) is null or p.ts_col is null
     or not pf_private.lc_has_col(p.tbl, p.ts_col) then
    return 0;
  end if;
  owned := pf_private.lc_has_col(p.tbl, 'owner_id');
  cutoff := now() - coalesce(p.keep_for, '0 days'::interval);
  w := format('%I < %L', p.ts_col, cutoff)
       || case when owned then format(' and owner_id = %L', p_owner) else '' end
       || case when p.extra_where is not null then ' and (' || p.extra_where || ')' else '' end;

  if p.action = 'DELETE' then
    execute format('delete from public.%I where ctid in (select ctid from public.%I where %s limit %s)', p.tbl, p.tbl, w, p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'COMPACT' and p.tbl = 'pf_inbound_event' then
    update public.pf_inbound_event set payload = pf_private.lc_compact_payload(payload)
     where id in (select id from public.pf_inbound_event
                   where owner_id = p_owner and received_at < cutoff and not (payload ? '_compacted') limit p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'COMPACT' and p.tbl = 'pf_tx_classification' then
    update public.pf_tx_classification set reason = null
     where tx_id in (select tx_id from public.pf_tx_classification
                      where owner_id = p_owner and updated_at < cutoff and status in ('APPLIED', 'SUGGESTED')
                        and reason is not null limit p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'ROLLUP' and p.tbl = 'pf_ai_usage' then
    -- whole months only, so a month is never split between detail and summary
    cutoff := date_trunc('month', cutoff);
    with gone as (
      delete from public.pf_ai_usage where id in (
        select id from public.pf_ai_usage where owner_id = p_owner and period < cutoff::date
         order by period limit p.batch)
      returning period, model, coalesce(feature, 'other') as feature, spent_micro_usd, state)
    insert into public.pf_ai_usage_month(owner_id, period, model, feature, calls, spent_micro_usd, unknown_calls)
      select p_owner, period, model, feature, count(*), sum(spent_micro_usd), count(*) filter (where state = 'UNKNOWN_CHARGE')
        from gone group by period, model, feature
    on conflict (owner_id, period, model, feature) do update set
      calls = pf_ai_usage_month.calls + excluded.calls,
      spent_micro_usd = pf_ai_usage_month.spent_micro_usd + excluded.spent_micro_usd,
      unknown_calls = pf_ai_usage_month.unknown_calls + excluded.unknown_calls;
    get diagnostics n = row_count;

  elsif p.action = 'ROLLUP' and p.tbl = 'pf_audit' then
    with gone as (
      delete from public.pf_audit where id in (
        select id from public.pf_audit where owner_id = p_owner and created_at < cutoff order by id limit p.batch)
      returning created_at, action)
    insert into public.pf_audit_month(owner_id, month, action, n)
      select p_owner, date_trunc('month', created_at at time zone 'Asia/Ho_Chi_Minh')::date, action, count(*)
        from gone group by 2, 3
    on conflict (owner_id, month, action) do update set n = pf_audit_month.n + excluded.n;
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- Distils one closed month (Vietnam time) of the ledger into pf_month_stat. Net per transaction and category, so a
-- reversed transaction counts zero and a split bill counts only the owner's share.
create function pf_private.lc_month_stat(p_owner uuid, p_month date) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare n integer;
begin
  delete from public.pf_month_stat where owner_id = p_owner and month = p_month;
  with lines as (
    select c.id as cat, c.type, j.tx_id, sum(e.signed_amount::numeric) as amt
      from public.pf_journal j
      join public.pf_entry e on e.journal_id = j.id
      join public.pf_category c on c.ledger_account_id = e.ledger_account_id
     where j.owner_id = p_owner and j.posted
       and j.effective_at >= (p_month::timestamp at time zone 'Asia/Ho_Chi_Minh')
       and j.effective_at < ((p_month + interval '1 month')::timestamp at time zone 'Asia/Ho_Chi_Minh')
     group by c.id, c.type, j.tx_id),
  v as (
    select cat, type, case when type = 'EXPENSE' then amt else -amt end as v from lines where amt <> 0),
  agg as (
    select cat, type, count(*) filter (where v > 0) as cnt, sum(v) as total,
           coalesce(percentile_cont(0.5) within group (order by v) filter (where v > 0), 0) as p50
      from v group by grouping sets ((cat, type), (type)))
  insert into public.pf_month_stat(owner_id, month, type, category_id, tx_count, total, avg, p50)
    select p_owner, p_month, type, cat, cnt, round(total), case when cnt > 0 then round(total / cnt) else 0 end, round(p50)
      from agg where type is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- runner
-- One bounded maintenance pass: every policy once (batch-limited) + up to 3 closed months distilled (the previous
-- month is re-distilled during the first 10 days of a month, for late captures). Returns per-table counts and
-- more = true when any batch was full (call again).
create function public.pf_lifecycle_run(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p pf_private.retention_policy; n integer; res jsonb := '{}'::jsonb; more boolean := false;
        cur date; prev date; m date; first_m date; through date; done_months integer := 0; stats integer := 0; vn timestamp;
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-lifecycle'), hashtext(p_owner::text));
  for p in select * from pf_private.retention_policy where action <> 'KEEP' order by tbl loop
    n := pf_private.lc_apply(p_owner, p);
    if n > 0 then res := res || jsonb_build_object(p.tbl, n); end if;
    if n >= p.batch then more := true; end if;
  end loop;

  vn := now() at time zone 'Asia/Ho_Chi_Minh';
  cur := date_trunc('month', vn)::date;
  prev := (cur - interval '1 month')::date;
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  select month_stat_through into through from public.pf_lifecycle_state where owner_id = p_owner for update;
  -- first month with any income/expense category activity (opening balances and transfers do not count)
  select date_trunc('month', min(j.effective_at) at time zone 'Asia/Ho_Chi_Minh')::date into first_m
    from public.pf_journal j
   where j.owner_id = p_owner and j.posted
     and exists (select 1 from public.pf_entry e join public.pf_category c on c.ledger_account_id = e.ledger_account_id
                  where e.journal_id = j.id);
  if first_m is not null then
    m := greatest(first_m, coalesce((through + interval '1 month')::date, first_m));
    while m <= prev and done_months < 3 loop
      stats := stats + pf_private.lc_month_stat(p_owner, m);
      update public.pf_lifecycle_state set month_stat_through = m where owner_id = p_owner;
      through := m;
      done_months := done_months + 1;
      m := (m + interval '1 month')::date;
    end loop;
    if m <= prev then more := true; end if;
    -- late captures of the previous month: refresh it once a day during the first 10 days of a new month
    if done_months = 0 and through >= prev and extract(day from vn) <= 10
       and coalesce((select max(computed_at) from public.pf_month_stat where owner_id = p_owner and month = prev), 'epoch')
           < now() - interval '20 hours' then
      stats := stats + pf_private.lc_month_stat(p_owner, prev);
      done_months := 1;
    end if;
  end if;

  res := jsonb_build_object('tables', res, 'month_stats', stats, 'months', done_months, 'more', more, 'at', now());
  update public.pf_lifecycle_state set last_run_at = now(), last_result = res, runs = runs + 1 where owner_id = p_owner;
  return res;
end $$;

-- ---------------------------------------------------------------- capacity
create function pf_private.lc_r2_bytes(p_owner uuid) returns table (bytes bigint, files integer)
language plpgsql stable set search_path = pg_catalog, public as $$
declare b bigint := 0; f integer := 0; b2 bigint; f2 integer;
begin
  if to_regclass('public.pf_tx_attachment') is not null then
    select coalesce(sum(size_bytes), 0), count(*) into b, f from public.pf_tx_attachment where owner_id = p_owner;
  end if;
  select coalesce(sum(size_bytes), 0), count(*) into b2, f2 from public.pf_attachment where owner_id = p_owner;
  return query select b + b2, f + f2;
end $$;

create function pf_private.lc_top_tables(p_limit integer) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('table', t.relname, 'bytes', t.bytes, 'rows', t.rows) order by t.bytes desc), '[]'::jsonb)
    from (select c.relname, pg_total_relation_size(c.oid) as bytes, greatest(c.reltuples, 0)::bigint as rows
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'
           order by pg_total_relation_size(c.oid) desc limit p_limit) t
$$;

-- Records this week's snapshot (once per ISO week, Vietnam time). Returns the snapshot and the warning level that
-- should be pushed now (0 = none): 60 / 80 the first time the database crosses that share of p_limit_bytes.
create function public.pf_capacity_record(p_owner uuid, p_limit_bytes bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare wk date; db bigint; r record; ai bigint; txn bigint; pct numeric; lvl integer := 0; warned integer;
begin
  perform pf_private.assert_owner(p_owner);
  wk := date_trunc('week', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  db := pg_database_size(current_database());
  select * into r from pf_private.lc_r2_bytes(p_owner);
  select coalesce(sum(spent_micro_usd), 0) into ai from public.pf_ai_usage
   where owner_id = p_owner and period = date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  select count(*) into txn from public.pf_tx where owner_id = p_owner;
  insert into public.pf_capacity_snapshot(owner_id, week, db_bytes, r2_bytes, attachments, tx_count, top, ai_micro_usd)
    values (p_owner, wk, db, r.bytes, r.files, txn, pf_private.lc_top_tables(8), ai)
    on conflict (owner_id, week) do update set db_bytes = excluded.db_bytes, r2_bytes = excluded.r2_bytes,
      attachments = excluded.attachments, tx_count = excluded.tx_count, top = excluded.top,
      ai_micro_usd = excluded.ai_micro_usd, created_at = now();
  pct := case when coalesce(p_limit_bytes, 0) > 0 then 100.0 * db / p_limit_bytes else 0 end;
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  select warned_level into warned from public.pf_lifecycle_state where owner_id = p_owner for update;
  if pct >= 80 and warned < 80 then lvl := 80;
  elsif pct >= 60 and warned < 60 then lvl := 60;
  end if;
  -- falling back under a level (after cleanup / archiving) re-arms it
  update public.pf_lifecycle_state set warned_level = case when lvl > 0 then lvl
                                                            when pct < 55 then 0
                                                            when pct < 75 then least(warned_level, 60)
                                                            else warned_level end
   where owner_id = p_owner;
  return jsonb_build_object('week', wk, 'db_bytes', db, 'pct', round(pct, 1), 'warn', lvl);
end $$;

-- Everything the capacity screen needs; the projection is computed by the API from 'history'.
create function public.pf_capacity_report(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r record; st public.pf_lifecycle_state; month_start date;
begin
  perform pf_private.assert_owner(p_owner);
  select * into r from pf_private.lc_r2_bytes(p_owner);
  select * into st from public.pf_lifecycle_state where owner_id = p_owner;
  month_start := date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  return jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'top', pf_private.lc_top_tables(8),
    'r2_bytes', r.bytes, 'attachments', r.files,
    'tx_count', (select count(*) from public.pf_tx where owner_id = p_owner),
    'history', coalesce((select jsonb_agg(jsonb_build_object('week', s.week, 'db_bytes', s.db_bytes, 'r2_bytes', s.r2_bytes)
                                           order by s.week)
                           from (select * from public.pf_capacity_snapshot where owner_id = p_owner
                                  order by week desc limit 26) s), '[]'::jsonb),
    'ai', jsonb_build_object(
      'this_month_micro_usd', (select coalesce(sum(spent_micro_usd), 0) from public.pf_ai_usage
                                where owner_id = p_owner and period = month_start),
      'this_month_calls', (select count(*) from public.pf_ai_usage
                            where owner_id = p_owner and period = month_start and state = 'SETTLED'),
      'by_feature', coalesce((select jsonb_agg(jsonb_build_object('feature', f.feature, 'calls', f.calls, 'micro_usd', f.spent)
                                                order by f.spent desc)
                                from (select coalesce(feature, 'other') as feature, count(*) as calls, sum(spent_micro_usd) as spent
                                        from public.pf_ai_usage
                                       where owner_id = p_owner and period = month_start and state <> 'RELEASED'
                                       group by 1) f), '[]'::jsonb),
      'months', coalesce((select jsonb_agg(jsonb_build_object('period', x.period, 'micro_usd', x.spent) order by x.period)
                            from (select period, sum(spent) as spent from (
                                    select period, spent_micro_usd as spent from public.pf_ai_usage where owner_id = p_owner
                                    union all
                                    select period, spent_micro_usd from public.pf_ai_usage_month where owner_id = p_owner) u
                                  where period >= month_start - interval '11 months'
                                  group by period) x), '[]'::jsonb)),
    'last_run_at', st.last_run_at, 'last_result', coalesce(st.last_result, '{}'::jsonb), 'runs', coalesce(st.runs, 0),
    'r2_swept_at', st.r2_swept_at);
end $$;

-- ---------------------------------------------------------------- R2 orphan sweep (bounded, driven by the API)
-- Of the given object keys (one page of an R2 listing under the owner's prefix), the ones no attachment row uses.
create function public.pf_lifecycle_r2_orphans(p_owner uuid, p_keys text[]) returns text[]
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare out text[];
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(array_agg(k), '{}') into out
    from unnest(coalesce(p_keys, '{}')) k
   where k like p_owner::text || '/%'
     and (to_regclass('public.pf_tx_attachment') is null
          or not exists (select 1 from public.pf_tx_attachment a where a.object_key = k))
     and not exists (select 1 from public.pf_attachment a where a.object_key = k);
  return out;
end $$;

create function public.pf_lifecycle_r2_cursor(p_owner uuid, p_cursor text, p_done boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  update public.pf_lifecycle_state set r2_cursor = case when p_done then null else p_cursor end,
         r2_swept_at = case when p_done then now() else r2_swept_at end
   where owner_id = p_owner;
  return (select jsonb_build_object('r2_cursor', r2_cursor, 'r2_swept_at', r2_swept_at)
            from public.pf_lifecycle_state where owner_id = p_owner);
end $$;

create function public.pf_lifecycle_state_get(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select to_jsonb(s) - 'owner_id' from public.pf_lifecycle_state s where s.owner_id = p_owner), '{}'::jsonb);
end $$;

-- Reads for the assistant / reports: distilled monthly history (cheap, survives any detail trimming).
create function public.pf_month_stats(p_owner uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('month', s.month, 'type', s.type, 'category_id', s.category_id,
                     'category', c.name, 'tx_count', s.tx_count, 'total', s.total::text, 'avg', s.avg::text, 'p50', s.p50::text)
                     order by s.month, s.type, s.total desc)
                     from public.pf_month_stat s left join public.pf_category c on c.id = s.category_id
                    where s.owner_id = p_owner and s.month between coalesce(p_from, '2000-01-01') and coalesce(p_to, '2999-12-01')),
                  '[]'::jsonb);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on all functions in schema pf_private from public, anon, authenticated, service_role;

commit;
