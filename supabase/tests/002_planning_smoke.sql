-- Debts, goals, budgets, categories, recurring (migration 003). Runs after 001 on the same database (owner already bound).
\set ON_ERROR_STOP on

create or replace function pg_temp.cmd(p_type text, p_payload jsonb) returns jsonb language plpgsql as $$
declare id uuid := gen_random_uuid();
begin
  return public.pf_execute_command('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444',
    id, md5(id::text), jsonb_build_object('command_id', id, 'command_type', p_type, 'schema_version', 1, 'payload', p_payload));
end $$;

create or replace function pg_temp.expect_error(p_code text, p_type text, p_payload jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.cmd(p_type, p_payload);
  raise exception 'expected %', p_code;
exception when others then
  if sqlerrm <> p_code then raise exception 'wanted %, got %', p_code, sqlerrm; end if;
end $$;

create or replace function pg_temp.acc(p_name text) returns uuid language sql as $$
  select (x->>'id')::uuid from jsonb_array_elements(public.pf_read_accounts('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;
create or replace function pg_temp.bal(p_name text) returns bigint language sql as $$
  select (x->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;
create or replace function pg_temp.cat(p_name text) returns uuid language sql as $$
  select (x->>'id')::uuid from jsonb_array_elements(public.pf_read_categories('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;

do $$
declare
  o constant uuid := '11111111-1111-1111-1111-111111111111';
  main_ uuid := pg_temp.acc('Main'); cash uuid := pg_temp.acc('Cash');
  main_before bigint := pg_temp.bal('Main'); cash_before bigint := pg_temp.bal('Cash');
  c uuid; d uuid; dv int; tx uuid; r jsonb; g uuid; gv int; dash jsonb; parent uuid; child uuid; rec uuid; occ jsonb; b jsonb;
  nw_before numeric; nw_after numeric;
begin
  -- ---- debts: lend 500.000, partial repayment with interest, guards, write-off
  c := (pg_temp.cmd('CONTACT_CREATE', jsonb_build_object('alias', 'Nam')))->>'contact_id';
  r := pg_temp.cmd('DEBT_CREATE', jsonb_build_object('direction', 'RECEIVABLE', 'contact_id', c, 'principal', '500000', 'originated_at', '2026-11-20T03:00:00Z', 'account_id', main_));
  d := (r->>'debt_id')::uuid;
  assert pg_temp.bal('Main') = main_before - 500000, 'lending reduces cash';
  assert ((public.pf_read_debts(o, '2026-11-27')->0)->>'remaining')::bigint = 500000, 'remaining = principal';

  select version into dv from public.pf_debt where id = d;
  r := pg_temp.cmd('DEBT_REPAY', jsonb_build_object('debt_id', d, 'account_id', main_, 'principal', '200000', 'interest', '10000', 'effective_at', '2026-11-25T03:00:00Z', 'expected_version', dv));
  tx := (r->>'tx_id')::uuid;
  assert r->>'state' = 'PARTIAL' and (r->>'remaining')::bigint = 300000, 'partial repayment';
  assert pg_temp.bal('Main') = main_before - 500000 + 210000, 'repayment brings principal + interest in';

  perform pg_temp.expect_error('VERSION_CONFLICT', 'DEBT_REPAY', jsonb_build_object('debt_id', d, 'account_id', main_, 'principal', '1000', 'effective_at', '2026-11-25T03:00:00Z', 'expected_version', dv));
  select version into dv from public.pf_debt where id = d;
  perform pg_temp.expect_error('INSUFFICIENT_PRINCIPAL', 'DEBT_REPAY', jsonb_build_object('debt_id', d, 'account_id', main_, 'principal', '300001', 'effective_at', '2026-11-25T03:00:00Z', 'expected_version', dv));
  perform pg_temp.expect_error('DEBT_LINKED', 'TX_REVERSE', jsonb_build_object('tx_id', tx, 'reason', 'x', 'expected_version', (select version from public.pf_tx where id = tx)));

  dash := public.pf_read_dashboard(o, '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z');
  assert (dash->>'income')::bigint = 20000000 + 10000, 'interest received is income';
  assert (dash->>'receivable')::bigint = 300000, 'receivable in dashboard';

  r := pg_temp.cmd('DEBT_WRITE_OFF', jsonb_build_object('debt_id', d, 'amount', '300000', 'reason', 'không đòi được', 'effective_at', '2026-11-26T03:00:00Z', 'expected_version', dv));
  assert r->>'state' = 'WRITTEN_OFF' and (r->>'remaining')::bigint = 0, 'full write-off';
  assert pg_temp.bal('Main') = main_before - 500000 + 210000, 'write-off moves no cash';
  assert (public.pf_read_dashboard(o, '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z')->>'expense')::bigint = 3300 + 300000, 'bad debt is an expense (BR-19); the earlier food purchase was reversed in test 001';

  -- historical payable: no cash movement, lowers net worth
  nw_before := (public.pf_read_dashboard(o, '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z')->>'net_worth')::numeric;
  r := pg_temp.cmd('DEBT_CREATE', jsonb_build_object('direction', 'PAYABLE', 'contact_id', c, 'principal', '1000000', 'originated_at', '2026-01-01T00:00:00Z', 'historical', true));
  nw_after := (public.pf_read_dashboard(o, '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z')->>'net_worth')::numeric;
  assert nw_after = nw_before - 1000000, 'payable lowers net worth';
  assert pg_temp.bal('Main') = main_before - 500000 + 210000, 'historical debt moves no cash';

  -- ---- goals: reservations never touch the ledger and cannot exceed available cash
  r := pg_temp.cmd('GOAL_CREATE', jsonb_build_object('name', 'Du lịch', 'target', '5000000'));
  g := (r->>'goal_id')::uuid;
  select version into gv from public.pf_goal where id = g;
  perform pg_temp.cmd('GOAL_ALLOCATE', jsonb_build_object('goal_id', g, 'account_id', cash, 'amount', '300000', 'expected_version', gv));
  select version into gv from public.pf_goal where id = g;
  perform pg_temp.expect_error('INSUFFICIENT_AVAILABLE', 'GOAL_ALLOCATE', jsonb_build_object('goal_id', g, 'account_id', cash, 'amount', (cash_before - 299999)::text, 'expected_version', gv));
  perform pg_temp.cmd('GOAL_RELEASE', jsonb_build_object('goal_id', g, 'account_id', cash, 'amount', '100000', 'expected_version', gv));
  select version into gv from public.pf_goal where id = g;
  perform pg_temp.expect_error('INSUFFICIENT_PRINCIPAL', 'GOAL_RELEASE', jsonb_build_object('goal_id', g, 'account_id', cash, 'amount', '200001', 'expected_version', gv));
  assert pg_temp.bal('Cash') = cash_before, 'allocation does not change the ledger balance';
  assert (public.pf_read_goals(o)->'goals'->0->>'allocated')::bigint = 200000, 'allocated progress';
  assert (select (x->>'available')::bigint from jsonb_array_elements(public.pf_read_goals(o)->'accounts') x where (x->>'account_id')::uuid = cash) = cash_before - 200000, 'available = balance - reserved';

  -- ---- budgets: spent comes from the ledger; updates need the current version
  perform pg_temp.cmd('TX_CREATE', jsonb_build_object('kind', 'EXPENSE', 'account_id', main_, 'amount', '65000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', pg_temp.cat('Ăn uống')));
  perform pg_temp.cmd('BUDGET_UPSERT', jsonb_build_object('month', '2026-11', 'limit', '1000000', 'carryover', false, 'category_id', pg_temp.cat('Ăn uống')));
  b := public.pf_read_budgets(o, '2026-11-15')->0;
  assert (b->>'spent')::bigint = 65000 and (b->>'remaining')::bigint = 935000, 'budget consumption from ledger';
  perform pg_temp.expect_error('VERSION_CONFLICT', 'BUDGET_UPSERT', jsonb_build_object('month', '2026-11', 'limit', '2000000', 'carryover', false, 'category_id', pg_temp.cat('Ăn uống')));
  perform pg_temp.cmd('BUDGET_UPSERT', jsonb_build_object('month', '2026-11', 'limit', '2000000', 'carryover', false, 'category_id', pg_temp.cat('Ăn uống'), 'expected_version', (b->>'version')::int));
  perform pg_temp.cmd('BUDGET_UPSERT', jsonb_build_object('month', '2026-12', 'limit', '1000000', 'carryover', true, 'category_id', pg_temp.cat('Ăn uống')));
  assert ((public.pf_read_budgets(o, '2026-12-01')->0)->>'carried')::bigint = 2000000 - 65000, 'carryover = previous unused budget';

  -- ---- categories: hierarchy without cycles, class never changes
  parent := (pg_temp.cmd('CATEGORY_UPSERT', jsonb_build_object('name', 'Cà phê', 'type', 'EXPENSE')))->>'category_id';
  child := (pg_temp.cmd('CATEGORY_UPSERT', jsonb_build_object('name', 'Cà phê sáng', 'type', 'EXPENSE', 'parent_id', parent)))->>'category_id';
  perform pg_temp.expect_error('VALIDATION_FAILED', 'CATEGORY_UPSERT', jsonb_build_object('name', 'Cà phê', 'type', 'EXPENSE', 'category_id', parent, 'parent_id', child, 'expected_version', 1));
  perform pg_temp.expect_error('CATEGORY_MISMATCH', 'CATEGORY_UPSERT', jsonb_build_object('name', 'Cà phê', 'type', 'INCOME', 'category_id', parent, 'expected_version', 1));

  -- ---- recurring: occurrences are generated, never auto-posted, matched once
  rec := (pg_temp.cmd('RECURRING_UPSERT', jsonb_build_object('name', 'Netflix', 'kind', 'EXPENSE', 'account_id', main_, 'amount', '70000', 'interval', 'MONTHLY',
          'next_date', '2026-11-28', 'enabled', true, 'category_id', pg_temp.cat('Giải trí'))))->>'recurring_id';
  assert public.pf_sync_occurrences(o, '2026-11-27') = 1, 'one occurrence due within the horizon';
  assert public.pf_sync_occurrences(o, '2026-11-27') = 0, 'sync is idempotent';
  occ := public.pf_read_recurring(o)->0->'expected'->0;
  tx := (pg_temp.cmd('TX_CREATE', jsonb_build_object('kind', 'EXPENSE', 'account_id', main_, 'amount', '70000', 'effective_at', '2026-11-28T01:00:00Z', 'category_id', pg_temp.cat('Giải trí'))))->>'tx_id';
  perform pg_temp.cmd('OCCURRENCE_MATCH', jsonb_build_object('occurrence_id', occ->>'id', 'tx_id', tx, 'expected_version', (occ->>'version')::int));
  perform pg_temp.expect_error('INVALID_STATE', 'OCCURRENCE_MATCH', jsonb_build_object('occurrence_id', occ->>'id', 'tx_id', tx, 'expected_version', 2));
end $$;

do $$
begin
  assert (select coalesce(sum(signed_amount::numeric), 0) from public.pf_entry) = 0, 'ledger still sums to zero after planning commands';
  assert not exists (select 1 from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted group by e.journal_id having sum(e.signed_amount::numeric) <> 0), 'every journal balances';
end $$;

select 'OK: planning smoke checks passed' as result;
