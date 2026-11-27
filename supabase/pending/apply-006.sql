-- MoMa: chạy file này MỘT lần trong Supabase SQL Editor (Run and enable RLS)
-- Migration 006: kiểm soát chi phí Trợ lý AI (pf_ai_reserve / pf_ai_settle / pf_ai_mark_unknown / pf_ai_usage_read).
-- Thiếu file này thì Trợ lý luôn báo "Hệ thống tạm thời gián đoạn".
-- AI spend guard (spec 05 section 5) on the baseline pf_ai_usage ledger: reserve the worst-case cost before every
-- provider call (row lock on the owner), settle with actual usage, keep the reservation when the outcome is unknown.
-- Integer micro-USD, UTC calendar month. Server role only.
begin;

create function public.pf_ai_reserve(p_owner uuid, p_estimate bigint, p_cap bigint, p_provider text, p_model text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare per date := date_trunc('month', now() at time zone 'UTC')::date; committed bigint; rid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if p_estimate <= 0 or p_cap <= 0 or coalesce(p_provider, '') = '' or coalesce(p_model, '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform 1 from public.pf_owner where user_id = p_owner for update;   -- serialises concurrent reservations
  select coalesce(sum(case when state = 'SETTLED' then spent_micro_usd else reserved_micro_usd end) filter (where state <> 'RELEASED'), 0)
    into committed from public.pf_ai_usage where owner_id = p_owner and period = per;
  if committed + p_estimate > p_cap then perform pf_private.err('AI_BUDGET_EXCEEDED'); end if;
  insert into public.pf_ai_usage(owner_id, period, provider, model, reserved_micro_usd, state)
    values (p_owner, per, p_provider, p_model, p_estimate, 'RESERVED') returning id into rid;
  return jsonb_build_object('id', rid, 'period', per, 'committed_micro', committed + p_estimate, 'cap_micro', p_cap);
end $$;

create function public.pf_ai_settle(p_owner uuid, p_id uuid, p_actual bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_ai_usage set state = 'SETTLED', spent_micro_usd = greatest(p_actual, 0)
   where id = p_id and owner_id = p_owner and state in ('RESERVED', 'UNKNOWN_CHARGE');
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Provider outcome unknown (timeout / transport error): the vendor may still bill, so the reservation stays counted.
create function public.pf_ai_mark_unknown(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_ai_usage set state = 'UNKNOWN_CHARGE' where id = p_id and owner_id = p_owner and state = 'RESERVED';
  return jsonb_build_object('ok', true);
end $$;

create function public.pf_ai_usage_read(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare per date := date_trunc('month', now() at time zone 'UTC')::date;
begin
  perform pf_private.assert_owner(p_owner);
  return (select jsonb_build_object(
      'period', per,
      'spent_micro', coalesce(sum(spent_micro_usd) filter (where state = 'SETTLED'), 0),
      'reserved_micro', coalesce(sum(reserved_micro_usd) filter (where state in ('RESERVED', 'UNKNOWN_CHARGE')), 0),
      'calls', count(*) filter (where state = 'SETTLED'))
    from public.pf_ai_usage where owner_id = p_owner and period = per);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
