-- Migration 010: pairing money moved between the owner's own accounts into one TRANSFER.
-- Fresh database, stubs + all migrations applied.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('abababab-abab-abab-abab-abababababab', 'pair@example.test', now());

set role service_role;

do $$
declare
  o constant uuid := 'abababab-abab-abab-abab-abababababab';
  s constant uuid := '33333333-3333-3333-3333-333333333333';
  d constant uuid := '44444444-4444-4444-4444-444444444444';
  cid uuid; tp uuid; momo uuid; cash uuid; vcb uuid; cin uuid; cout uuid; r jsonb; x jsonb; y jsonb; z jsonb;
  t0 timestamptz := date_trunc('minute', now()) - interval '2 hours';
  pid uuid; n int; h text[];
begin
  perform public.pf_setup_reserve('ffffffff-ffff-ffff-ffff-ffffffffffff', now() + interval '10 min');
  perform public.pf_setup_record_invite('ffffffff-ffff-ffff-ffff-ffffffffffff', o);
  perform public.pf_setup_claim(o, 'Lê Đào Nhân Sâm');
  perform public.pf_device_register(o, s, d, 'Test');
  -- accounts: TPBank (linked to SePay), MoMo wallet, cash, Vietcombank
  foreach r in array array[
      jsonb_build_object('kind', 'BANK', 'institution', 'TPBank', 'name', 'TPBank chính', 'last4', '1234', 'opening_amount', '10000000', 'baseline_at', t0 - interval '1 day'),
      jsonb_build_object('kind', 'WALLET', 'institution', 'MoMo', 'name', 'Ví MoMo', 'opening_amount', '200000', 'baseline_at', t0 - interval '1 day'),
      jsonb_build_object('kind', 'CASH', 'institution', 'Ví', 'name', 'Tiền mặt', 'opening_amount', '1000000', 'baseline_at', t0 - interval '1 day'),
      jsonb_build_object('kind', 'BANK', 'institution', 'Vietcombank', 'name', 'VCB', 'last4', '8888', 'opening_amount', '5000000', 'baseline_at', t0 - interval '1 day')] loop
    cid := gen_random_uuid();
    perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1, 'payload', r));
  end loop;
  select (a->>'id')::uuid into tp from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'name' = 'TPBank chính';
  select (a->>'id')::uuid into momo from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'name' = 'Ví MoMo';
  select (a->>'id')::uuid into cash from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'name' = 'Tiền mặt';
  select (a->>'id')::uuid into vcb from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'name' = 'VCB';
  select (c->>'id')::uuid into cin from jsonb_array_elements(public.pf_read_categories(o)) c where c->>'name' = 'Thu nhập khác';
  select (c->>'id')::uuid into cout from jsonb_array_elements(public.pf_read_categories(o)) c where c->>'name' = 'Khác';
  perform public.pf_link_account(o, tp, 'SEPAY', 'ext-tp', 'hash-tp', '1234', 'LE DAO NHAN SAM', 'TPBank', 10000000);

  -- ---------------------------------------------------------------- 1) bank out + notification in -> AUTO transfer
  r := public.pf_ingest_bank_event('SEPAY', 'tp-1', 'hash-tp', 'out', 500000, t0, 'MOMO NAP TIEN VI 0909', cout, 9500000, '{}'::jsonb);
  assert r->>'status' = 'APPLIED', 'bank out applied';
  x := public.pf_transfer_try_pair(o, (r->>'tx_id')::uuid);
  assert x->>'status' = 'NONE', 'nothing to pair yet: ' || x::text;
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '500000', 'effective_at', t0 + interval '40 seconds',
                                      'note', 'Nhận tiền từ TPBank', 'source', 'NOTIFICATION')));
  x := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert x->>'status' = 'AUTO', 'unique strong match pairs automatically: ' || x::text;
  pid := (x->>'pair_id')::uuid;
  assert (select status from public.pf_tx where id = (r->>'tx_id')::uuid) = 'VOID', 'bank leg reversed';
  assert (select status from public.pf_tx where id = (y->>'tx_id')::uuid) = 'VOID', 'notification leg reversed';
  assert (select kind::text || '|' || account_id || '|' || to_account_id || '|' || amount || '|' || source || '|' || effective_at
            from public.pf_tx where id = (x->>'transfer_tx_id')::uuid)
       = 'TRANSFER|' || tp || '|' || momo || '|500000|BANK|' || t0, 'one transfer out-account -> in-account at the earlier time, source of the out leg';
  assert (select note from public.pf_tx where id = (x->>'transfer_tx_id')::uuid) = 'MOMO NAP TIEN VI 0909 / Nhận tiền từ TPBank', 'note keeps both contents';
  assert (select hints from public.pf_transfer_pair where id = pid) @> array['keyword', 'account'], 'hints recorded';
  assert (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = tp::text) = 9500000, 'TPBank balance';
  assert (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = momo::text) = 700000, 'MoMo balance';
  -- no income / expense left from the move (the transfer has no P&L)
  r := public.pf_read_dashboard(o, t0 - interval '1 hour', t0 + interval '1 hour');
  assert (r->>'income')::bigint = 0 and (r->>'expense')::bigint = 0, 'no income/expense from an own transfer: ' || r::text;
  -- re-running is a no-op
  x := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert x->>'status' = 'NONE', 'void legs never pair again';
  r := public.pf_transfer_sweep(o, 48);
  assert (r->>'auto')::int = 0 and (r->>'suggested')::int = 0, 'sweep idempotent: ' || r::text;
  r := public.pf_transfer_pair_for_tx(o, (select transfer_tx from public.pf_transfer_pair where id = pid));
  assert r->>'state' = 'AUTO' and (r->>'can_undo')::boolean and r->'out'->>'account_name' = 'TPBank chính', 'pair for transfer tx';

  -- ---------------------------------------------------------------- 2) undo restores the two legs and never re-pairs them
  r := public.pf_transfer_undo(o, pid);
  assert r->>'state' = 'REJECTED', 'undo';
  assert (select kind::text || '|' || source || '|' || category_id from public.pf_tx where id = (r->>'out_tx_id')::uuid) = 'EXPENSE|BANK|' || cout, 'out leg restored';
  assert (select kind::text || '|' || source from public.pf_tx where id = (r->>'in_tx_id')::uuid) = 'UNKNOWN_CREDIT|NOTIFICATION', 'in leg restored';
  assert (select status from public.pf_tx where id = (r->>'voided_transfer_tx_id')::uuid) = 'VOID', 'transfer reversed';
  assert (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = momo::text) = 700000, 'MoMo balance after undo';
  x := public.pf_transfer_try_pair(o, (r->>'in_tx_id')::uuid);
  assert x->>'status' = 'NONE', 'restored legs are not paired again: ' || x::text;
  r := public.pf_transfer_sweep(o, 48);
  assert (r->>'auto')::int = 0 and (r->>'suggested')::int = 0, 'sweep leaves rejected legs: ' || r::text;
  begin
    perform public.pf_transfer_undo(o, pid);
    raise exception 'undo twice must fail';
  exception when others then assert sqlerrm = 'INVALID_STATE', 'undo twice: ' || sqlerrm;
  end;

  -- ---------------------------------------------------------------- 3) ambiguity -> SUGGESTED, ledger unchanged
  -- two money-in of 300.000 (MoMo, cash) for one bank money-out
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '300000', 'effective_at', t0 + interval '30 minutes', 'source', 'NOTIFICATION')));
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'INCOME', 'account_id', cash, 'amount', '300000', 'effective_at', t0 + interval '31 minutes', 'category_id', cin)));
  r := public.pf_ingest_bank_event('SEPAY', 'tp-2', 'hash-tp', 'out', 300000, t0 + interval '30 minutes 20 seconds', 'CK', cout, null, '{}'::jsonb);
  z := public.pf_transfer_try_pair(o, (r->>'tx_id')::uuid);
  assert z->>'status' = 'SUGGESTED' and (z->>'suggested')::int = 2, 'two candidates -> two suggestions: ' || z::text;
  assert (select status from public.pf_tx where id = (r->>'tx_id')::uuid) = 'POSTED', 'ledger untouched while suggested';
  n := jsonb_array_length(public.pf_transfer_suggestions(o));
  assert n = 2, 'two suggestions listed, got ' || n;
  z := public.pf_transfer_try_pair(o, (r->>'tx_id')::uuid);
  assert z->>'status' = 'NONE', 'suggestions are not duplicated';
  -- reject the cash one, accept the MoMo one
  select (e->>'id')::uuid into pid from jsonb_array_elements(public.pf_transfer_suggestions(o)) e where e->'in'->>'account_id' = cash::text;
  z := public.pf_transfer_decide(o, pid, false);
  assert z->>'state' = 'REJECTED', 'rejected';
  select (e->>'id')::uuid into pid from jsonb_array_elements(public.pf_transfer_suggestions(o)) e where e->'in'->>'account_id' = momo::text;
  z := public.pf_transfer_decide(o, pid, true);
  assert z->>'state' = 'CONFIRMED', 'accepted';
  assert (select kind::text || '|' || to_account_id from public.pf_tx where id = (z->>'transfer_tx_id')::uuid) = 'TRANSFER|' || momo, 'accepted -> transfer';
  assert jsonb_array_length(public.pf_transfer_suggestions(o)) = 0, 'nothing left to review';
  assert (select status from public.pf_tx where id = (y->>'tx_id')::uuid) = 'POSTED', 'the rejected cash income stays';
  x := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert x->>'status' = 'NONE', 'rejected pair never suggested again';
  begin
    perform public.pf_transfer_decide(o, pid, true);
    raise exception 'decide twice must fail';
  exception when others then assert sqlerrm = 'INVALID_STATE', 'decide twice: ' || sqlerrm;
  end;

  -- ---------------------------------------------------------------- 4) weak match (8 minutes, no hint) -> SUGGESTED
  r := public.pf_ingest_bank_event('SEPAY', 'tp-3', 'hash-tp', 'out', 123000, t0 + interval '60 minutes', 'THANH TOAN', cout, null, '{}'::jsonb);
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', vcb, 'amount', '123000', 'effective_at', t0 + interval '68 minutes', 'source', 'NOTIFICATION', 'note', 'GD nhan')));
  z := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert z->>'status' = 'SUGGESTED', 'weak match only suggested: ' || z::text;
  assert (select score from public.pf_transfer_pair where in_tx = (y->>'tx_id')::uuid) = 10, 'weak score';

  -- ---------------------------------------------------------------- 5) weak time + owner name hint -> AUTO
  r := public.pf_ingest_bank_event('SEPAY', 'tp-4', 'hash-tp', 'out', 777000, t0 + interval '90 minutes', 'LE DAO NHAN SAM CHUYEN KHOAN', cout, null, '{}'::jsonb);
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', vcb, 'amount', '777000', 'effective_at', t0 + interval '100 minutes', 'source', 'NOTIFICATION')));
  z := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert z->>'status' = 'AUTO', 'name hint makes a 10 minute match strong: ' || z::text;
  h := (select hints from public.pf_transfer_pair where id = (z->>'pair_id')::uuid);
  assert h = array['owner_name'], 'owner name hint (diacritic-insensitive): ' || h::text;
  assert (select score from public.pf_transfer_pair where id = (z->>'pair_id')::uuid) = 35, 'weak time + one hint';

  -- ---------------------------------------------------------------- 6) never: same account, different amount, > 15 min, both manual, debt-linked
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', tp, 'amount', '50000', 'effective_at', t0 + interval '110 minutes', 'source', 'NOTIFICATION')));
  r := public.pf_ingest_bank_event('SEPAY', 'tp-5', 'hash-tp', 'out', 50000, t0 + interval '110 minutes', 'momo', cout, null, '{}'::jsonb);
  assert public.pf_transfer_try_pair(o, (r->>'tx_id')::uuid)->>'status' = 'NONE', 'same account never pairs';
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '50001', 'effective_at', t0 + interval '110 minutes', 'source', 'NOTIFICATION')));
  assert public.pf_transfer_try_pair(o, (x->>'tx_id')::uuid)->>'status' = 'NONE', 'amount must match exactly';
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '50000', 'effective_at', t0 + interval '126 minutes', 'source', 'NOTIFICATION')));
  assert public.pf_transfer_try_pair(o, (x->>'tx_id')::uuid)->>'status' = 'NONE', 'more than 15 minutes apart';
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '61000', 'effective_at', t0 + interval '115 minutes', 'category_id', cout)));
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'INCOME', 'account_id', momo, 'amount', '61000', 'effective_at', t0 + interval '115 minutes', 'category_id', cin, 'note', 'momo')));
  assert public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid)->>'status' = 'NONE', 'two manual legs are left alone';

  -- ---------------------------------------------------------------- 7) same bank reference -> certain, even 3 hours apart
  -- SePay stores the referenceCode with the event; the bank content itself does not show it.
  r := public.pf_ingest_bank_event('SEPAY', 'tp-ref', 'hash-tp', 'out', 2500000, t0 + interval '130 minutes', 'THANH TOAN HD', cout, null,
         '{"source": "webhook", "reference": "FT26332327719412"}'::jsonb);
  -- a weaker same-amount candidate 10 minutes later is only suggested
  cid := gen_random_uuid();
  x := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'INCOME', 'account_id', cash, 'amount', '2500000', 'effective_at', t0 + interval '140 minutes', 'category_id', cin)));
  z := public.pf_transfer_try_pair(o, (x->>'tx_id')::uuid);
  assert z->>'status' = 'SUGGESTED', 'weak cash candidate suggested: ' || z::text;
  -- MoMo notification 3 hours later with the exact real text
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '2500000', 'effective_at', t0 + interval '310 minutes',
                                      'note', 'LE DAO NHAN SAM chuyen FT26332327719412', 'source', 'NOTIFICATION')));
  z := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert z->>'status' = 'AUTO', 'same reference pairs automatically: ' || z::text;
  assert (select kind::text || '|' || account_id || '|' || to_account_id || '|' || effective_at from public.pf_tx where id = (z->>'transfer_tx_id')::uuid)
       = 'TRANSFER|' || tp || '|' || momo || '|' || (t0 + interval '130 minutes'), 'transfer TPBank -> MoMo at the bank time';
  assert (select score from public.pf_transfer_pair where id = (z->>'pair_id')::uuid) = 100, 'certain score';
  assert (select hints from public.pf_transfer_pair where id = (z->>'pair_id')::uuid) @> array['reference', 'owner_name'], 'reference hint';
  assert not exists (select 1 from jsonb_array_elements(public.pf_transfer_suggestions(o)) e where e->'in'->>'tx_id' = x->>'tx_id'), 'stale cash suggestion hidden';
  assert (select status from public.pf_tx where id = (x->>'tx_id')::uuid) = 'POSTED', 'cash income kept';
  -- without a shared reference, 3 hours apart never pairs
  r := public.pf_ingest_bank_event('SEPAY', 'tp-ref2', 'hash-tp', 'out', 2600000, t0 + interval '130 minutes', 'CHUYEN TIEN', cout, null,
         '{"reference": "FT26332327719999"}'::jsonb);
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '2600000', 'effective_at', t0 + interval '310 minutes',
                                      'note', 'LE DAO NHAN SAM chuyen FT26332327710000', 'source', 'NOTIFICATION')));
  assert public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid)->>'status' = 'NONE', 'different references 3 hours apart';

  -- ---------------------------------------------------------------- 8) one leg only: money into VCB from the owner's MoMo
  -- MoMo never notifies money out; the VCB notification names the owner and MoMo.
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', vcb, 'amount', '4000', 'effective_at', t0 - interval '30 minutes',
          'note', '+4,000 VND ... Ref 159036437923-LE DAO NHAN SAM chuyen tien qua MoMo-CHUYEN TIEN-...', 'source', 'NOTIFICATION')));
  assert public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid)->>'status' = 'NONE', 'no out-leg: nothing at hook time';
  -- money out of TPBank to the owner's MoMo wallet; the MoMo side has not arrived
  r := public.pf_ingest_bank_event('SEPAY', 'tp-momo', 'hash-tp', 'out', 150000, t0 - interval '40 minutes', 'MOMO 0909123456', cout, null, '{}'::jsonb);
  assert public.pf_transfer_try_pair(o, (r->>'tx_id')::uuid)->>'status' = 'NONE', 'no in-leg yet';
  x := public.pf_transfer_sweep(o, 48);
  assert (x->>'failed')::int = 0, 'sweep without failures: ' || x::text;
  -- VCB money-in -> transfer MoMo -> VCB
  z := (select to_jsonb(p) from public.pf_transfer_pair p where p.in_tx = (y->>'tx_id')::uuid);
  assert z->>'state' = 'AUTO' and z->>'out_tx' is null and z->>'synth_account' = momo::text, 'one-leg pair: ' || z::text;
  assert (select kind::text || '|' || account_id || '|' || to_account_id || '|' || amount || '|' || source from public.pf_tx where id = (z->>'transfer_tx')::uuid)
       = 'TRANSFER|' || momo || '|' || vcb || '|4000|NOTIFICATION', 'transfer from the owner''s MoMo into VCB';
  assert (select status from public.pf_tx where id = (y->>'tx_id')::uuid) = 'VOID', 'income reversed';
  x := public.pf_transfer_pair_for_tx(o, (z->>'transfer_tx')::uuid);
  assert x->'synth_account'->>'account_name' = 'Ví MoMo' and x->'out' = 'null'::jsonb and (x->>'can_undo')::boolean, 'pair for a one-leg transfer: ' || x::text;
  -- undo: the income comes back alone and stays alone
  x := public.pf_transfer_undo(o, (z->>'id')::uuid);
  assert x->>'out_tx_id' is null and (select kind::text || '|' || status from public.pf_tx where id = (x->>'in_tx_id')::uuid) = 'UNKNOWN_CREDIT|POSTED', 'undo one-leg: ' || x::text;
  assert (select status from public.pf_tx where id = (z->>'transfer_tx')::uuid) = 'VOID', 'one-leg transfer reversed';
  x := public.pf_transfer_sweep(o, 48);
  assert not exists (select 1 from public.pf_transfer_pair p where p.in_tx = (select id from public.pf_tx t where t.amount = 4000 and t.status = 'POSTED' and t.kind = 'UNKNOWN_CREDIT')),
    'the restored income is not converted again';

  -- TPBank money-out to MoMo -> transfer TPBank -> MoMo; the late MoMo notification is absorbed, not counted twice
  z := (select to_jsonb(p) from public.pf_transfer_pair p where p.out_tx = (r->>'tx_id')::uuid);
  assert z->>'in_tx' is null and z->>'synth_account' = momo::text, 'out one-leg pair: ' || z::text;
  assert (select kind::text || '|' || account_id || '|' || to_account_id from public.pf_tx where id = (z->>'transfer_tx')::uuid)
       = 'TRANSFER|' || tp || '|' || momo, 'transfer TPBank -> MoMo';
  n := (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = momo::text);
  cid := gen_random_uuid();
  y := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'UNKNOWN_CREDIT', 'account_id', momo, 'amount', '150000', 'effective_at', t0 - interval '36 minutes',
          'note', 'Nhan tien tu TPBank', 'source', 'NOTIFICATION')));
  x := public.pf_transfer_try_pair(o, (y->>'tx_id')::uuid);
  assert x->>'status' = 'ABSORBED' and x->>'pair_id' = z->>'id', 'late MoMo leg absorbed: ' || x::text;
  assert (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = momo::text) = n, 'MoMo counted once';
  assert (select in_tx from public.pf_transfer_pair where id = (z->>'id')::uuid) = (y->>'tx_id')::uuid, 'pair now has both legs';
  assert (select note from public.pf_tx where id = (z->>'transfer_tx')::uuid) = 'MOMO 0909123456 / Nhan tien tu TPBank', 'note gains the late text';
  -- undo after absorb restores both original legs
  x := public.pf_transfer_undo(o, (z->>'id')::uuid);
  assert x->>'out_tx_id' is not null and x->>'in_tx_id' is not null, 'both legs restored: ' || x::text;
  assert (select (a->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts(o)) a where a->>'id' = momo::text) = n, 'MoMo still counted once';
  x := public.pf_transfer_sweep(o, 48);
  assert (x->>'auto')::int = 0 and (x->>'failed')::int = 0, 'nothing re-converted after undo: ' || x::text;
end $$;

reset role;
do $$ begin
  assert pf_private.transfer_score(60, '{}') = 50 and pf_private.transfer_score(600, '{keyword}') = 35
     and pf_private.transfer_score(600, '{}') = 10 and pf_private.transfer_score(60, '{keyword,owner_name,account}') = 100, 'score scale';
  assert pf_private.transfer_mentions(' chuyen tu tk 0123451234 ', (select id from public.pf_account where name = 'TPBank chính')), 'last4 at the end of a number';
  assert not pf_private.transfer_mentions(' ma gd 12345 ', (select id from public.pf_account where name = 'TPBank chính')), 'last4 inside a number is not a hint';
  assert pf_private.transfer_mentions(' nap tu vietcombank ', (select id from public.pf_account where name = 'VCB')), 'bank name';
  assert coalesce((select sum(signed_amount::numeric) from public.pf_entry), 0) = 0, 'ledger stays balanced';
  assert not exists (select j.id from public.pf_journal j join public.pf_entry e on e.journal_id = j.id group by j.id having sum(e.signed_amount::numeric) <> 0), 'every journal balanced';
  assert (select count(*) from public.pf_audit where action = 'TRANSFER_PAIR' and actor = 'system')
       = (select count(*) from public.pf_transfer_pair where transfer_tx is not null), 'system audit per conversion';
  assert (select count(*) from public.pf_audit where action = 'TRANSFER_PAIR_ABSORB') = 1, 'absorb audited';
  assert pf_private.transfer_own_counterpart('abababab-abab-abab-abab-abababababab',
           (select t from public.pf_tx t where t.amount = 4000 and t.status = 'POSTED')) = (select id from public.pf_account where name = 'Ví MoMo'), 'name + MoMo counterpart';
  assert pf_private.transfer_own_counterpart('abababab-abab-abab-abab-abababababab',
           (select t from public.pf_tx t where t.note = 'THANH TOAN' and t.status = 'POSTED' limit 1)) is null, 'plain payment has no counterpart';
  assert pf_private.transfer_refs((select id from public.pf_tx where note = 'LE DAO NHAN SAM chuyen FT26332327719412')) = array['FT26332327719412'], 'reference from the note';
  assert pf_private.transfer_refs((select tx_id from public.pf_inbound_event where external_id = 'tp-ref')) = array['FT26332327719412'], 'reference from the bank event';
  assert pf_private.transfer_refs((select id from public.pf_tx where note = 'THANH TOAN' and kind = 'EXPENSE' limit 1)) = '{}', 'no reference in plain words';
end $$;

-- direct writes and anon calls are refused
set role service_role;
do $$ begin
  begin
    insert into public.pf_transfer_pair(owner_id, out_tx, in_tx, state) select owner_id, id, id, 'SUGGESTED' from public.pf_tx limit 1;
    raise exception 'service role must not write pairs directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set role anon;
do $$ begin
  begin
    perform public.pf_transfer_suggestions('abababab-abab-abab-abab-abababababab');
    raise exception 'anon must not execute';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 008_transfer_pairing' as result;
