-- MoMa migration 021: Kế hoạch & Dự toán (D-027).
-- Event plans ("tối thứ 7 đi nhậu", "tiệc tốt nghiệp tháng 1"): an estimate (low / likely / high + breakdown, computed by
-- the API from the owner's own history) and, after the event, the actual money spent in its time window (plan vs actual).
-- Life plans ("mua nhà 2,5 tỷ", "mua xe"): price + down payment / loan / inflation assumptions; the API projects when the
-- owner can afford it from real income and spending. Saving itself goes through goals (pf_goal, GOAL_* commands).
-- Planning data only: nothing here writes the ledger. No new command types (the dispatcher is untouched); the assistant
-- and the app use the owner-scoped RPCs below through /v1/plans/*. Server role only.
begin;

create table public.pf_event_plan (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  title text not null check (length(title) between 1 and 120),
  kind text not null check (kind in ('NHAU', 'AN_UONG', 'CAFE', 'TIEC', 'SINH_NHAT', 'DU_LICH', 'KHAC')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  headcount integer not null default 1 check (headcount between 1 and 500),
  -- names of the other people (free text, matched to contacts by the API when useful)
  people jsonb not null default '[]'::jsonb check (jsonb_typeof(people) = 'array' and jsonb_array_length(people) <= 50),
  place text check (place is null or length(place) <= 120),
  owner_pays boolean not null default false,       -- "tôi bao": no split expected
  transport text not null default 'GRAB' check (transport in ('GRAB', 'OWN', 'NONE')),
  note text check (note is null or length(note) <= 300),
  estimate jsonb not null default '{}'::jsonb check (jsonb_typeof(estimate) = 'object'),
  budget bigint check (budget is null or budget >= 0),   -- the owner's expected share (likely)
  state text not null default 'PLANNED' check (state in ('PLANNED', 'DONE', 'CANCELLED')),
  actual jsonb check (actual is null or jsonb_typeof(actual) = 'object'),
  reminded_at timestamptz,
  alerted_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (ends_at > starts_at and ends_at - starts_at <= interval '31 days')
);
alter table public.pf_event_plan enable row level security;
revoke all on table public.pf_event_plan from public, anon, authenticated;
create index pf_event_plan_owner_idx on public.pf_event_plan(owner_id, starts_at desc);
create index pf_event_plan_open_idx on public.pf_event_plan(owner_id, state, starts_at) where state = 'PLANNED';

create table public.pf_life_plan (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  name text not null check (length(name) between 1 and 120),
  kind text not null check (kind in ('HOUSE', 'CAR', 'TRAVEL', 'WEDDING', 'EDUCATION', 'OTHER')),
  price bigint not null check (price > 0 and price <= 1000000000000),
  down_pct numeric(5, 2) not null default 100 check (down_pct > 0 and down_pct <= 100),
  loan_rate_pct numeric(5, 2) not null default 0 check (loan_rate_pct between 0 and 30),
  loan_years smallint not null default 0 check (loan_years between 0 and 35),
  inflation_pct numeric(5, 2) check (inflation_pct between -5 and 30),          -- null = market default for the kind
  income_growth_pct numeric(5, 2) check (income_growth_pct between -20 and 50),  -- null = keeps pace with inflation
  extra_saving bigint not null default 0 check (extra_saving between -1000000000 and 1000000000),
  goal_id uuid references public.pf_goal(id),
  target_date date,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
alter table public.pf_life_plan enable row level security;
revoke all on table public.pf_life_plan from public, anon, authenticated;
create index pf_life_plan_owner_idx on public.pf_life_plan(owner_id, archived, created_at);

-- ---------------------------------------------------------------- event plans
create function pf_private.event_plan_json(e public.pf_event_plan) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', e.id, 'title', e.title, 'kind', e.kind, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
    'headcount', e.headcount, 'people', e.people, 'place', e.place, 'owner_pays', e.owner_pays, 'transport', e.transport,
    'note', e.note, 'estimate', e.estimate, 'budget', e.budget::text, 'state', e.state, 'actual', e.actual,
    'reminded_at', e.reminded_at, 'alerted_at', e.alerted_at, 'closed_at', e.closed_at, 'created_at', e.created_at,
    'updated_at', e.updated_at, 'version', e.version)
$$;

-- Create (id new / null) or update (same id, still PLANNED). The client may choose the id so a retry never doubles.
create function public.pf_plan_event_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan; pid uuid; s timestamptz; f timestamptz;
begin
  perform pf_private.assert_owner(p_owner);
  if jsonb_typeof(p) <> 'object' then perform pf_private.err('VALIDATION_FAILED'); end if;
  begin
    pid := nullif(p->>'id', '')::uuid;
    s := (p->>'starts_at')::timestamptz;
    f := coalesce((p->>'ends_at')::timestamptz, s + interval '4 hours');
  exception when others then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  if s is null or coalesce(btrim(p->>'title'), '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  if pid is not null then
    select * into e from public.pf_event_plan where id = pid for update;
    if found and e.owner_id <> p_owner then perform pf_private.err('NOT_FOUND'); end if;
    if found and e.state <> 'PLANNED' then perform pf_private.err('INVALID_STATE'); end if;
  end if;
  begin
    if e.id is null then
      insert into public.pf_event_plan(id, owner_id, title, kind, starts_at, ends_at, headcount, people, place, owner_pays,
                                       transport, note, estimate, budget)
      values (coalesce(pid, gen_random_uuid()), p_owner, left(btrim(p->>'title'), 120), coalesce(p->>'kind', 'KHAC'), s, f,
              coalesce((p->>'headcount')::integer, 1), coalesce(p->'people', '[]'::jsonb), nullif(left(btrim(p->>'place'), 120), ''),
              coalesce((p->>'owner_pays')::boolean, false), coalesce(p->>'transport', 'GRAB'), nullif(left(btrim(p->>'note'), 300), ''),
              coalesce(p->'estimate', '{}'::jsonb), nullif(p->>'budget', '')::bigint)
      returning * into e;
    else
      update public.pf_event_plan set
        title = left(btrim(p->>'title'), 120), kind = coalesce(p->>'kind', e.kind), starts_at = s, ends_at = f,
        headcount = coalesce((p->>'headcount')::integer, e.headcount), people = coalesce(p->'people', e.people),
        place = case when p ? 'place' then nullif(left(btrim(p->>'place'), 120), '') else e.place end,
        owner_pays = coalesce((p->>'owner_pays')::boolean, e.owner_pays), transport = coalesce(p->>'transport', e.transport),
        note = case when p ? 'note' then nullif(left(btrim(p->>'note'), 300), '') else e.note end,
        estimate = coalesce(p->'estimate', e.estimate), budget = coalesce(nullif(p->>'budget', '')::bigint, e.budget),
        reminded_at = case when e.starts_at <> s then null else e.reminded_at end,
        updated_at = now(), version = e.version + 1
      where id = e.id returning * into e;
    end if;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  return pf_private.event_plan_json(e);
end $$;

-- p_state null = every state. Newest first by start time, bounded.
create function public.pf_plan_event_list(p_owner uuid, p_state text, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.event_plan_json(e) order by e.starts_at desc)
                     from (select * from public.pf_event_plan
                            where owner_id = p_owner and (p_state is null or state = p_state)
                              and (p_from is null or ends_at >= p_from) and (p_to is null or starts_at < p_to)
                            order by starts_at desc limit 200) e), '[]'::jsonb);
end $$;

create function public.pf_plan_event_get(p_owner uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan;
begin
  perform pf_private.assert_owner(p_owner);
  select * into e from public.pf_event_plan where id = p_id and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return pf_private.event_plan_json(e);
end $$;

-- DONE (with the actual snapshot) or CANCELLED. A DONE plan can be closed again (refreshed actual), a cancelled one not.
create function public.pf_plan_event_close(p_owner uuid, p_id uuid, p_state text, p_actual jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan;
begin
  perform pf_private.assert_owner(p_owner);
  if p_state not in ('DONE', 'CANCELLED') then perform pf_private.err('VALIDATION_FAILED'); end if;
  select * into e from public.pf_event_plan where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if e.state = 'CANCELLED' then perform pf_private.err('INVALID_STATE'); end if;
  update public.pf_event_plan set state = p_state,
         actual = case when p_state = 'DONE' and jsonb_typeof(p_actual) = 'object' then p_actual else e.actual end,
         closed_at = now(), updated_at = now(), version = e.version + 1
   where id = e.id returning * into e;
  return pf_private.event_plan_json(e);
end $$;

-- Reminder / in-event alert bookkeeping (claimed once): true when this call set the flag.
create function public.pf_plan_event_mark(p_owner uuid, p_id uuid, p_what text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  if p_what = 'REMINDED' then
    update public.pf_event_plan set reminded_at = now() where id = p_id and owner_id = p_owner and reminded_at is null;
  elsif p_what = 'ALERTED' then
    update public.pf_event_plan set alerted_at = now() where id = p_id and owner_id = p_owner and alerted_at is null;
  else
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- ---------------------------------------------------------------- history reads for estimation / actuals
-- Money out between p_from and p_to (posted EXPENSE / UNKNOWN_DEBIT), with the owner's own share when a split was
-- applied (the others' shares became their debts) and the group size of that split. Debt money, recurring payments
-- (rent, bills) and transfers are not part of an outing, so they are left out.
create function public.pf_plan_spend_rows(p_owner uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  -- Text normalisation and the ride / food flags are computed here (Postgres), not in the Worker: the API has a
  -- 10 ms CPU budget per request on the free plan. The word lists mirror modules/plans/estimate.ts.
  return coalesce((select jsonb_agg(r.j order by r.at) from (
    select t.effective_at as at, jsonb_build_object(
             'id', t.id, 'at', t.effective_at, 'kind', t.kind, 'amount', t.amount::text,
             'owner_amount', coalesce(sa.owner_amount, t.amount)::text,
             'group_size', case when sa.id is not null then jsonb_array_length(sa.shares) + 1 end,
             'category', c.name, 'merchant', t.merchant, 'note', left(t.note, 160), 'account_id', t.account_id,
             'hour', extract(hour from t.effective_at at time zone 'Asia/Ho_Chi_Minh')::integer,
             'norm', x.c || x.t,
             'ride', x.t !~ '\m(xang|gui xe|do xe|bai xe|rua xe|sua xe|ve xe|ve may bay|bao duong)\M'
                     and (x.t ~ '\m(grab|be|xanh sm|xanhsm|gojek|taxi|xe om|uber|vinasun|mai linh|grabcar|grabbike|gsm)\M'
                          or (x.c ~ '\mdi chuyen\M' and t.amount between 12000 and 600000)),
             'food', x.c ~ '\m(an uong|an|nha hang|do uong|giai tri|nhau|cafe|ca phe)\M'
                     or x.t ~ '\m(nhau|bia|beer|lau|nuong|oc|quan|nha hang|buffet|karaoke|pub|bar|an|com|pho|bun|cafe|ca phe|tra sua|coffee|highlands|phuc long|katinat|starbucks)\M') as j
      from public.pf_tx t
      left join public.pf_category c on c.id = t.category_id
      cross join lateral (select ' ' || pf_private.ai_norm(c.name) || ' ' as c,
                                 ' ' || pf_private.ai_norm(concat_ws(' ', t.merchant, t.note)) || ' ' as t) x
      left join lateral (select a.id, a.owner_amount, a.shares from public.pf_split_application a
                          where a.tx_id = t.id and a.state = 'APPLIED' order by a.created_at desc limit 1) sa on true
     where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
       and t.effective_at >= p_from and t.effective_at < p_to
       and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
       and not exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id)
       and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)
     order by t.effective_at desc limit 1200) r), '[]'::jsonb);  -- bounded: the API must stay light (Workers free plan)
end $$;

-- Income / expense per Vietnam calendar month for the last p_months months (current month included, flagged partial).
create function public.pf_plan_months(p_owner uuid, p_months integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare n integer := least(greatest(coalesce(p_months, 12), 1), 36);
        cur date := date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('month', to_char(m.m, 'YYYY-MM'), 'income', coalesce(x.income, 0)::text,
                     'expense', coalesce(x.expense, 0)::text, 'partial', m.m = cur) order by m.m)
    from generate_series(cur - make_interval(months => n - 1), cur, interval '1 month') as m(m)
    left join (
      select date_trunc('month', j.effective_at at time zone 'Asia/Ho_Chi_Minh')::date as mm,
             -sum(e.signed_amount::numeric) filter (where a.class = 'INCOME') as income,
             sum(e.signed_amount::numeric) filter (where a.class = 'EXPENSE') as expense
        from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
        join public.pf_ledger_account a on a.id = e.ledger_account_id
       where j.owner_id = p_owner and a.code not in ('SYS_ADJUSTMENT_IN', 'SYS_ADJUSTMENT_OUT')
         and j.effective_at >= (cur - make_interval(months => n - 1))::timestamp at time zone 'Asia/Ho_Chi_Minh'
       group by 1) x on x.mm = m.m::date), '[]'::jsonb);
end $$;

-- What the owner has now: known assets / liabilities, debts both ways, and every active goal with its saved amount.
create function public.pf_plan_wealth(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare assets numeric; liabilities numeric; receivable numeric; payable numeric;
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(sum(b.debit_net) filter (where b.class = 'ASSET'), 0), coalesce(-sum(b.debit_net) filter (where b.class = 'LIABILITY'), 0)
    into assets, liabilities
    from public.pf_account a join pf_private.ledger_balance b on b.id = a.ledger_account_id
   where a.owner_id = p_owner and a.baseline_known and not a.archived;
  select coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'RECEIVABLE'), 0),
         coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'PAYABLE'), 0)
    into receivable, payable from public.pf_debt d where d.owner_id = p_owner and d.state in ('OPEN', 'PARTIAL');
  return jsonb_build_object('assets', assets::text, 'liabilities', liabilities::text, 'receivable', receivable::text,
    'payable', payable::text,
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'target', g.target::text,
                          'due_date', g.due_date, 'state', g.state,
                          'allocated', coalesce((select sum(al.signed_amount::numeric) from public.pf_allocation al where al.goal_id = g.id), 0)::text)
                        order by g.name)
                        from public.pf_goal g where g.owner_id = p_owner and g.state = 'ACTIVE'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- life plans
create function pf_private.life_plan_json(l public.pf_life_plan) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', l.id, 'name', l.name, 'kind', l.kind, 'price', l.price::text, 'down_pct', l.down_pct,
    'loan_rate_pct', l.loan_rate_pct, 'loan_years', l.loan_years, 'inflation_pct', l.inflation_pct,
    'income_growth_pct', l.income_growth_pct, 'extra_saving', l.extra_saving::text, 'goal_id', l.goal_id,
    'target_date', l.target_date, 'created_at', l.created_at, 'updated_at', l.updated_at, 'version', l.version)
$$;

create function public.pf_life_plan_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l public.pf_life_plan; pid uuid; gid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if jsonb_typeof(p) <> 'object' or coalesce(btrim(p->>'name'), '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  begin
    pid := nullif(p->>'id', '')::uuid;
    gid := nullif(p->>'goal_id', '')::uuid;
  exception when others then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  if gid is not null and not exists (select 1 from public.pf_goal where id = gid and owner_id = p_owner) then
    perform pf_private.err('NOT_FOUND');
  end if;
  if pid is not null then
    select * into l from public.pf_life_plan where id = pid for update;
    if found and (l.owner_id <> p_owner or l.archived) then perform pf_private.err('NOT_FOUND'); end if;
  end if;
  begin
    if l.id is null then
      insert into public.pf_life_plan(id, owner_id, name, kind, price, down_pct, loan_rate_pct, loan_years, inflation_pct,
                                      income_growth_pct, extra_saving, goal_id, target_date)
      values (coalesce(pid, gen_random_uuid()), p_owner, left(btrim(p->>'name'), 120), coalesce(p->>'kind', 'OTHER'),
              (p->>'price')::bigint, coalesce((p->>'down_pct')::numeric, 100), coalesce((p->>'loan_rate_pct')::numeric, 0),
              coalesce((p->>'loan_years')::smallint, 0), (p->>'inflation_pct')::numeric,
              (p->>'income_growth_pct')::numeric, coalesce((p->>'extra_saving')::bigint, 0), gid,
              nullif(p->>'target_date', '')::date)
      returning * into l;
    else
      update public.pf_life_plan set
        name = left(btrim(p->>'name'), 120), kind = coalesce(p->>'kind', l.kind), price = coalesce((p->>'price')::bigint, l.price),
        down_pct = coalesce((p->>'down_pct')::numeric, l.down_pct), loan_rate_pct = coalesce((p->>'loan_rate_pct')::numeric, l.loan_rate_pct),
        loan_years = coalesce((p->>'loan_years')::smallint, l.loan_years),
        inflation_pct = case when p ? 'inflation_pct' then (p->>'inflation_pct')::numeric else l.inflation_pct end,
        income_growth_pct = case when p ? 'income_growth_pct' then (p->>'income_growth_pct')::numeric else l.income_growth_pct end,
        extra_saving = coalesce((p->>'extra_saving')::bigint, l.extra_saving),
        goal_id = case when p ? 'goal_id' then gid else l.goal_id end,
        target_date = case when p ? 'target_date' then nullif(p->>'target_date', '')::date else l.target_date end,
        updated_at = now(), version = l.version + 1
      where id = l.id returning * into l;
    end if;
  exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range
                  or invalid_datetime_format then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  return pf_private.life_plan_json(l);
end $$;

create function public.pf_life_plan_list(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.life_plan_json(l) order by l.created_at)
                     from public.pf_life_plan l where l.owner_id = p_owner and not l.archived), '[]'::jsonb);
end $$;

-- Archived, never deleted (the linked goal and its savings stay untouched).
create function public.pf_life_plan_delete(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_life_plan set archived = true, updated_at = now(), version = version + 1
   where id = p_id and owner_id = p_owner and not archived;
  get diagnostics n = row_count;
  if n = 0 then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('id', p_id, 'archived', true);
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
