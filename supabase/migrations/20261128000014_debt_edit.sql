-- MoMa migration 014: fix debts entered by mistake (owner request, 1.1.0).
--   DEBT_UPDATE           person, due date, note; the amount only while nothing has been repaid or written off.
--   DEBT_PAYMENT_REVERSE  undo one repayment / write-off: its transaction is reversed (VOID) and the remaining
--                         principal comes back.
--   DEBT_CANCEL           "Xóa khoản nợ": every active payment and the origin transaction are reversed, the debt
--                         becomes CANCELLED and disappears from lists, balances and net worth.
-- The ledger stays append-only (docs/12 §4): nothing is deleted, every change is a REVERSAL journal (and, for an
-- amount change, a REPLACEMENT journal). Debt rows are never deleted.
-- Also: pf_read_debts lists each debt's payments (for "Hoàn tác") and hides cancelled debts; pf_read_transactions
-- returns debt_id so a debt-linked transaction can open its debt.
begin;

alter table public.pf_debt drop constraint pf_debt_state_check;
alter table public.pf_debt add constraint pf_debt_state_check
  check (state in ('OPEN', 'PARTIAL', 'SETTLED', 'WRITTEN_OFF', 'CANCELLED'));

-- Reverses the current journal of one transaction and voids it (same entries, opposite signs, original date).
create function pf_private.debt_void_tx(p_owner uuid, p_tx uuid, p_memo text) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; lines jsonb;
begin
  select * into t from public.pf_tx where id = p_tx and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.status <> 'POSTED' or t.current_journal_id is null then perform pf_private.err('INVALID_STATE'); end if;
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', p_memo) order by line_no)
    into lines from public.pf_entry where journal_id = t.current_journal_id;
  perform pf_private.post_journal(p_owner, t.id, (select effective_at from public.pf_journal where id = t.current_journal_id),
                                  'REVERSAL', lines, t.current_journal_id);
  update public.pf_tx set status = 'VOID', version = version + 1, updated_at = now() where id = t.id returning version into t.version;
  perform pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
end $$;

-- Repayments / write-offs that are still in effect (not undone).
create function pf_private.debt_active_payments(p_debt uuid) returns setof public.pf_debt_payment
language sql stable set search_path = pg_catalog, public as $$
  select p.* from public.pf_debt_payment p
   where p.debt_id = p_debt and p.kind in ('REPAYMENT', 'WRITEOFF')
     and not exists (select 1 from public.pf_debt_payment r where r.reversal_of = p.id)
$$;

-- State from what is left: nothing paid = OPEN, fully covered = SETTLED (or WRITTEN_OFF when a write-off closed it).
create function pf_private.debt_state_of(p_debt uuid) returns text
language plpgsql stable set search_path = pg_catalog, public as $$
declare d public.pf_debt; rem numeric; has_writeoff boolean;
begin
  select * into d from public.pf_debt where id = p_debt;
  rem := pf_private.debt_remaining(p_debt);
  if rem <= 0 then
    select exists (select 1 from pf_private.debt_active_payments(p_debt) where kind = 'WRITEOFF') into has_writeoff;
    return case when has_writeoff then 'WRITTEN_OFF' else 'SETTLED' end;
  end if;
  return case when rem >= d.principal then 'OPEN' else 'PARTIAL' end;
end $$;

create function pf_private.cmd_debt_update(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; t public.pf_tx; princ bigint; lines jsonb; rj uuid; nj uuid; eff timestamptz; seq bigint; cid uuid;
begin
  select * into d from public.pf_debt where id = (p->>'debt_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if d.state = 'CANCELLED' then perform pf_private.err('INVALID_STATE'); end if;

  if p ? 'contact_id' then
    cid := (p->>'contact_id')::uuid;
    perform 1 from public.pf_contact where id = cid and owner_id = p_owner and not archived;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
    -- The person follows the debt everywhere it is shown: the debt, its origin and its payments.
    update public.pf_debt set contact_id = cid where id = d.id;
    update public.pf_tx set contact_id = cid, version = version + 1, updated_at = now()
     where owner_id = p_owner and (id = d.origin_tx_id or id in (select tx_id from public.pf_debt_payment where debt_id = d.id));
  end if;
  if p ? 'due_date' then
    update public.pf_debt set due_date = nullif(p->>'due_date', '')::date where id = d.id;
  end if;
  if p ? 'note' then
    update public.pf_debt set note = nullif(btrim(left(p->>'note', 500)), '') where id = d.id;
    update public.pf_tx set note = nullif(btrim(left(p->>'note', 1000)), ''), version = version + 1, updated_at = now() where id = d.origin_tx_id;
  end if;

  if p ? 'principal' then
    princ := pf_private.parse_money(p->>'principal');
    if princ <> d.principal then
      -- Changing the amount after money moved would rewrite settled history: undo the payments first.
      if exists (select 1 from pf_private.debt_active_payments(d.id)) then perform pf_private.err('DEBT_HAS_PAYMENTS'); end if;
      select * into t from public.pf_tx where id = d.origin_tx_id for update;
      if t.status <> 'POSTED' or t.current_journal_id is null then perform pf_private.err('INVALID_STATE'); end if;
      select effective_at into eff from public.pf_journal where id = t.current_journal_id;
      select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo để sửa số tiền') order by line_no)
        into lines from public.pf_entry where journal_id = t.current_journal_id;
      rj := pf_private.post_journal(p_owner, t.id, eff, 'REVERSAL', lines, t.current_journal_id);
      -- Same two ledger accounts (debt + cash/equity), new amount, same direction.
      select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id,
                                          'signed_amount', (sign(signed_amount) * princ)::bigint::text) order by line_no)
        into lines from public.pf_entry where journal_id = t.current_journal_id;
      nj := pf_private.post_journal(p_owner, t.id, eff, 'REPLACEMENT', lines);
      update public.pf_tx set current_journal_id = nj, amount = princ, version = version + 1, updated_at = now() where id = t.id
        returning version into t.version;
      perform pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
      update public.pf_debt set principal = princ where id = d.id;
    end if;
  end if;

  update public.pf_debt set state = pf_private.debt_state_of(d.id), version = version + 1 where id = d.id returning * into d;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'DEBT_UPDATE', d.id, jsonb_build_object('principal', d.principal::text, 'due_date', d.due_date));
  seq := pf_private.touch_change(p_owner, 'debt', d.id, d.version);
  return jsonb_build_object('debt_id', d.id, 'state', d.state, 'remaining', pf_private.debt_remaining(d.id)::text, 'change_seq', seq);
end $$;

create function pf_private.cmd_debt_payment_reverse(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; pay public.pf_debt_payment; seq bigint;
begin
  select * into d from public.pf_debt where id = (p->>'debt_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if d.state = 'CANCELLED' then perform pf_private.err('INVALID_STATE'); end if;
  select * into pay from pf_private.debt_active_payments(d.id) where id = (p->>'payment_id')::uuid;
  if not found then perform pf_private.err('NOT_FOUND'); end if;   -- unknown, other debt, or already undone
  perform pf_private.debt_void_tx(p_owner, pay.tx_id, 'Hoàn tác lần ghi trả');
  insert into public.pf_debt_payment(debt_id, tx_id, principal, interest, kind, reversal_of)
    values (d.id, pay.tx_id, pay.principal, pay.interest, 'REVERSAL', pay.id);
  update public.pf_debt set state = pf_private.debt_state_of(d.id), version = version + 1 where id = d.id returning * into d;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'DEBT_PAYMENT_REVERSE', d.id, jsonb_build_object('payment_id', pay.id, 'principal', pay.principal::text));
  seq := pf_private.touch_change(p_owner, 'debt', d.id, d.version);
  return jsonb_build_object('debt_id', d.id, 'tx_id', pay.tx_id, 'state', d.state,
                            'remaining', pf_private.debt_remaining(d.id)::text, 'change_seq', seq);
end $$;

create function pf_private.cmd_debt_cancel(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; pay public.pf_debt_payment; n integer := 0; seq bigint;
begin
  select * into d from public.pf_debt where id = (p->>'debt_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if d.state = 'CANCELLED' then perform pf_private.err('INVALID_STATE'); end if;
  for pay in select * from pf_private.debt_active_payments(d.id) loop
    perform pf_private.debt_void_tx(p_owner, pay.tx_id, 'Xóa khoản nợ');
    insert into public.pf_debt_payment(debt_id, tx_id, principal, interest, kind, reversal_of)
      values (d.id, pay.tx_id, pay.principal, pay.interest, 'REVERSAL', pay.id);
    n := n + 1;
  end loop;
  perform pf_private.debt_void_tx(p_owner, d.origin_tx_id, 'Xóa khoản nợ');
  update public.pf_debt set state = 'CANCELLED', version = version + 1 where id = d.id returning * into d;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'DEBT_CANCEL', d.id, jsonb_build_object('reason', left(coalesce(p->>'reason', ''), 200), 'payments_reversed', n));
  seq := pf_private.touch_change(p_owner, 'debt', d.id, d.version);
  return jsonb_build_object('debt_id', d.id, 'state', d.state, 'payments_reversed', n, 'change_seq', seq);
end $$;

-- Dispatcher: migration 004 + the three debt commands.
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
    when 'DEBT_UPDATE'      then pf_private.cmd_debt_update(p_owner, payload)
    when 'DEBT_PAYMENT_REVERSE' then pf_private.cmd_debt_payment_reverse(p_owner, payload)
    when 'DEBT_CANCEL'      then pf_private.cmd_debt_cancel(p_owner, payload)
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

-- Debts list: cancelled debts are gone; each debt carries its repayments / write-offs (newest first) so one can be
-- undone. "reversed" marks the ones already undone (kept for history).
create or replace function public.pf_read_debts(p_owner uuid, p_today date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.overdue desc, x.due_date nulls last, x.originated_at) from (
    select d.id, d.direction, d.contact_id, c.alias as contact_alias, d.principal::text as principal,
           pf_private.debt_remaining(d.id)::text as remaining, d.state, d.due_date, d.originated_at, d.note, d.version,
           (d.state in ('OPEN', 'PARTIAL') and d.due_date is not null and d.due_date < p_today) as overdue,
           d.origin_tx_id,
           (select t.account_id from public.pf_tx t where t.id = d.origin_tx_id) as account_id,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'kind', p.kind, 'principal', p.principal::text, 'interest', p.interest::text,
                       'tx_id', p.tx_id, 'account_id', t.account_id, 'effective_at', t.effective_at,
                       'reversed', exists (select 1 from public.pf_debt_payment r where r.reversal_of = p.id))
                     order by t.effective_at desc, p.id)
                       from public.pf_debt_payment p join public.pf_tx t on t.id = p.tx_id
                      where p.debt_id = d.id and p.kind in ('REPAYMENT', 'WRITEOFF')), '[]'::jsonb) as payments
      from public.pf_debt d join public.pf_contact c on c.id = d.contact_id
     where d.owner_id = p_owner and d.state <> 'CANCELLED') x), '[]'::jsonb);
end $$;

-- Transactions list: migration 009 + debt_id (the debt a LOAN_* / write-off transaction belongs to).
create or replace function public.pf_read_transactions(p_owner uuid, p_limit integer, p_before_at timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc, x.id desc) from (
    select t.id, t.kind, t.status, t.effective_at, t.amount::text as amount, t.fee::text as fee, t.account_id, t.to_account_id, t.category_id,
           t.merchant, t.note, t.version, t.related_tx_id, t.contact_id, t.source,
           exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id) or exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id) as debt_linked,
           coalesce((select d.id from public.pf_debt d where d.origin_tx_id = t.id),
                    (select dp.debt_id from public.pf_debt_payment dp where dp.tx_id = t.id limit 1)) as debt_id
    from public.pf_tx t
    where t.owner_id = p_owner and t.status in ('POSTED','VOID')
      and (p_before_at is null or (t.effective_at, t.id) < (p_before_at, p_before_id))
    order by t.effective_at desc, t.id desc limit lim) x), '[]'::jsonb);
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
