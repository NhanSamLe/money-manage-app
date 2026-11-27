-- MoMa migration 008: smart reminders (meal / cash check / reviews / budget alerts) and spending insights.
-- Settings are one jsonb document per owner (defaults live in the Worker). Each scheduled push is claimed once in
-- pf_push_log (at most once per key). Insights store the computed numbers + text; numbers are never produced by AI.
-- Local time is Asia/Ho_Chi_Minh (UTC+7). Server role only.
begin;

create table public.pf_reminder_settings (
  owner_id uuid primary key references public.pf_owner(user_id),
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  updated_at timestamptz not null default now()
);
alter table public.pf_reminder_settings enable row level security;

create table public.pf_reminder_skip (
  owner_id uuid not null references public.pf_owner(user_id),
  kind text not null check (kind in ('breakfast', 'lunch', 'dinner')),
  day date not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, kind, day)
);
alter table public.pf_reminder_skip enable row level security;

create table public.pf_push_log (
  owner_id uuid not null references public.pf_owner(user_id),
  key text not null check (length(key) between 1 and 200),
  sent_at timestamptz not null default now(),
  primary key (owner_id, key)
);
alter table public.pf_push_log enable row level security;

create table public.pf_insight (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  period text not null check (period in ('DAY', 'WEEK', 'MONTH')),
  period_start date not null,
  period_end date not null check (period_end >= period_start),
  created_at timestamptz not null default now(),
  payload jsonb not null check (jsonb_typeof(payload) = 'object')
);
alter table public.pf_insight enable row level security;
create index pf_insight_owner_idx on public.pf_insight(owner_id, period, created_at desc);

revoke all on table public.pf_reminder_settings, public.pf_reminder_skip, public.pf_push_log, public.pf_insight from public, anon, authenticated;

-- ---------------------------------------------------------------- settings
create function public.pf_reminder_settings_read(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return (select settings from public.pf_reminder_settings where owner_id = p_owner);
end $$;

create function public.pf_reminder_settings_write(p_owner uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' or length(p_settings::text) > 8000 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_reminder_settings(owner_id, settings, updated_at) values (p_owner, p_settings, now())
    on conflict (owner_id) do update set settings = excluded.settings, updated_at = now();
  return p_settings;
end $$;

-- ---------------------------------------------------------------- day status (skips + meals logged)
-- Food categories: the seeded "Ăn uống" category (matched by name, or the seeded 'restaurant' icon) and all of its
-- descendants. A meal is done when a POSTED expense in one of them falls in the meal's local window.
create function pf_private.food_categories(p_owner uuid) returns setof uuid
language sql stable set search_path = pg_catalog, public as $$
  with recursive food as (
    select c.id from public.pf_category c
     where c.owner_id = p_owner and c.type = 'EXPENSE' and (lower(btrim(c.name)) = lower('Ăn uống') or c.icon = 'restaurant')
    union
    select c.id from public.pf_category c join food f on c.parent_id = f.id where c.owner_id = p_owner
  ) select id from food
$$;

create function public.pf_reminder_day_status(p_owner uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare meals jsonb := '{}'::jsonb; w record; done boolean;
begin
  perform pf_private.assert_owner(p_owner);
  if p_day is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  for w in select * from (values ('breakfast', time '04:00', time '10:30'), ('lunch', time '10:30', time '15:00'), ('dinner', time '15:00', time '23:00'))
             as t(kind, t_from, t_to) loop
    select exists (
      select 1 from public.pf_tx t
       where t.owner_id = p_owner and t.kind = 'EXPENSE' and t.status = 'POSTED'
         and t.category_id in (select pf_private.food_categories(p_owner))
         and t.effective_at >= ((p_day + w.t_from) at time zone 'Asia/Ho_Chi_Minh')
         and t.effective_at <  ((p_day + w.t_to) at time zone 'Asia/Ho_Chi_Minh')) into done;
    meals := meals || jsonb_build_object(w.kind, done);
  end loop;
  return jsonb_build_object(
    'date', to_char(p_day, 'YYYY-MM-DD'),
    'skipped', coalesce((select jsonb_agg(s.kind order by array_position(array['breakfast', 'lunch', 'dinner'], s.kind))
                           from public.pf_reminder_skip s where s.owner_id = p_owner and s.day = p_day), '[]'::jsonb),
    'done', meals,
    'has_accounts', exists (select 1 from public.pf_account a where a.owner_id = p_owner and not a.archived));
end $$;

create function public.pf_reminder_skip_set(p_owner uuid, p_kind text, p_day date, p_on boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  if p_kind not in ('breakfast', 'lunch', 'dinner') or p_day is null or p_on is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  if p_on then
    insert into public.pf_reminder_skip(owner_id, kind, day) values (p_owner, p_kind, p_day) on conflict do nothing;
  else
    delete from public.pf_reminder_skip where owner_id = p_owner and kind = p_kind and day = p_day;
  end if;
  return public.pf_reminder_day_status(p_owner, p_day);
end $$;

-- True only for the first claim of a key: the caller sends the push only then (at most once per key).
create function public.pf_push_log_claim(p_owner uuid, p_key text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare k text;
begin
  perform pf_private.assert_owner(p_owner);
  if coalesce(p_key, '') = '' or length(p_key) > 200 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_push_log(owner_id, key) values (p_owner, p_key) on conflict do nothing returning key into k;
  return k is not null;
end $$;

-- ---------------------------------------------------------------- insights
create function pf_private.insight_json(i public.pf_insight) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select i.payload || jsonb_build_object('id', i.id, 'period', i.period, 'period_start', to_char(i.period_start, 'YYYY-MM-DD'),
    'period_end', to_char(i.period_end, 'YYYY-MM-DD'), 'created_at', i.created_at)
$$;

create function public.pf_insight_create(p_owner uuid, p_period text, p_start date, p_end date, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare i public.pf_insight;
begin
  perform pf_private.assert_owner(p_owner);
  if p_period not in ('DAY', 'WEEK', 'MONTH') or p_start is null or p_end is null or p_end < p_start
     or p_payload is null or jsonb_typeof(p_payload) <> 'object' or length(p_payload::text) > 32000 then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  insert into public.pf_insight(owner_id, period, period_start, period_end, payload) values (p_owner, p_period, p_start, p_end, p_payload) returning * into i;
  return pf_private.insight_json(i);
end $$;

create function public.pf_insight_list(p_owner uuid, p_period text, p_limit integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 20), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.insight_json(x) order by x.created_at desc, x.id desc) from (
      select * from public.pf_insight where owner_id = p_owner and (p_period is null or period = p_period)
       order by created_at desc, id desc limit lim) x), '[]'::jsonb);
end $$;

create function public.pf_insight_get(p_owner uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare i public.pf_insight;
begin
  perform pf_private.assert_owner(p_owner);
  select * into i from public.pf_insight where id = p_id and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return pf_private.insight_json(i);
end $$;

create function public.pf_insight_latest(p_owner uuid, p_period text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare i public.pf_insight;
begin
  perform pf_private.assert_owner(p_owner);
  select * into i from public.pf_insight where owner_id = p_owner and period = p_period order by created_at desc, id desc limit 1;
  if not found then return null; end if;
  return pf_private.insight_json(i);
end $$;

-- Analysis inputs for local dates [p_from, p_to] (inclusive). Same classification as the dashboard: only
-- SYS_ADJUSTMENT_* is excluded; by_category covers user categories (CAT_*); daily = local-day totals.
create function public.pf_period_stats(p_owner uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t_from timestamptz; t_to timestamptz; r jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then perform pf_private.err('VALIDATION_FAILED'); end if;
  t_from := p_from::timestamp at time zone 'Asia/Ho_Chi_Minh';
  t_to := (p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';
  with lines as (
    select (j.effective_at at time zone 'Asia/Ho_Chi_Minh')::date as day, a.class, a.code, a.id as lid, e.signed_amount::numeric as amt
      from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
      join public.pf_ledger_account a on a.id = e.ledger_account_id
     where j.owner_id = p_owner and j.effective_at >= t_from and j.effective_at < t_to
       and a.class in ('INCOME', 'EXPENSE') and a.code not in ('SYS_ADJUSTMENT_IN', 'SYS_ADJUSTMENT_OUT')
  ), cats as (
    select lid, sum(amt) as total from lines where class = 'EXPENSE' and code like 'CAT\_%' escape '\' group by lid having sum(amt) <> 0
  ), days as (
    select day, coalesce(-sum(amt) filter (where class = 'INCOME'), 0) as inc, coalesce(sum(amt) filter (where class = 'EXPENSE'), 0) as exp
      from lines group by day
  )
  select jsonb_build_object(
      'from', to_char(p_from, 'YYYY-MM-DD'), 'to', to_char(p_to, 'YYYY-MM-DD'),
      'income', (select coalesce(-sum(amt) filter (where class = 'INCOME'), 0) from lines)::text,
      'expense', (select coalesce(sum(amt) filter (where class = 'EXPENSE'), 0) from lines)::text,
      'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category_id', c.id, 'name', c.name, 'parent_id', c.parent_id, 'amount', s.total::text)
                                                order by s.total desc, c.name), '[]'::jsonb)
                        from cats s join public.pf_category c on c.ledger_account_id = s.lid),
      'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', to_char(d.day, 'YYYY-MM-DD'), 'income', d.inc::text, 'expense', d.exp::text) order by d.day), '[]'::jsonb)
                  from days d))
    into r;
  return r;
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
