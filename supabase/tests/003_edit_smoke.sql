-- Edit commands (migration 004): account update, annotate/reclassify, correct, profile. Runs after 001/002.
\set ON_ERROR_STOP on
\ir _helpers.sql

do $$
declare
  o constant uuid := '11111111-1111-1111-1111-111111111111';
  main_ uuid := pg_temp.acc('Main'); cash uuid := pg_temp.acc('Cash');
  food uuid := pg_temp.cat('Ăn uống'); transport uuid := pg_temp.cat('Di chuyển');
  r jsonb; tx uuid; v int; tx2 uuid; before_bal bigint; jcount int; spend jsonb; acc_ver int; prof int; shop uuid;
begin
  -- ---- reclassify keeps money in place and history intact
  before_bal := pg_temp.bal('Main');
  r := pg_temp.cmd('TX_CREATE', jsonb_build_object('kind', 'EXPENSE', 'account_id', main_, 'amount', '120000', 'effective_at', '2026-11-27T04:00:00Z', 'category_id', food, 'merchant', 'Quán A'));
  tx := (r->>'tx_id')::uuid;
  select version into v from public.pf_tx where id = tx;
  perform pg_temp.cmd('TX_ANNOTATE', jsonb_build_object('tx_id', tx, 'expected_version', v, 'category_id', transport, 'note', 'đi grab'));
  assert pg_temp.bal('Main') = before_bal - 120000, 'reclassification does not move cash';
  assert (select count(*) from public.pf_journal where tx_id = tx) = 3, 'original + reversal + replacement journals';
  assert (select category_id from public.pf_tx where id = tx) = transport and (select note from public.pf_tx where id = tx) = 'đi grab', 'tx projection updated';
  select jsonb_agg(x) into spend from jsonb_array_elements(public.pf_read_dashboard('11111111-1111-1111-1111-111111111111', '2026-10-31T17:00:00Z', '2026-11-30T17:00:00Z')->'expense_by_category') x where x->>'name' = 'Di chuyển';
  assert (spend->0->>'amount')::bigint = 120000, 'spend moved to the new category';
  perform pg_temp.expect_error('VERSION_CONFLICT', 'TX_ANNOTATE', jsonb_build_object('tx_id', tx, 'expected_version', v, 'note', 'stale'));
  perform pg_temp.expect_error('CATEGORY_MISMATCH', 'TX_ANNOTATE', jsonb_build_object('tx_id', tx, 'expected_version', v + 1, 'category_id', pg_temp.cat('Lương')));

  -- note-only edit adds no journal
  select version into v from public.pf_tx where id = tx;
  perform pg_temp.cmd('TX_ANNOTATE', jsonb_build_object('tx_id', tx, 'expected_version', v, 'merchant', 'Grab'));
  assert (select count(*) from public.pf_journal where tx_id = tx) = 3, 'note/merchant edit posts nothing';

  -- reversing after reclassification nets everything to zero
  select version into v from public.pf_tx where id = tx;
  perform pg_temp.cmd('TX_REVERSE', jsonb_build_object('tx_id', tx, 'reason', 'hủy', 'expected_version', v));
  assert pg_temp.bal('Main') = before_bal, 'reversal after reclassification restores cash';
  assert coalesce((select sum(e.signed_amount::numeric) from public.pf_entry e join public.pf_journal j on j.id = e.journal_id
                   join public.pf_ledger_account a on a.id = e.ledger_account_id where j.tx_id = tx and a.class = 'EXPENSE'), 0) = 0, 'no expense left from the voided tx';

  -- ---- correct: old voided, new linked, balances reflect the new amount only
  before_bal := pg_temp.bal('Main');
  r := pg_temp.cmd('TX_CREATE', jsonb_build_object('kind', 'EXPENSE', 'account_id', main_, 'amount', '50000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', food));
  tx := (r->>'tx_id')::uuid;
  select version into v from public.pf_tx where id = tx;
  r := pg_temp.cmd('TX_CORRECT', jsonb_build_object('tx_id', tx, 'reason', 'sai số tiền', 'expected_version', v,
        'replacement', jsonb_build_object('kind', 'EXPENSE', 'account_id', main_, 'amount', '55000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', food)));
  tx2 := (r->>'tx_id')::uuid;
  assert (select status from public.pf_tx where id = tx) = 'VOID', 'old tx voided';
  assert (select related_tx_id from public.pf_tx where id = tx2) = tx, 'replacement links to the original';
  assert pg_temp.bal('Main') = before_bal - 55000, 'only the corrected amount remains';

  -- ---- account update
  select version into acc_ver from public.pf_account where id = cash;
  perform pg_temp.cmd('ACCOUNT_UPDATE', jsonb_build_object('account_id', cash, 'expected_version', acc_ver, 'name', 'Ví tiền mặt'));
  assert pg_temp.acc('Ví tiền mặt') = cash, 'rename visible in reads';
  select version into acc_ver from public.pf_account where id = cash;
  perform pg_temp.cmd('ACCOUNT_UPDATE', jsonb_build_object('account_id', cash, 'expected_version', acc_ver, 'archived', true));
  perform pg_temp.expect_error('ACCOUNT_ARCHIVED', 'TX_CREATE', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '1000', 'effective_at', '2026-11-27T05:00:00Z', 'category_id', food));
  assert pg_temp.acc('Ví tiền mặt') is null, 'archived accounts are hidden from the list';

  -- ---- profile
  select version into prof from public.pf_owner where user_id = o;
  perform pg_temp.cmd('PROFILE_UPDATE', jsonb_build_object('expected_version', prof, 'display_name', 'Sâm'));
  perform pg_temp.expect_error('VERSION_CONFLICT', 'PROFILE_UPDATE', jsonb_build_object('expected_version', prof, 'display_name', 'X'));
  assert (public.pf_read_profile(o)->>'display_name') = 'Sâm', 'profile updated';

  -- ---- invariants
  assert (select coalesce(sum(signed_amount::numeric), 0) from public.pf_entry) = 0, 'ledger sums to zero after edits';
  assert not exists (select 1 from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted group by e.journal_id having sum(e.signed_amount::numeric) <> 0), 'every journal balances';
end $$;

select 'OK: edit smoke checks passed' as result;
