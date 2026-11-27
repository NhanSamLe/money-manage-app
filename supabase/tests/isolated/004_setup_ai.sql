-- Migrations 005 (re-invite) and 006 (AI spend guard). Fresh database with stubs and all migrations applied.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'owner2@example.test', null),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'owner2b@example.test', now());

set role service_role;

-- 1. Re-invite: an abandoned invite binding can be reset only by the lease holder, and never once BOUND.
do $$
declare
  l constant uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  r jsonb;
begin
  perform public.pf_setup_reserve(l, now() + interval '10 min');
  perform public.pf_setup_record_invite(l, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  -- a different user cannot be recorded while the first invite is bound
  begin
    perform public.pf_setup_record_invite(l, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
    raise exception 'expected IDENTITY_CONFLICT';
  exception when others then
    assert sqlerrm = 'IDENTITY_CONFLICT', 'got ' || sqlerrm;
  end;
  -- wrong lease is refused
  begin
    perform public.pf_setup_reset_invite('dddddddd-dddd-dddd-dddd-dddddddddddd');
    raise exception 'expected SETUP_LEASE_INVALID';
  exception when others then
    assert sqlerrm = 'SETUP_LEASE_INVALID', 'got ' || sqlerrm;
  end;
  r := public.pf_setup_reset_invite(l);
  assert r->>'old_invite_user_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'reports the replaced user';
  assert (select state from public.pf_setup) = 'UNINITIALIZED', 'state reset';
  perform public.pf_setup_record_invite(l, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  assert (select invite_user_id from public.pf_setup) = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'new invite recorded';
  perform public.pf_setup_claim('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Owner');
  begin
    perform public.pf_setup_reset_invite(l);
    raise exception 'expected SETUP_ALREADY_BOUND';
  exception when others then
    assert sqlerrm = 'SETUP_ALREADY_BOUND', 'bound owner must be untouchable, got ' || sqlerrm;
  end;
end $$;

-- 2. AI spend guard: reserve worst case, settle with actual, unknown outcomes stay reserved, cap holds.
do $$
declare
  o constant uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  r jsonb; id1 uuid; id2 uuid;
begin
  r := public.pf_ai_reserve(o, 1500, 10000, 'deepseek', 'deepseek-flash');
  id1 := (r->>'id')::uuid;
  assert (r->>'committed_micro')::bigint = 1500, 'reserved';
  perform public.pf_ai_settle(o, id1, 400);
  r := public.pf_ai_usage_read(o);
  assert (r->>'spent_micro')::bigint = 400 and (r->>'reserved_micro')::bigint = 0 and (r->>'calls')::int = 1, 'settled with actual cost';
  id2 := (public.pf_ai_reserve(o, 9000, 10000, 'deepseek', 'deepseek-flash')->>'id')::uuid;   -- 400 + 9000 <= 10000
  perform public.pf_ai_mark_unknown(o, id2);                                                    -- timeout: stays reserved
  r := public.pf_ai_usage_read(o);
  assert (r->>'reserved_micro')::bigint = 9000, 'unknown charge keeps its reservation';
  begin
    perform public.pf_ai_reserve(o, 1000, 10000, 'deepseek', 'deepseek-flash');                 -- 400 + 9000 + 1000 > 10000
    raise exception 'expected AI_BUDGET_EXCEEDED';
  exception when others then
    assert sqlerrm = 'AI_BUDGET_EXCEEDED', 'cap must hold, got ' || sqlerrm;
  end;
  begin
    perform public.pf_ai_reserve(o, 0, 10000, 'deepseek', 'deepseek-flash');
    raise exception 'expected VALIDATION_FAILED';
  exception when others then
    assert sqlerrm = 'VALIDATION_FAILED', 'got ' || sqlerrm;
  end;
  begin
    perform public.pf_ai_settle(o, gen_random_uuid(), 1);
    raise exception 'expected NOT_FOUND';
  exception when others then
    assert sqlerrm = 'NOT_FOUND', 'got ' || sqlerrm;
  end;
end $$;

-- 3. Not callable by anon.
reset role;
set role anon;
do $$ begin
  begin
    perform public.pf_ai_reserve('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 1, 1, 'x', 'y');
    raise exception 'anon must not execute';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 004_setup_ai' as result;
