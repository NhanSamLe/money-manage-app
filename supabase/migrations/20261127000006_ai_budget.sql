-- AI spend guard (spec 05 section 5): reserve the worst-case cost before every provider call, settle with actual usage.
-- Integer micro-USD, UTC calendar month, row-locked. Server role only. Unknown timeouts keep their reservation.
begin;

create table public.pf_ai_usage (
  owner_id uuid not null references public.pf_owner(user_id),
  period text not null check (period ~ '^[0-9]{4}-[0-9]{2}$'),
  reserved_micro bigint not null default 0 check (reserved_micro >= 0),
  spent_micro bigint not null default 0 check (spent_micro >= 0),
  calls integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (owner_id, period)
);
alter table public.pf_ai_usage enable row level security;

create function public.pf_ai_reserve(p_owner uuid, p_estimate bigint, p_cap bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare per text := to_char(now() at time zone 'UTC', 'YYYY-MM'); u public.pf_ai_usage;
begin
  perform pf_private.assert_owner(p_owner);
  if p_estimate <= 0 or p_cap <= 0 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_ai_usage(owner_id, period) values (p_owner, per) on conflict do nothing;
  select * into u from public.pf_ai_usage where owner_id = p_owner and period = per for update;
  if u.reserved_micro + u.spent_micro + p_estimate > p_cap then perform pf_private.err('AI_BUDGET_EXCEEDED'); end if;
  update public.pf_ai_usage set reserved_micro = reserved_micro + p_estimate, updated_at = now() where owner_id = p_owner and period = per;
  return jsonb_build_object('period', per, 'spent_micro', u.spent_micro, 'reserved_micro', u.reserved_micro + p_estimate, 'cap_micro', p_cap);
end $$;

create function public.pf_ai_settle(p_owner uuid, p_period text, p_estimate bigint, p_actual bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_ai_usage
     set reserved_micro = greatest(reserved_micro - p_estimate, 0), spent_micro = spent_micro + greatest(p_actual, 0),
         calls = calls + 1, updated_at = now()
   where owner_id = p_owner and period = p_period;
  return jsonb_build_object('ok', true);
end $$;

create function public.pf_ai_usage_read(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare per text := to_char(now() at time zone 'UTC', 'YYYY-MM'); u public.pf_ai_usage;
begin
  perform pf_private.assert_owner(p_owner);
  select * into u from public.pf_ai_usage where owner_id = p_owner and period = per;
  return jsonb_build_object('period', per, 'spent_micro', coalesce(u.spent_micro, 0), 'reserved_micro', coalesce(u.reserved_micro, 0), 'calls', coalesce(u.calls, 0));
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
