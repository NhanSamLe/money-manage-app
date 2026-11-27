-- Migration 007: bank links and idempotent inbound bank events. Fresh database, stubs + all migrations applied.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'bank@example.test', now());

set role service_role;

do $$
declare
  o constant uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  s constant uuid := '33333333-3333-3333-3333-333333333333';
  d constant uuid := '44444444-4444-4444-4444-444444444444';
  cid uuid := gen_random_uuid(); acc uuid; other uuid; cin uuid; cout uuid; r jsonb; links jsonb; bal bigint; n int;
begin
  perform public.pf_setup_reserve('ffffffff-ffff-ffff-ffff-ffffffffffff', now() + interval '10 min');
  perform public.pf_setup_record_invite('ffffffff-ffff-ffff-ffff-ffffffffffff', o);
  perform public.pf_setup_claim(o, 'Bank Owner');
  perform public.pf_device_register(o, s, d, 'Test');
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'BANK', 'institution', 'ACB', 'name', 'ACB 4567', 'opening_amount', '1000000', 'baseline_at', now())));
  select (x->>'id')::uuid into acc from jsonb_array_elements(public.pf_read_accounts(o)) x where x->>'name' = 'ACB 4567';
  select (x->>'id')::uuid into cin from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'type' = 'INCOME' limit 1;
  select (x->>'id')::uuid into cout from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'type' = 'EXPENSE' limit 1;

  -- link once, replay-safe, and one bank account cannot be linked to a second MoMa account
  r := public.pf_link_account(o, acc, 'SEPAY', 'ext-1', 'hash-aaa', '4567', 'NGUYEN VAN A', 'ACB', 1000000);
  assert (r->>'replayed')::boolean = false, 'first link';
  r := public.pf_link_account(o, acc, 'SEPAY', 'ext-1', 'hash-aaa', '4567', 'NGUYEN VAN A', 'ACB', 1000000);
  assert (r->>'replayed')::boolean = true, 'second link replays';
  assert public.pf_link_find('SEPAY', 'hash-aaa')->>'account_id' = acc::text, 'lookup by number hash';
  assert public.pf_link_find('SEPAY', 'unknown') is null, 'unknown number';

  -- money in: posted once, balance follows
  r := public.pf_ingest_bank_event('SEPAY', 'k1', 'hash-aaa', 'in', 500000, now(), 'LUONG THANG 11', cin, 1500000, '{}'::jsonb);
  assert r->>'status' = 'APPLIED', 'in applied: ' || r::text;
  r := public.pf_ingest_bank_event('SEPAY', 'k1', 'hash-aaa', 'in', 500000, now(), 'LUONG THANG 11', cin, 1500000, '{}'::jsonb);
  assert r->>'status' = 'DUPLICATE', 'same event is not posted twice';
  -- money out
  r := public.pf_ingest_bank_event('SEPAY', 'k2', 'hash-aaa', 'out', 120000, now() + interval '1 second', 'GRAB', cout, 1380000, '{}'::jsonb);
  assert r->>'status' = 'APPLIED', 'out applied';
  -- unknown account number is reported, never posted
  r := public.pf_ingest_bank_event('SEPAY', 'k3', 'hash-zzz', 'in', 1000, now(), 'X', cin, null, '{}'::jsonb);
  assert r->>'status' = 'UNMATCHED', 'unmatched';

  select (x->>'balance')::bigint into bal from jsonb_array_elements(public.pf_read_accounts(o)) x where x->>'id' = acc::text;
  assert bal = 1000000 + 500000 - 120000, 'ledger balance matches bank after in and out, got ' || bal;
  links := public.pf_read_account_links(o);
  assert (links->0->>'bank_balance')::bigint = 1380000, 'bank balance recorded';
  assert (links->0->>'ledger_balance')::bigint = 1380000, 'ledger equals bank';
end $$;

-- storage and ledger checks as the table owner
reset role;
do $$ begin
  assert (select count(*) from public.pf_inbound_event) = 2, 'exactly two events stored';
  assert coalesce((select sum(signed_amount::numeric) from public.pf_entry), 0) = 0, 'ledger stays balanced';
end $$;

-- not callable by anon
set role anon;
do $$ begin
  begin
    perform public.pf_ingest_bank_event('SEPAY', 'x', 'x', 'in', 1, now(), '', null, null, '{}'::jsonb);
    raise exception 'anon must not execute';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 005_bank_links' as result;
