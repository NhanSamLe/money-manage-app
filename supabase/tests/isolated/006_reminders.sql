-- Migration 008: reminder settings, skips, meal status, push claims, insights and period stats.
-- Fresh database, stubs + all migrations applied.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('abababab-abab-abab-abab-abababababab', 'remind@example.test', now());

set role service_role;

do $$
declare
  o constant uuid := 'abababab-abab-abab-abab-abababababab';
  s constant uuid := '33333333-3333-3333-3333-333333333333';
  d constant uuid := '44444444-4444-4444-4444-444444444444';
  cid uuid; cash uuid; food uuid; coffee uuid; move uuid; salary uuid; r jsonb; ins jsonb; st jsonb; n int;
  day constant date := '2026-11-20';
begin
  perform public.pf_setup_reserve('ffffffff-ffff-ffff-ffff-ffffffffffff', now() + interval '10 min');
  perform public.pf_setup_record_invite('ffffffff-ffff-ffff-ffff-ffffffffffff', o);
  perform public.pf_setup_claim(o, 'Remind Owner');
  perform public.pf_device_register(o, s, d, 'Test');

  -- no account yet: status says so (the scheduler stays quiet)
  st := public.pf_reminder_day_status(o, day);
  assert (st->>'has_accounts')::boolean = false, 'no accounts yet';
  assert st->'done' = '{"breakfast": false, "lunch": false, "dinner": false}'::jsonb, 'nothing done: ' || st::text;

  cid := gen_random_uuid();
  perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'CASH', 'institution', 'Ví', 'name', 'Tiền mặt', 'opening_amount', '5000000', 'baseline_at', '2026-11-01T00:00:00Z')));
  select (x->>'id')::uuid into cash from jsonb_array_elements(public.pf_read_accounts(o)) x where x->>'name' = 'Tiền mặt';
  select (x->>'id')::uuid into food from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Ăn uống';
  select (x->>'id')::uuid into move from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Di chuyển';
  select (x->>'id')::uuid into salary from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Lương';
  -- a child category of "Ăn uống" also counts as a meal
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'CATEGORY_UPSERT', 'schema_version', 1,
        'payload', jsonb_build_object('type', 'EXPENSE', 'name', 'Cà phê', 'parent_id', food)));
  coffee := (r->>'category_id')::uuid;

  -- 07:30 local coffee (child of food) -> breakfast; 12:00 local taxi (not food) -> lunch NOT done; 19:00 food -> dinner
  foreach r in array array[
      jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '30000', 'effective_at', '2026-11-20T00:30:00Z', 'category_id', coffee),
      jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '70000', 'effective_at', '2026-11-20T05:00:00Z', 'category_id', move),
      jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '120000', 'effective_at', '2026-11-20T12:00:00Z', 'category_id', food),
      jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '50000', 'effective_at', '2026-11-19T12:00:00Z', 'category_id', food),
      jsonb_build_object('kind', 'INCOME', 'account_id', cash, 'amount', '2000000', 'effective_at', '2026-11-20T03:00:00Z', 'category_id', salary)] loop
    cid := gen_random_uuid();
    perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1, 'payload', r));
  end loop;

  st := public.pf_reminder_day_status(o, day);
  assert (st->>'has_accounts')::boolean, 'has accounts';
  assert st->'done' = '{"breakfast": true, "lunch": false, "dinner": true}'::jsonb, 'meal windows: ' || st::text;
  assert st->'skipped' = '[]'::jsonb, 'nothing skipped';

  -- skip on / replay / off
  st := public.pf_reminder_skip_set(o, 'lunch', day, true);
  st := public.pf_reminder_skip_set(o, 'lunch', day, true);
  st := public.pf_reminder_skip_set(o, 'breakfast', day, true);
  assert st->'skipped' = '["breakfast", "lunch"]'::jsonb, 'skips ordered by meal: ' || st::text;
  st := public.pf_reminder_skip_set(o, 'breakfast', day, false);
  assert st->'skipped' = '["lunch"]'::jsonb, 'skip removed';
  begin
    perform public.pf_reminder_skip_set(o, 'snack', day, true);
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'got ' || sqlerrm;
  end;

  -- settings: none stored -> null (the Worker applies defaults); write replaces
  assert public.pf_reminder_settings_read(o) is null, 'no settings yet';
  perform public.pf_reminder_settings_write(o, '{"cash_check": {"enabled": false, "time": "21:30"}}'::jsonb);
  perform public.pf_reminder_settings_write(o, '{"cash_check": {"enabled": true, "time": "21:00"}}'::jsonb);
  assert public.pf_reminder_settings_read(o)->'cash_check'->>'time' = '21:00', 'settings replaced';

  -- push claims: true only the first time
  assert public.pf_push_log_claim(o, 'meal:breakfast:2026-11-20') = true, 'first claim';
  assert public.pf_push_log_claim(o, 'meal:breakfast:2026-11-20') = false, 'second claim refused';
  assert public.pf_push_log_claim(o, 'meal:lunch:2026-11-20') = true, 'other key';

  -- period stats: local days, income/expense, categories, daily totals
  r := public.pf_period_stats(o, '2026-11-19', '2026-11-20');
  assert r->>'expense' = '270000', 'expense: ' || r::text;
  assert r->>'income' = '2000000', 'income';
  assert jsonb_array_length(r->'daily') = 2, 'two local days';
  assert (select x->>'expense' from jsonb_array_elements(r->'daily') x where x->>'day' = '2026-11-20') = '220000', 'day total';
  assert (select x->>'amount' from jsonb_array_elements(r->'by_category') x where x->>'name' = 'Ăn uống') = '170000', 'food total';
  assert (r->'by_category'->0->>'name') = 'Ăn uống', 'largest first';
  r := public.pf_period_stats(o, '2026-11-21', '2026-11-21');
  assert r->>'expense' = '0' and r->'daily' = '[]'::jsonb and r->'by_category' = '[]'::jsonb, 'empty period';

  -- insights
  assert public.pf_insight_latest(o, 'WEEK') is null, 'no insight yet';
  ins := public.pf_insight_create(o, 'WEEK', '2026-11-16', '2026-11-22', '{"title": "T1", "numbers": {"expense": "1"}}'::jsonb);
  assert ins->>'title' = 'T1' and ins->>'period' = 'WEEK' and ins->>'period_start' = '2026-11-16', 'created: ' || ins::text;
  perform public.pf_insight_create(o, 'DAY', '2026-11-20', '2026-11-20', '{"title": "D1"}'::jsonb);
  perform public.pf_insight_create(o, 'WEEK', '2026-11-16', '2026-11-22', '{"title": "T2"}'::jsonb);
  assert public.pf_insight_latest(o, 'WEEK')->>'title' = 'T2', 'latest week';
  assert jsonb_array_length(public.pf_insight_list(o, null, 20)) = 3, 'list all';
  assert jsonb_array_length(public.pf_insight_list(o, 'WEEK', 1)) = 1, 'list limit';
  assert public.pf_insight_get(o, (ins->>'id')::uuid)->>'title' = 'T1', 'get by id';
  begin
    perform public.pf_insight_get(o, gen_random_uuid());
    raise exception 'expected NOT_FOUND';
  exception when others then assert sqlerrm = 'NOT_FOUND', 'got ' || sqlerrm;
  end;
  begin
    perform public.pf_insight_create(o, 'YEAR', '2026-01-01', '2026-12-31', '{}'::jsonb);
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'got ' || sqlerrm;
  end;
  -- another user id is refused
  begin
    perform public.pf_insight_list(gen_random_uuid(), null, 20);
    raise exception 'expected OWNER_NOT_BOUND';
  exception when others then assert sqlerrm = 'OWNER_NOT_BOUND', 'got ' || sqlerrm;
  end;
end $$;

reset role;
do $$ begin
  assert (select count(*) from public.pf_push_log) = 2, 'two claims stored';
  assert (select relrowsecurity from pg_class where oid = 'public.pf_insight'::regclass), 'RLS on pf_insight';
  assert (select relrowsecurity from pg_class where oid = 'public.pf_reminder_settings'::regclass), 'RLS on settings';
  assert (select relrowsecurity from pg_class where oid = 'public.pf_reminder_skip'::regclass), 'RLS on skips';
  assert (select relrowsecurity from pg_class where oid = 'public.pf_push_log'::regclass), 'RLS on push log';
end $$;

-- not callable by anon / authenticated, tables not readable
set role anon;
do $$ begin
  begin
    perform public.pf_push_log_claim('abababab-abab-abab-abab-abababababab', 'x');
    raise exception 'anon must not execute';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.pf_insight;
    raise exception 'anon must not read';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set role authenticated;
do $$ begin
  begin
    perform public.pf_period_stats('abababab-abab-abab-abab-abababababab', '2026-11-01', '2026-11-30');
    raise exception 'authenticated must not execute';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 006_reminders' as result;
