-- MoMa migration 004: edit commands (ACCOUNT_UPDATE, TX_ANNOTATE, TX_CORRECT, PROFILE_UPDATE) + dispatcher.
-- Posted history stays immutable: edits that change money reverse the journal and post a replacement.
-- Decision D-006: TX_CORRECT voids the old transaction and creates a NEW linked one (related_tx_id); the spec's
-- "same transaction id" is only needed once source-event links exist (Gate 3).
begin;

create function pf_private.cmd_account_update(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare a public.pf_account; nm text;
begin
  select * into a from public.pf_account where id = (p->>'account_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if a.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  nm := coalesce(nullif(btrim(p->>'name'), ''), a.name);
  if length(nm) > 120 then perform pf_private.err('VALIDATION_FAILED'); end if;
  update public.pf_account set name = nm, archived = coalesce((p->>'archived')::boolean, archived),
         hidden = coalesce((p->>'hidden')::boolean, hidden), version = version + 1
   where id = a.id returning * into a;
  update public.pf_ledger_account set name = a.name where id = a.ledger_account_id;
  return jsonb_build_object('account_id', a.id, 'change_seq', pf_private.touch_change(p_owner, 'account', a.id, a.version));
end $$;

create function pf_private.cmd_tx_annotate(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; newcat public.pf_category; oldcat public.pf_category; lines jsonb; rj uuid; nj uuid; old_eff timestamptz; seq bigint;
begin
  if p ? 'splits' or p ? 'learn_rule' then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  select * into t from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if t.status <> 'POSTED' then perform pf_private.err('INVALID_STATE'); end if;
  if p ? 'contact_id' then
    perform 1 from public.pf_contact where id = (p->>'contact_id')::uuid and owner_id = p_owner;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
  end if;
  if p ? 'category_id' and (p->>'category_id')::uuid is distinct from t.category_id then
    -- Reclassification: only plain income/expense, same class; reverse + replacement keeps history.
    if t.kind not in ('INCOME', 'EXPENSE') then perform pf_private.err('INVALID_STATE'); end if;
    select * into newcat from public.pf_category where id = (p->>'category_id')::uuid and owner_id = p_owner and not archived;
    if not found or newcat.type <> t.kind::text then perform pf_private.err('CATEGORY_MISMATCH'); end if;
    select * into oldcat from public.pf_category where id = t.category_id;
    select effective_at into old_eff from public.pf_journal where id = t.current_journal_id;
    select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo để đổi danh mục') order by line_no)
      into lines from public.pf_entry where journal_id = t.current_journal_id;
    rj := pf_private.post_journal(p_owner, t.id, old_eff, 'REVERSAL', lines, t.current_journal_id);
    select jsonb_agg(jsonb_build_object('ledger_account_id', case when e.ledger_account_id = oldcat.ledger_account_id then newcat.ledger_account_id else e.ledger_account_id end,
                                        'signed_amount', e.signed_amount::text) order by e.line_no)
      into lines from public.pf_entry e where e.journal_id = t.current_journal_id;
    nj := pf_private.post_journal(p_owner, t.id, old_eff, 'REPLACEMENT', lines);
    update public.pf_tx set current_journal_id = nj, category_id = newcat.id where id = t.id;
  end if;
  update public.pf_tx set note = case when p ? 'note' then left(p->>'note', 1000) else note end,
         merchant = case when p ? 'merchant' then left(p->>'merchant', 120) else merchant end,
         contact_id = case when p ? 'contact_id' then (p->>'contact_id')::uuid else contact_id end,
         version = version + 1, updated_at = now()
   where id = t.id returning * into t;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe) values (p_owner, 'owner', 'TX_ANNOTATE', t.id, jsonb_build_object('reclassified', nj is not null));
  seq := pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
  return jsonb_build_object('tx_id', t.id, 'change_seq', seq);
end $$;

create function pf_private.cmd_tx_correct(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare rev jsonb; created jsonb;
begin
  rev := pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', p->>'tx_id', 'reason', p->>'reason', 'expected_version', (p->>'expected_version')::integer));
  created := pf_private.cmd_tx_create(p_owner, p->'replacement');
  update public.pf_tx set related_tx_id = (p->>'tx_id')::uuid where id = (created->>'tx_id')::uuid;
  return jsonb_build_object('tx_id', created->>'tx_id', 'voided_tx_id', p->>'tx_id', 'journal_id', created->>'journal_id', 'change_seq', created->>'change_seq');
end $$;

create function pf_private.cmd_profile_update(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare o public.pf_owner;
begin
  select * into o from public.pf_owner where user_id = p_owner for update;
  if o.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  update public.pf_owner set display_name = coalesce(left(btrim(p->>'display_name'), 80), display_name),
         wizard_step = coalesce(p->>'wizard_step', wizard_step), version = version + 1
   where user_id = p_owner returning * into o;
  return jsonb_build_object('user_id', o.user_id, 'version', o.version, 'change_seq', pf_private.touch_change(p_owner, 'profile', o.user_id, o.version));
end $$;

create or replace function public.pf_execute_command(p_owner uuid, p_session uuid, p_device uuid, p_command_id uuid, p_hash text, p_command jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.pf_command; ctype text := p_command->>'command_type'; payload jsonb := p_command->'payload'; res jsonb; d public.pf_device;
begin
  perform pf_private.assert_owner(p_owner);
  if p_device is not null then
    select * into d from public.pf_device where id = p_device and owner_id = p_owner;
    if not found or not d.active or d.revoked_at is not null or d.session_id is distinct from p_session then perform pf_private.err('DEVICE_REVOKED'); end if;
  end if;
  if (p_command->>'command_id')::uuid is distinct from p_command_id or (p_command->>'schema_version')::int <> 1 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_command(owner_id, command_id, request_hash) values (p_owner, p_command_id, p_hash) on conflict do nothing;
  select * into r from public.pf_command where owner_id = p_owner and command_id = p_command_id for update;
  if r.request_hash <> p_hash then perform pf_private.err('DUPLICATE_KEY_MISMATCH'); end if;
  if r.result is not null then return r.result || jsonb_build_object('status', 'REPLAYED'); end if;
  res := case ctype
    when 'ACCOUNT_CREATE'   then pf_private.cmd_account_create(p_owner, payload)
    when 'ACCOUNT_UPDATE'   then pf_private.cmd_account_update(p_owner, payload)
    when 'TX_CREATE'        then pf_private.cmd_tx_create(p_owner, payload)
    when 'TX_REVERSE'       then pf_private.cmd_tx_reverse(p_owner, payload)
    when 'TX_ANNOTATE'      then pf_private.cmd_tx_annotate(p_owner, payload)
    when 'TX_CORRECT'       then pf_private.cmd_tx_correct(p_owner, payload)
    when 'PROFILE_UPDATE'   then pf_private.cmd_profile_update(p_owner, payload)
    when 'CONTACT_CREATE'   then pf_private.cmd_contact_create(p_owner, payload)
    when 'CONTACT_UPDATE'   then pf_private.cmd_contact_update(p_owner, payload)
    when 'DEBT_CREATE'      then pf_private.cmd_debt_create(p_owner, payload)
    when 'DEBT_REPAY'       then pf_private.cmd_debt_repay(p_owner, payload)
    when 'DEBT_WRITE_OFF'   then pf_private.cmd_debt_write_off(p_owner, payload)
    when 'GOAL_CREATE'      then pf_private.cmd_goal_create(p_owner, payload)
    when 'GOAL_ALLOCATE'    then pf_private.cmd_goal_allocate(p_owner, payload)
    when 'GOAL_RELEASE'     then pf_private.cmd_goal_release(p_owner, payload)
    when 'BUDGET_UPSERT'    then pf_private.cmd_budget_upsert(p_owner, payload)
    when 'CATEGORY_UPSERT'  then pf_private.cmd_category_upsert(p_owner, payload)
    when 'RECURRING_UPSERT' then pf_private.cmd_recurring_upsert(p_owner, payload)
    when 'OCCURRENCE_MATCH' then pf_private.cmd_occurrence_match(p_owner, payload)
    else null end;
  if res is null then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  res := res || jsonb_build_object('status', 'COMMITTED');
  update public.pf_command set result = res where owner_id = p_owner and command_id = p_command_id;
  return res;
end $$;

-- Transactions list also needs the linked/related id and the merchant for display.
create or replace function public.pf_read_transactions(p_owner uuid, p_limit integer, p_before_at timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc, x.id desc) from (
    select t.id, t.kind, t.status, t.effective_at, t.amount::text as amount, t.fee::text as fee, t.account_id, t.to_account_id, t.category_id,
           t.merchant, t.note, t.version, t.related_tx_id, t.contact_id,
           exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id) or exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id) as debt_linked
    from public.pf_tx t
    where t.owner_id = p_owner and t.status in ('POSTED','VOID')
      and (p_before_at is null or (t.effective_at, t.id) < (p_before_at, p_before_id))
    order by t.effective_at desc, t.id desc limit lim) x), '[]'::jsonb);
end $$;

-- Categories need their version for optimistic updates (CATEGORY_UPSERT).
create or replace function public.pf_read_categories(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'type', type, 'name', name, 'icon', icon, 'parent_id', parent_id, 'version', version, 'system', name = 'Khác') order by type, name)
    from public.pf_category where owner_id = p_owner and not archived), '[]'::jsonb);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on all functions in schema pf_private from public, anon, authenticated, service_role;

commit;
