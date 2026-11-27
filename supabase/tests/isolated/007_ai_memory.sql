-- Migration 009: transaction source + assistant memory (upsert/reinforce, relevant, list, delete, decay, learning
-- from corrections / undo / kept transactions, reflection stats). Fresh database, stubs + all migrations applied.
\set ON_ERROR_STOP on

insert into auth.users(id, email, email_confirmed_at) values
  ('cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd', 'memory@example.test', now());

-- normalisation (same rules as normalizeKey in the Worker)
do $$ begin
  assert pf_private.ai_norm('  Nước ĐẬU, 15k!! ') = 'nuoc dau 15k', 'norm: ' || pf_private.ai_norm('  Nước ĐẬU, 15k!! ');
  assert pf_private.ai_norm('Cà phê sữa đá') = 'ca phe sua da', 'norm 2';
  assert pf_private.ai_norm(normalize('Phở bò', NFD)) = 'pho bo', 'NFD input';
end $$;

-- The main scenario runs as the migration owner so it can also inspect pf_ai_memory directly (service_role only
-- has the RPCs; checked at the end).
do $$
declare
  o constant uuid := 'cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd';
  s constant uuid := '33333333-3333-3333-3333-333333333333';
  d constant uuid := '44444444-4444-4444-4444-444444444444';
  cid uuid; cash uuid; food uuid; move uuid; shop uuid; r jsonb; m jsonb; tx uuid; tx2 uuid; n int; st jsonb; w numeric;
begin
  perform public.pf_setup_reserve('ffffffff-ffff-ffff-ffff-ffffffffffff', now() + interval '10 min');
  perform public.pf_setup_record_invite('ffffffff-ffff-ffff-ffff-ffffffffffff', o);
  perform public.pf_setup_claim(o, 'Memory Owner');
  perform public.pf_device_register(o, s, d, 'Test');

  -- ---------------------------------------------------------------- source
  cid := gen_random_uuid();
  perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'ACCOUNT_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'CASH', 'institution', 'Ví', 'name', 'Tiền mặt', 'opening_amount', '5000000', 'baseline_at', '2026-11-01T00:00:00Z')));
  select (x->>'id')::uuid into cash from jsonb_array_elements(public.pf_read_accounts(o)) x where x->>'name' = 'Tiền mặt';
  select (x->>'id')::uuid into food from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Ăn uống';
  select (x->>'id')::uuid into move from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Di chuyển';
  select (x->>'id')::uuid into shop from jsonb_array_elements(public.pf_read_categories(o)) x where x->>'name' = 'Mua sắm';
  assert shop is not null and food is not null and move is not null, 'seeded categories';
  assert (select source from public.pf_tx where owner_id = o and kind = 'OPENING') = 'SYSTEM', 'opening balance is SYSTEM';

  -- manual default, AI from the payload, unknown / server-only sources refused
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '20000', 'category_id', food, 'note', 'bánh mì',
           'effective_at', (((now() at time zone 'Asia/Ho_Chi_Minh')::date - 1) + time '23:30') at time zone 'Asia/Ho_Chi_Minh')));
  assert (select source from public.pf_tx where id = (r->>'tx_id')::uuid) = 'MANUAL', 'default MANUAL';
  begin
    cid := gen_random_uuid();
    perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
          'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '1000', 'effective_at', now(), 'category_id', food, 'source', 'BANK')));
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'client BANK refused, got ' || sqlerrm;
  end;

  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '15000', 'effective_at', now(), 'category_id', shop, 'note', 'nước đậu', 'source', 'AI')));
  tx := (r->>'tx_id')::uuid;
  assert (select source from public.pf_tx where id = tx) = 'AI', 'AI source stored';
  assert (select x->>'source' from jsonb_array_elements(public.pf_read_transactions(o, 10)) x where (x->>'id')::uuid = tx) = 'AI', 'source in read';

  -- ---------------------------------------------------------------- correction: AI put "nước đậu" in Mua sắm, owner moves it to Ăn uống
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_ANNOTATE', 'schema_version', 1,
        'payload', jsonb_build_object('tx_id', tx, 'expected_version', 2, 'category_id', food, 'note', 'nước đậu')));
  r := public.pf_ai_observe_command(o, 'TX_ANNOTATE', jsonb_build_object('tx_id', tx, 'category_id', food), r);
  assert r->>'learned' = 'correction', 'correction learned: ' || r::text;
  select to_jsonb(x) into m from public.pf_ai_memory x where owner_id = o and kind = 'CATEGORY_RULE' and key = 'nuoc dau';
  assert m->'value'->>'category_id' = food::text and m->>'source' = 'correction' and (m->>'weight')::numeric = 0.7, 'rule: ' || m::text;
  assert m->'value'->>'phrase' = 'nước đậu' and m->'value'->>'category' = 'Ăn uống', 'rule value: ' || m::text;

  -- a manual transaction teaches nothing
  r := public.pf_ai_observe_command(o, 'TX_ANNOTATE', jsonb_build_object('tx_id', (select id from public.pf_tx where owner_id = o and note = 'bánh mì'), 'category_id', move), '{}'::jsonb);
  assert r->>'learned' is null, 'manual tx ignored';

  -- TX_CORRECT keeps the source on the replacement
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CORRECT', 'schema_version', 1,
        'payload', jsonb_build_object('tx_id', tx, 'reason', 'sai số tiền', 'expected_version', 3,
           'replacement', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '18000', 'effective_at', now(), 'category_id', move, 'note', 'nước đậu'))));
  tx2 := (r->>'tx_id')::uuid;
  assert (select source from public.pf_tx where id = tx2) = 'AI', 'replacement keeps AI source';
  r := public.pf_ai_observe_command(o, 'TX_CORRECT', '{}'::jsonb, r);
  assert r->>'learned' = 'correction', 'correct learned';
  assert (select value->>'category_id' from public.pf_ai_memory where owner_id = o and kind = 'CATEGORY_RULE' and key = 'nuoc dau') = move::text, 'rule moved';

  -- undo: reversing the AI transaction halves the rule that pointed to its category
  select weight into w from public.pf_ai_memory where owner_id = o and kind = 'CATEGORY_RULE' and key = 'nuoc dau';
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_REVERSE', 'schema_version', 1,
        'payload', jsonb_build_object('tx_id', tx2, 'reason', 'Hoàn tác từ Trợ lý AI', 'expected_version', 2)));
  r := public.pf_ai_observe_command(o, 'TX_REVERSE', jsonb_build_object('tx_id', tx2), r);
  assert r->>'learned' = 'undo', 'undo learned';
  m := (select to_jsonb(x) from public.pf_ai_memory x where owner_id = o and kind = 'CATEGORY_RULE' and key = 'nuoc dau');
  assert (m->>'weight')::numeric = round(w * 0.5, 3) and m->>'source' = 'undo', 'weakened: ' || m::text;
  -- a second undo drops it (0.35 -> 0.175 -> 0.0875 < 0.15)
  perform public.pf_ai_memory_upsert(o, 'CATEGORY_RULE', 'nuoc dau', jsonb_build_object('category_id', move), 'undo');
  perform public.pf_ai_memory_upsert(o, 'CATEGORY_RULE', 'nuoc dau', jsonb_build_object('category_id', move), 'undo');
  assert not exists (select 1 from public.pf_ai_memory where owner_id = o and key = 'nuoc dau'), 'dropped below threshold';
  assert public.pf_ai_memory_upsert(o, 'CATEGORY_RULE', 'khong co', jsonb_build_object('category_id', move), 'undo') is null, 'undo of nothing';

  -- ---------------------------------------------------------------- upsert / reinforce / conflict
  m := public.pf_ai_memory_upsert(o, 'ALIAS', 'NC Đậu', jsonb_build_object('from', 'nc đậu', 'to', 'nước đậu'), 'pattern');
  assert m->>'key' = 'nc dau' and (m->>'weight')::numeric = 0.4 and (m->>'hits')::int = 1, 'alias created: ' || m::text;
  m := public.pf_ai_memory_upsert(o, 'ALIAS', 'nc dau', jsonb_build_object('from', 'nc dau', 'to', 'Nước Đậu'), 'pattern');
  assert (m->>'weight')::numeric = 0.62 and (m->>'hits')::int = 2, 'reinforced 0.4*0.8+0.3: ' || m::text;
  m := public.pf_ai_memory_upsert(o, 'ALIAS', 'nc dau', jsonb_build_object('from', 'nc dau', 'to', 'nước dừa'), 'pattern');
  assert (m->>'weight')::numeric = 0.558 and m->'value'->>'to' = 'Nước Đậu', 'weak conflicting evidence lowers, keeps value: ' || m::text;
  m := public.pf_ai_memory_upsert(o, 'ALIAS', 'nc dau', jsonb_build_object('from', 'nc dau', 'to', 'nước dừa'), 'user');
  assert (m->>'weight')::numeric = 0.9 and m->'value'->>'to' = 'nước dừa' and m->>'source' = 'user', 'owner wins: ' || m::text;
  for n in 1..5 loop m := public.pf_ai_memory_upsert(o, 'ALIAS', 'nc dau', jsonb_build_object('to', 'nước dừa'), 'pattern'); end loop;
  assert (m->>'weight')::numeric <= 1 and m->>'source' = 'user', 'capped at 1, stays user';
  begin
    perform public.pf_ai_memory_upsert(o, 'SECRET', 'x', '{}'::jsonb, 'user');
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'bad kind, got ' || sqlerrm;
  end;
  begin
    perform public.pf_ai_memory_upsert(o, 'NOTE', '!!!', '{}'::jsonb, 'user');
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'empty key, got ' || sqlerrm;
  end;

  perform public.pf_ai_memory_upsert(o, 'CATEGORY_RULE', 'nuoc dua', jsonb_build_object('phrase', 'nước dừa', 'category_id', food, 'category', 'Ăn uống'), 'correction');
  perform public.pf_ai_memory_upsert(o, 'PERSON', 'nam', jsonb_build_object('name', 'Nam'), 'pattern');
  perform public.pf_ai_memory_upsert(o, 'NOTE', 'luon tra tien mat', jsonb_build_object('text', 'Luôn trả tiền mặt cho ăn sáng'), 'user');
  perform public.pf_ai_memory_upsert(o, 'HABIT', 'bua sang', jsonb_build_object('text', 'Ăn sáng khoảng 30.000 ₫'), 'reflection');
  n := public.pf_ai_memory_upsert_many(o, jsonb_build_array(
         jsonb_build_object('kind', 'PERSON', 'key', 'Hùng', 'value', jsonb_build_object('name', 'Hùng'), 'source', 'pattern'),
         jsonb_build_object('kind', 'PREFERENCE', 'key', 'ca phe momo', 'value', jsonb_build_object('text', 'Cà phê trả bằng MoMo'), 'source', 'pattern', 'weight', 0.5)));
  assert n = 2, 'upsert_many';

  -- ---------------------------------------------------------------- relevant
  r := public.pf_ai_memory_relevant(o, array['nc', 'dau', '15k'], 20);
  assert exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'ALIAS' and x->>'key' = 'nc dau'), 'alias matched: ' || r::text;
  assert exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'CATEGORY_RULE' and x->>'key' = 'nuoc dua'), 'rule via alias expansion: ' || r::text;
  assert not exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'PERSON'), 'no unrelated person';
  assert exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'NOTE') and exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'HABIT'),
    'general entries always included';
  assert (r->0->>'kind') in ('ALIAS', 'CATEGORY_RULE'), 'matched first';
  r := public.pf_ai_memory_relevant(o, array['Nam mượn 500k'], 20);
  assert exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'PERSON' and x->>'key' = 'nam'), 'person matched from a phrase';
  r := public.pf_ai_memory_relevant(o, null, 5);
  assert jsonb_array_length(r) >= 3, 'no terms: general only';

  -- ---------------------------------------------------------------- list / delete
  r := public.pf_ai_memory_list(o, null, 100);
  assert jsonb_array_length(r) = (select count(*) from public.pf_ai_memory where owner_id = o), 'list all';
  r := public.pf_ai_memory_list(o, 'PERSON', 100);
  assert jsonb_array_length(r) = 2, 'list by kind';
  r := public.pf_ai_memory_delete(o, (r->0->>'id')::uuid);
  assert r->>'deleted' = 'true', 'deleted';
  begin
    perform public.pf_ai_memory_delete(o, gen_random_uuid());
    raise exception 'expected NOT_FOUND';
  exception when others then assert sqlerrm = 'NOT_FOUND', 'got ' || sqlerrm;
  end;

  -- ---------------------------------------------------------------- replace (nightly HABIT set)
  n := public.pf_ai_memory_replace(o, 'HABIT', 'reflection', jsonb_build_array(
         jsonb_build_object('key', 'bua trua', 'value', jsonb_build_object('text', 'Ăn trưa khoảng 45.000 ₫'))));
  assert n = 1, 'replace count';
  assert not exists (select 1 from public.pf_ai_memory where owner_id = o and kind = 'HABIT' and key = 'bua sang'), 'stale habit removed';
  assert exists (select 1 from public.pf_ai_memory where owner_id = o and kind = 'HABIT' and key = 'bua trua'), 'new habit';
  begin
    perform public.pf_ai_memory_replace(o, 'NOTE', 'user', '[]'::jsonb);
    raise exception 'expected VALIDATION_FAILED';
  exception when others then assert sqlerrm = 'VALIDATION_FAILED', 'user set is never replaced, got ' || sqlerrm;
  end;

  -- ---------------------------------------------------------------- decay
  update public.pf_ai_memory set last_seen_at = now() - interval '40 days' where owner_id = o;
  update public.pf_ai_memory set weight = 0.16 where owner_id = o and kind = 'PERSON';
  st := public.pf_ai_memory_decay(o);
  assert (st->>'dropped')::int >= 1, 'weak stale dropped: ' || st::text;
  assert not exists (select 1 from public.pf_ai_memory where owner_id = o and kind = 'PERSON'), 'person dropped';
  assert (select weight from public.pf_ai_memory where owner_id = o and kind = 'NOTE') = 0.9, 'owner notes never decay';
  assert (select weight from public.pf_ai_memory where owner_id = o and kind = 'CATEGORY_RULE' and key = 'nuoc dua') = 0.63, 'decayed 10%';

  -- ---------------------------------------------------------------- positive feedback for kept AI transactions
  cid := gen_random_uuid();
  r := public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
        'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', '40000', 'effective_at', now() - interval '1 day', 'category_id', move, 'note', 'Grab đi làm', 'source', 'AI')));
  update public.pf_tx set created_at = now() - interval '30 hours' where id = (r->>'tx_id')::uuid;
  assert public.pf_ai_confirm_recent(o) = 1, 'one kept AI tx';
  m := (select to_jsonb(x) from public.pf_ai_memory x where owner_id = o and kind = 'CATEGORY_RULE' and key = 'grab di lam');
  assert m->>'source' = 'pattern' and m->'value'->>'category_id' = move::text, 'pattern rule: ' || coalesce(m::text, 'null');

  -- ---------------------------------------------------------------- reflection stats
  for n in 1..6 loop
    cid := gen_random_uuid();
    perform public.pf_execute_command(o, s, d, cid, md5(cid::text), jsonb_build_object('command_id', cid, 'command_type', 'TX_CREATE', 'schema_version', 1,
          'payload', jsonb_build_object('kind', 'EXPENSE', 'account_id', cash, 'amount', (30000 + n * 1000)::text, 'category_id', food, 'note', 'phở',
             'effective_at', (((now() at time zone 'Asia/Ho_Chi_Minh')::date - n) + time '07:30') at time zone 'Asia/Ho_Chi_Minh')));
  end loop;
  st := public.pf_ai_reflect_stats(o, 30);
  assert (st->>'days')::int = 30 and jsonb_array_length(st->'weekdays') = 7, 'shape: ' || st::text;
  assert (select sum((x->>'days')::int) from jsonb_array_elements(st->'weekdays') x) = 30, 'weekday days sum';
  m := (select x from jsonb_array_elements(st->'meals') x where x->>'meal' = 'breakfast');
  assert (m->>'days')::int = 6 and m->>'median' = '33000' and m->>'category' = 'Ăn uống' and m->>'account' = 'Tiền mặt', 'breakfast: ' || m::text;
  assert exists (select 1 from jsonb_array_elements(st->'keywords') x where x->>'key' = 'pho' and (x->>'count')::int = 6), 'keyword: ' || (st->'keywords')::text;
  assert exists (select 1 from jsonb_array_elements(st->'preferences') x where x->>'category' = 'Ăn uống' and x->>'daypart' = 'morning' and x->>'account' = 'Tiền mặt'),
    'preference: ' || (st->'preferences')::text;

  assert (select relrowsecurity from pg_class where oid = 'public.pf_ai_memory'::regclass), 'RLS on memory';
end $$;

-- the Worker role uses the RPCs only
set role service_role;
do $$ begin
  assert jsonb_array_length(public.pf_ai_memory_list('cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd', null, 10)) > 0, 'service_role lists';
  begin
    perform 1 from public.pf_ai_memory;
    raise exception 'service_role must not read the table directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- not callable by anon / authenticated, table not readable
set role anon;
do $$ begin
  begin
    perform public.pf_ai_memory_list('cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd', null, 10);
    raise exception 'anon must not execute';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.pf_ai_memory;
    raise exception 'anon must not read';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set role authenticated;
do $$ begin
  begin
    perform public.pf_ai_memory_upsert('cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd', 'NOTE', 'x y z', '{"text":"x"}'::jsonb, 'user');
    raise exception 'authenticated must not execute';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'ok 007_ai_memory' as result;
