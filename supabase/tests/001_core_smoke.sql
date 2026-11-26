-- Core invariant checks for migrations 001 + 002. Run on a FRESH database that already has the
-- Supabase stubs (roles anon/authenticated/service_role, auth.users) and both migrations applied:
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/001_core_smoke.sql
-- Any failed ASSERT aborts the script with a non-zero exit code.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'owner@example.test', now()),
  ('99999999-9999-9999-9999-999999999999', 'intruder@example.test', now());

set role service_role;

-- 1. Setup: reserve -> invite -> claim; claim is replay-safe; a second identity is refused.
do $$
declare r jsonb;
begin
  perform public.pf_setup_reserve('22222222-2222-2222-2222-222222222222', now() + interval '10 min');
  perform public.pf_setup_record_invite('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');
  r := public.pf_setup_claim('11111111-1111-1111-1111-111111111111', 'Test');
  assert (r->>'replayed')::boolean = false, 'first claim must not be a replay';
  r := public.pf_setup_claim('11111111-1111-1111-1111-111111111111', 'Test');
  assert (r->>'replayed')::boolean = true, 'second claim by same owner must replay';
  begin
    perform public.pf_setup_claim('99999999-9999-9999-9999-999999999999', 'Intruder');
    raise exception 'expected SETUP_ALREADY_BOUND';
  exception when others then
    assert sqlerrm = 'SETUP_ALREADY_BOUND', 'intruder must be refused, got: ' || sqlerrm;
  end;
  assert public.pf_get_owner() = '11111111-1111-1111-1111-111111111111', 'owner binding';
end $$;

-- 2. Device, accounts, income/expense/transfer, idempotency, reversal.
do $$
declare
  o constant uuid := '11111111-1111-1111-1111-111111111111';
  s constant uuid := '33333333-3333-3333-3333-333333333333';
  d constant uuid := '44444444-4444-4444-4444-444444444444';
  a1 uuid; a2 uuid; food uuid; salary uuid; r jsonb; tx uuid; ver int; dash jsonb;
begin
  perform public.pf_device_register(o, s, d, 'Test device');

  r := public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555501', 'h01', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555501', 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'BANK', 'institution', 'VCB', 'name', 'Main', 'opening_amount', '10000000', 'baseline_at', '2026-11-01T00:00:00Z')));
  a1 := (r->>'account_id')::uuid;
  r := public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555502', 'h02', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555502', 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'CASH', 'institution', 'Wallet', 'name', 'Cash', 'opening_amount', '0', 'baseline_at', '2026-11-01T00:00:00Z')));
  a2 := (r->>'account_id')::uuid;

  select (x->>'id')::uuid into food from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Ăn uống';
  select (x->>'id')::uuid into salary from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Lương';

  -- expense 65.000 -> balance 9.935.000
  r := public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555503', 'h03', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555503', 'command_type', 'TX_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', a1, 'amount', '65000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', food)));
  tx := (r->>'tx_id')::uuid;
  assert (select (x->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) x where (x->>'id')::uuid = a1) = 9935000, 'balance after expense';

  -- idempotency: same command id + same hash replays; different hash is a conflict
  r := public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555503', 'h03', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555503', 'command_type', 'TX_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', a1, 'amount', '65000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', food)));
  assert r->>'status' = 'REPLAYED', 'replay status';
  assert (select count(*) from public.pf_tx where kind = 'EXPENSE') = 1, 'replay must not double-post';
  begin
    perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555503', 'DIFFERENT', jsonb_build_object(
      'command_id', '55555555-5555-5555-5555-555555555503', 'command_type', 'TX_CREATE', 'schema_version', 1, 'payload', '{}'::jsonb));
    raise exception 'expected DUPLICATE_KEY_MISMATCH';
  exception when others then
    assert sqlerrm = 'DUPLICATE_KEY_MISMATCH', 'hash mismatch must conflict, got: ' || sqlerrm;
  end;

  -- income + category/kind mismatch refused
  perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555504', 'h04', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555504', 'command_type', 'TX_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'INCOME', 'account_id', a1, 'amount', '20000000', 'effective_at', '2026-11-27T06:00:00Z', 'category_id', salary)));
  begin
    perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555505', 'h05', jsonb_build_object(
      'command_id', '55555555-5555-5555-5555-555555555505', 'command_type', 'TX_CREATE', 'schema_version', 1,
      'payload', jsonb_build_object('kind', 'INCOME', 'account_id', a1, 'amount', '1000', 'effective_at', '2026-11-27T06:00:00Z', 'category_id', food)));
    raise exception 'expected CATEGORY_MISMATCH';
  exception when others then
    assert sqlerrm = 'CATEGORY_MISMATCH', 'income into expense category must be refused, got: ' || sqlerrm;
  end;

  -- transfer with fee: principal to cash, fee is the only P&L effect
  perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555506', 'h06', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555506', 'command_type', 'TX_CREATE', 'schema_version', 1,
    'payload', jsonb_build_object('kind', 'TRANSFER', 'account_id', a1, 'to_account_id', a2, 'amount', '1000000', 'fee', '3300', 'effective_at', '2026-11-27T07:00:00Z')));
  assert (select (x->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) x where (x->>'id')::uuid = a2) = 1000000, 'cash received principal';
  assert (select (x->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) x where (x->>'id')::uuid = a1) = 9935000 + 20000000 - 1003300, 'bank paid principal + fee';

  -- dashboard: BR-15 transfer fee IS an expense (65.000 purchase + 3.300 fee); only SYS_ADJUSTMENT_* is excluded
  dash := public.pf_read_dashboard(o, '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z');
  assert (dash->>'income')::bigint = 20000000, 'dashboard income';
  assert (dash->>'expense')::bigint = 68300, 'dashboard expense includes the transfer fee';

  -- reversal restores the balance, keeps history, and cannot be repeated
  select version into ver from public.pf_tx where id = tx;
  perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555507', 'h07', jsonb_build_object(
    'command_id', '55555555-5555-5555-5555-555555555507', 'command_type', 'TX_REVERSE', 'schema_version', 1,
    'payload', jsonb_build_object('tx_id', tx, 'reason', 'test', 'expected_version', ver)));
  assert (select status from public.pf_tx where id = tx) = 'VOID', 'reversed tx is VOID';
  assert (select count(*) from public.pf_journal where tx_id = tx) = 2, 'original + reversal journals kept';
  begin
    select version into ver from public.pf_tx where id = tx;
    perform public.pf_execute_command(o, s, d, '55555555-5555-5555-5555-555555555508', 'h08', jsonb_build_object(
      'command_id', '55555555-5555-5555-5555-555555555508', 'command_type', 'TX_REVERSE', 'schema_version', 1,
      'payload', jsonb_build_object('tx_id', tx, 'reason', 'again', 'expected_version', ver)));
    raise exception 'expected INVALID_STATE';
  exception when others then
    assert sqlerrm = 'INVALID_STATE', 'double reversal must be refused, got: ' || sqlerrm;
  end;

  -- unknown owner is refused everywhere
  begin
    perform public.pf_read_accounts('99999999-9999-9999-9999-999999999999');
    raise exception 'expected OWNER_NOT_BOUND';
  exception when others then
    assert sqlerrm = 'OWNER_NOT_BOUND', 'non-owner read must be refused, got: ' || sqlerrm;
  end;
end $$;

-- 3. Direct DML on ledger tables is denied to the server role (only RPCs may write).
do $$
begin
  begin
    insert into public.pf_entry(journal_id, line_no, ledger_account_id, signed_amount) values (gen_random_uuid(), 1, gen_random_uuid(), 1);
    raise exception 'expected insufficient_privilege';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 4. anon / authenticated cannot call any RPC or read any table.
reset role;
set role anon;
do $$
begin
  begin
    perform public.pf_read_accounts('11111111-1111-1111-1111-111111111111');
    raise exception 'expected insufficient_privilege for anon rpc';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.pf_tx;
    raise exception 'expected insufficient_privilege for anon select';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 5. Journal invariants hold at table level (as table owner): posted data is immutable, all journals sum to zero.
do $$
begin
  assert (select coalesce(sum(signed_amount::numeric), 0) from public.pf_entry) = 0, 'all entries must sum to zero';
  assert not exists (select 1 from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
                     group by e.journal_id having sum(e.signed_amount::numeric) <> 0), 'every posted journal balances';
  begin
    update public.pf_entry set signed_amount = 1 where true;
    raise exception 'expected ENTRY_UPDATE_FORBIDDEN';
  exception when others then
    assert sqlerrm = 'ENTRY_UPDATE_FORBIDDEN', 'entry update must be blocked, got: ' || sqlerrm;
  end;
  begin
    update public.pf_journal set effective_at = now() where posted;
    raise exception 'expected JOURNAL_IMMUTABLE';
  exception when others then
    assert sqlerrm = 'JOURNAL_IMMUTABLE', 'posted journal must be immutable, got: ' || sqlerrm;
  end;
end $$;

select 'OK: core smoke checks passed' as result;
