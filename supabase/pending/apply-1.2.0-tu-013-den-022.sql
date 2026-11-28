-- MoMa 1.2.0: tất cả migration mới 013 → 022 (dùng khi CHƯA chạy 013 và 014)
-- Dán TOÀN BỘ file này vào Supabase SQL Editor rồi bấm Run MỘT lần. Mỗi phần có begin/commit riêng.
-- Nếu một phần báo lỗi "already exists" nghĩa là phần đó đã chạy trước đây: xóa phần đó khỏi file rồi chạy lại phần còn lại.

-- ===================================================== 20261128000013_tx_attachments.sql
-- MoMa migration 013: transaction attachments (receipts, transfer screenshots, invoices).
-- The pictures themselves live in Cloudflare R2 (bucket moma-attachments), never in Postgres: this table only keeps
-- the object key and metadata. Server role only; the API checks the owner on every read.
begin;

create table public.pf_tx_attachment (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  tx_id uuid not null references public.pf_tx(id),
  object_key text not null unique check (length(object_key) between 10 and 300),
  content_type text not null check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes integer not null check (size_bytes between 1 and 10485760),
  created_at timestamptz not null default now()
);
alter table public.pf_tx_attachment enable row level security;
revoke all on table public.pf_tx_attachment from public, anon, authenticated;
create index pf_tx_attachment_tx_idx on public.pf_tx_attachment(owner_id, tx_id, created_at);

-- At most 10 pictures per transaction (counted on the row itself; earlier versions keep their own).
create function public.pf_attachment_add(p_owner uuid, p_tx uuid, p_key text, p_type text, p_size integer) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare aid uuid; ts timestamptz;
begin
  perform pf_private.assert_owner(p_owner);
  if not exists (select 1 from public.pf_tx where id = p_tx and owner_id = p_owner) then
    perform pf_private.err('NOT_FOUND');
  end if;
  if (select count(*) from public.pf_tx_attachment where owner_id = p_owner and tx_id = p_tx) >= 10 then
    perform pf_private.err('ATTACHMENT_LIMIT');
  end if;
  insert into public.pf_tx_attachment(owner_id, tx_id, object_key, content_type, size_bytes)
    values (p_owner, p_tx, p_key, p_type, p_size)
    returning id, created_at into aid, ts;
  return jsonb_build_object('id', aid, 'tx_id', p_tx, 'content_type', p_type, 'size_bytes', p_size, 'created_at', ts);
end $$;

-- Pictures of a transaction and of every earlier version it replaced: "Chỉnh sửa" voids the old row and creates a
-- new one with related_tx_id = old id, so receipts attached before an edit stay visible on the new version.
create function public.pf_attachment_list(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((
    with recursive chain(id, depth) as (
      select t.id, 0 from public.pf_tx t where t.id = p_tx and t.owner_id = p_owner
      union all
      select t.related_tx_id, c.depth + 1 from chain c join public.pf_tx t on t.id = c.id
       where t.owner_id = p_owner and t.related_tx_id is not null and c.depth < 50
    )
    select jsonb_agg(jsonb_build_object('id', a.id, 'tx_id', a.tx_id, 'content_type', a.content_type,
             'size_bytes', a.size_bytes, 'created_at', a.created_at) order by a.created_at, a.id)
      from public.pf_tx_attachment a
     where a.owner_id = p_owner and a.tx_id in (select id from chain)), '[]'::jsonb);
end $$;

-- Object key of one attachment (the API streams it from R2). NOT_FOUND for another owner's id.
create function public.pf_attachment_get(p_owner uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r record;
begin
  perform pf_private.assert_owner(p_owner);
  select object_key, content_type into r from public.pf_tx_attachment where id = p_id and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('object_key', r.object_key, 'content_type', r.content_type);
end $$;

-- Removes the row and returns its object key so the API deletes the picture from R2.
create function public.pf_attachment_delete(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare k text;
begin
  perform pf_private.assert_owner(p_owner);
  delete from public.pf_tx_attachment where id = p_id and owner_id = p_owner returning object_key into k;
  if k is null then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('object_key', k);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;

-- ===================================================== 20261128000014_debt_edit.sql
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

-- ===================================================== 20261128000015_ai_classify.sql
-- MoMa migration 015: automatic categorization (D-020).
-- Money captured from bank notifications / SePay often arrives as "Tiền ra/vào chưa phân loại" (UNKNOWN_*) or in the
-- fallback category "Khác". The Worker classifies it (owner's learned rules -> own history -> merchant dictionary ->
-- DeepSeek) and either applies the category in place (high confidence) or stores a suggestion the app shows as
-- one-tap chips. Every decision is recorded in pf_tx_classification so the app can show "AI đã phân loại · Sửa" and
-- the classifier never touches what the owner has already decided.
--
-- Ledger: classifying keeps the SAME transaction id (receipts, transfer pairs, inbox links stay valid): the current
-- journal is reversed and a replacement posted where the suspense / old category leg moves to the new category's
-- ledger account. TX_ANNOTATE now accepts UNKNOWN_* too (same rule), so the owner's one-tap choice uses it.
begin;

create table public.pf_tx_classification (
  tx_id uuid primary key references public.pf_tx(id),
  owner_id uuid not null references public.pf_owner(user_id),
  -- APPLIED: the classifier set the category. SUGGESTED: low confidence, category is only a suggestion (may be null).
  -- CONFIRMED: owner kept / picked the suggested category. CORRECTED: owner chose another category.
  status text not null check (status in ('APPLIED', 'SUGGESTED', 'CONFIRMED', 'CORRECTED')),
  category_id uuid references public.pf_category(id),
  merchant text check (merchant is null or length(merchant) <= 120),
  confidence numeric(4, 3) not null default 0 check (confidence between 0 and 1),
  method text not null check (method in ('MEMORY', 'HISTORY', 'DICTIONARY', 'AI', 'RULE', 'OWNER')),
  reason text check (reason is null or length(reason) <= 300),
  -- When the owner was pushed about this still-unclear item (one batched push, never twice per item).
  notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.pf_tx_classification enable row level security;
revoke all on table public.pf_tx_classification from public, anon, authenticated;
create index pf_tx_classification_owner_idx on public.pf_tx_classification(owner_id, status, updated_at desc);

-- ---------------------------------------------------------------- in-place reclassification (ledger)
-- Moves a posted INCOME/EXPENSE/UNKNOWN_* transaction to category c. Caller has locked t and checked ownership.
create function pf_private.tx_reclassify(p_owner uuid, t public.pf_tx, c public.pf_category) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare old_leg uuid; lines jsonb; rj uuid; nj uuid; old_eff timestamptz; new_kind public.pf_tx_kind;
begin
  if t.status <> 'POSTED' or t.current_journal_id is null then perform pf_private.err('INVALID_STATE'); end if;
  new_kind := case
    when t.kind in ('EXPENSE', 'UNKNOWN_DEBIT') and c.type = 'EXPENSE' then 'EXPENSE'
    when t.kind in ('INCOME', 'UNKNOWN_CREDIT') and c.type = 'INCOME' then 'INCOME' end;
  if t.kind not in ('EXPENSE', 'UNKNOWN_DEBIT', 'INCOME', 'UNKNOWN_CREDIT') then perform pf_private.err('INVALID_STATE'); end if;
  if new_kind is null then perform pf_private.err('CATEGORY_MISMATCH'); end if;
  if t.kind = new_kind and t.category_id = c.id then return; end if;
  old_leg := case t.kind
    when 'UNKNOWN_DEBIT' then pf_private.sys_ledger(p_owner, 'SYS_SUSPENSE_DEBIT')
    when 'UNKNOWN_CREDIT' then pf_private.sys_ledger(p_owner, 'SYS_SUSPENSE_CREDIT')
    else (select ledger_account_id from public.pf_category where id = t.category_id) end;
  if old_leg is null or not exists (select 1 from public.pf_entry where journal_id = t.current_journal_id and ledger_account_id = old_leg) then
    perform pf_private.err('INVALID_STATE');
  end if;
  select effective_at into old_eff from public.pf_journal where id = t.current_journal_id;
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo để đổi danh mục') order by line_no)
    into lines from public.pf_entry where journal_id = t.current_journal_id;
  rj := pf_private.post_journal(p_owner, t.id, old_eff, 'REVERSAL', lines, t.current_journal_id);
  select jsonb_agg(jsonb_build_object('ledger_account_id', case when e.ledger_account_id = old_leg then c.ledger_account_id else e.ledger_account_id end,
                                      'signed_amount', e.signed_amount::text) order by e.line_no)
    into lines from public.pf_entry e where e.journal_id = t.current_journal_id;
  nj := pf_private.post_journal(p_owner, t.id, old_eff, 'REPLACEMENT', lines);
  update public.pf_tx set current_journal_id = nj, category_id = c.id, kind = new_kind where id = t.id;
end $$;

-- TX_ANNOTATE (migration 004) + classification of UNKNOWN_* in place. The owner's choice is recorded so the
-- classifier never overrides it and the app stops showing suggestions.
create or replace function pf_private.cmd_tx_annotate(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; newcat public.pf_category; reclass boolean := false; seq bigint; prev public.pf_tx_classification;
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
  if p ? 'category_id' and ((p->>'category_id')::uuid is distinct from t.category_id or t.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')) then
    if t.kind not in ('INCOME', 'EXPENSE', 'UNKNOWN_DEBIT', 'UNKNOWN_CREDIT') then perform pf_private.err('INVALID_STATE'); end if;
    select * into newcat from public.pf_category where id = (p->>'category_id')::uuid and owner_id = p_owner and not archived;
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
    perform pf_private.tx_reclassify(p_owner, t, newcat);
    reclass := true;
  end if;
  update public.pf_tx set note = case when p ? 'note' then left(p->>'note', 1000) else note end,
         merchant = case when p ? 'merchant' then left(p->>'merchant', 120) else merchant end,
         contact_id = case when p ? 'contact_id' then (p->>'contact_id')::uuid else contact_id end,
         version = version + 1, updated_at = now()
   where id = t.id returning * into t;
  if reclass then
    select * into prev from public.pf_tx_classification where tx_id = t.id;
    insert into public.pf_tx_classification(tx_id, owner_id, status, category_id, merchant, confidence, method, reason)
      values (t.id, p_owner, 'CONFIRMED', t.category_id, t.merchant, 1, 'OWNER', null)
    on conflict (tx_id) do update set
      status = case when public.pf_tx_classification.category_id = excluded.category_id then 'CONFIRMED' else 'CORRECTED' end,
      updated_at = now();
  end if;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe) values (p_owner, 'owner', 'TX_ANNOTATE', t.id, jsonb_build_object('reclassified', reclass));
  seq := pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
  return jsonb_build_object('tx_id', t.id, 'change_seq', seq, 'reclassified', reclass, 'previous_ai', prev.status);
end $$;

-- ---------------------------------------------------------------- classifier RPCs (Worker only)
-- Transactions still waiting for a category: UNKNOWN_* or bank/notification money parked in a fallback category
-- ("Khác" / "Thu nhập khác"), never classified before, not part of a pending own-account transfer, not debt-linked.
create function public.pf_ai_classify_candidates(p_owner uuid, p_limit integer, p_tx uuid default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc) from (
    select t.id, t.kind, t.amount::text as amount, t.effective_at, t.note, t.merchant, t.source, t.version, t.category_id,
           a.institution, a.name as account_name, a.kind as account_kind
      from public.pf_tx t join public.pf_account a on a.id = t.account_id
     where t.owner_id = p_owner and t.status = 'POSTED'
       and (p_tx is null or t.id = p_tx)
       and (p_tx is not null or t.effective_at > now() - interval '45 days')
       and (t.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')
            or (t.kind in ('EXPENSE', 'INCOME') and t.source in ('BANK', 'NOTIFICATION', 'IMPORT')
                and exists (select 1 from public.pf_category c where c.id = t.category_id and c.name in ('Khác', 'Thu nhập khác'))))
       and not exists (select 1 from public.pf_tx_classification k where k.tx_id = t.id)
       and not exists (select 1 from public.pf_transfer_pair p where p.state = 'SUGGESTED' and t.id in (p.out_tx, p.in_tx))
       and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
       and not exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id)
     order by t.effective_at desc limit lim) x), '[]'::jsonb);
end $$;

-- Owner's categorized history (most recent first) used as "same merchant -> same category" evidence and AI examples.
create function public.pf_ai_classify_examples(p_owner uuid, p_limit integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 300), 1), 1000);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb) from (
    select t.kind, t.category_id, t.note, t.merchant
      from public.pf_tx t join public.pf_category c on c.id = t.category_id
     where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'INCOME')
       and c.name not in ('Khác', 'Thu nhập khác')
       and coalesce(nullif(btrim(t.note), ''), nullif(btrim(t.merchant), '')) is not null
       and t.effective_at > now() - interval '365 days'
     order by t.effective_at desc limit lim) x), '[]'::jsonb);
end $$;

-- Records the classifier's decision. p_apply = true sets the category in place (only while the transaction is still
-- a candidate: nobody classified it meanwhile). Returns {status} = APPLIED | SUGGESTED | SKIPPED.
create function public.pf_ai_classify_record(p_owner uuid, p_tx uuid, p_category uuid, p_merchant text, p_confidence numeric,
                                             p_method text, p_reason text, p_apply boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx; c public.pf_category; st text; fallback boolean;
begin
  perform pf_private.assert_owner(p_owner);
  select * into t from public.pf_tx where id = p_tx and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if exists (select 1 from public.pf_tx_classification where tx_id = t.id) then return jsonb_build_object('status', 'SKIPPED'); end if;
  if p_category is not null then
    select * into c from public.pf_category where id = p_category and owner_id = p_owner and not archived;
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
  end if;
  fallback := t.kind in ('EXPENSE', 'INCOME') and exists (select 1 from public.pf_category x where x.id = t.category_id and x.name in ('Khác', 'Thu nhập khác'));
  st := 'SUGGESTED';
  if p_apply and c.id is not null and t.status = 'POSTED' and (t.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT') or fallback)
     and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
     and not exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id) then
    perform pf_private.tx_reclassify(p_owner, t, c);
    update public.pf_tx set merchant = coalesce(merchant, nullif(left(btrim(p_merchant), 120), '')), version = version + 1, updated_at = now()
     where id = t.id returning * into t;
    perform pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
    insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
      values (p_owner, 'ai', 'TX_CLASSIFY', t.id, jsonb_build_object('method', p_method, 'confidence', p_confidence));
    st := 'APPLIED';
  elsif c.id is not null and t.status = 'POSTED' and t.category_id = c.id and t.kind in ('EXPENSE', 'INCOME') then
    st := 'APPLIED'; -- already categorized this way when it was ingested (SePay rules / dictionary)
  end if;
  insert into public.pf_tx_classification(tx_id, owner_id, status, category_id, merchant, confidence, method, reason)
    values (t.id, p_owner, st, c.id, nullif(left(btrim(p_merchant), 120), ''), least(greatest(coalesce(p_confidence, 0), 0), 1),
            p_method, left(p_reason, 300));
  return jsonb_build_object('status', st, 'tx_id', t.id, 'version', t.version);
end $$;

-- Still-unclear money the owner should pick a category for ("Chọn loại nhanh"): the classifier was not sure and
-- nobody decided since. p_unnotified = true keeps only items not pushed yet (for the batched push).
create function public.pf_ai_classify_pending(p_owner uuid, p_limit integer, p_unnotified boolean default false) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return jsonb_build_object(
    'total', (select count(*) from public.pf_tx_classification k join public.pf_tx t on t.id = k.tx_id
               where k.owner_id = p_owner and k.status = 'SUGGESTED' and t.status = 'POSTED'
                 and (t.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')
                      or exists (select 1 from public.pf_category c where c.id = t.category_id and c.name in ('Khác', 'Thu nhập khác')))),
    'items', coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc) from (
      select t.id, t.kind, t.amount::text as amount, t.effective_at, t.note, t.merchant, t.version, t.category_id, t.account_id,
             a.name as account_name, a.institution, k.category_id as suggested_category_id, k.confidence, k.reason, k.merchant as suggested_merchant,
             k.notified_at
        from public.pf_tx_classification k join public.pf_tx t on t.id = k.tx_id join public.pf_account a on a.id = t.account_id
       where k.owner_id = p_owner and k.status = 'SUGGESTED' and t.status = 'POSTED'
         and (not coalesce(p_unnotified, false) or k.notified_at is null)
         and (t.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')
              or exists (select 1 from public.pf_category c where c.id = t.category_id and c.name in ('Khác', 'Thu nhập khác')))
       order by t.effective_at desc limit lim) x), '[]'::jsonb));
end $$;

create function public.pf_ai_classify_mark_notified(p_owner uuid, p_ids uuid[]) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_tx_classification set notified_at = now(), updated_at = now()
   where owner_id = p_owner and tx_id = any(p_ids) and notified_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
-- Facts of one transaction for learning after the owner (re)classified it.
create function public.pf_ai_classify_tx(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  select jsonb_build_object('id', t.id, 'kind', t.kind, 'note', t.note, 'merchant', t.merchant, 'source', t.source,
           'category_id', t.category_id, 'category', c.name, 'category_type', c.type,
           'previous', (select jsonb_build_object('status', k.status, 'category_id', k.category_id, 'method', k.method)
                          from public.pf_tx_classification k where k.tx_id = t.id))
    into r from public.pf_tx t left join public.pf_category c on c.id = t.category_id
   where t.id = p_tx and t.owner_id = p_owner;
  if r is null then perform pf_private.err('NOT_FOUND'); end if;
  return r;
end $$;

-- ---------------------------------------------------------------- read model: classification per transaction
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
                    (select dp.debt_id from public.pf_debt_payment dp where dp.tx_id = t.id limit 1)) as debt_id,
           (select jsonb_build_object('status', k.status, 'category_id', k.category_id, 'confidence', k.confidence,
                                      'method', k.method, 'merchant', k.merchant)
              from public.pf_tx_classification k where k.tx_id = t.id) as ai
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

commit;

-- ===================================================== 20261128000016_recurring_split.sql
-- MoMa migration 016: automatic recurring payments with bill splitting (D-022).
--   pf_recurring_split    per recurring rule: due window (day 5-10 of the month), amount tolerance, payee keywords,
--                         participants (contacts) with their share mode, rounding, auto-apply.
--   pf_split_application  one split of one expense transaction: PROPOSED (owner confirms with one tap), APPLIED (debts
--                         created, can be undone), UNDONE, DISMISSED.
-- Commands: RECURRING_SPLIT_UPSERT, SPLIT_APPLY, SPLIT_UNDO, SPLIT_DISMISS. The Worker's matcher and the bill-photo
-- reader call the same private functions through pf_split_* RPCs (server role only).
--
-- Ledger: the owner paid the whole bill (one EXPENSE transaction, cash already out). Each other person's share becomes
-- a RECEIVABLE debt whose origin transaction moves that share out of the expense leg:
--     Dr receivable (new debt ledger account)  +share      Cr expense/category leg of the bill  -share
-- so cash is untouched, the expense keeps only the owner's part, and the receivables add up to what the others owe.
-- Undo = DEBT_CANCEL of those debts (reversal journals, migration 014): the expense gets its full amount back.
-- Requires migration 015 (pf_private.tx_reclassify) for applying the rule's category in place.
begin;

create table public.pf_recurring_split (
  recurring_id uuid primary key references public.pf_recurring(id),
  owner_id uuid not null references public.pf_owner(user_id),
  window_start smallint not null check (window_start between 1 and 31),
  window_end smallint not null check (window_end between 1 and 31),
  tolerance_pct smallint not null default 10 check (tolerance_pct between 0 and 50),
  payee_keywords text[] not null default '{}' check (cardinality(payee_keywords) <= 10),
  -- Each other person's share is rounded UP to this step (owner keeps the remainder). 0 = exact.
  rounding integer not null default 5000 check (rounding in (0, 1000, 5000, 10000)),
  owner_share boolean not null default true,
  auto_apply boolean not null default true,
  -- [{contact_id, mode: EQUAL|FIXED|PERCENT, value}]
  participants jsonb not null default '[]'::jsonb check (jsonb_typeof(participants) = 'array' and jsonb_array_length(participants) <= 20),
  updated_at timestamptz not null default now()
);
alter table public.pf_recurring_split enable row level security;
revoke all on table public.pf_recurring_split from public, anon, authenticated;

create table public.pf_split_application (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  tx_id uuid not null references public.pf_tx(id),
  recurring_id uuid references public.pf_recurring(id),
  occurrence_id uuid references public.pf_occurrence(id),
  source text not null check (source in ('RECURRING', 'BILL', 'MANUAL', 'AI')),
  state text not null check (state in ('PROPOSED', 'APPLIED', 'UNDONE', 'DISMISSED')),
  confidence numeric(4, 3) not null default 0 check (confidence between 0 and 1),
  total bigint not null check (total > 0),
  category_id uuid references public.pf_category(id),
  -- [{contact_id (null = new person by name), name, amount, debt_id}]
  shares jsonb not null default '[]'::jsonb check (jsonb_typeof(shares) = 'array'),
  owner_amount bigint not null default 0,
  note text check (note is null or length(note) <= 300),
  hints jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  version integer not null default 1
);
alter table public.pf_split_application enable row level security;
revoke all on table public.pf_split_application from public, anon, authenticated;
create unique index pf_split_application_live_uq on public.pf_split_application(tx_id) where state in ('PROPOSED', 'APPLIED');
create index pf_split_application_owner_idx on public.pf_split_application(owner_id, state, created_at desc);

-- A bill that was split cannot be cancelled, corrected or moved to another category underneath its debts (each debt
-- took its share out of that category's ledger account): undo the split first. Also keeps the automatic classifier
-- (migration 015) from re-categorizing a split bill.
create function pf_private.split_guard_void() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if ((new.status = 'VOID' and old.status <> 'VOID') or new.category_id is distinct from old.category_id)
     and exists (select 1 from public.pf_split_application a where a.tx_id = new.id and a.state = 'APPLIED') then
    perform pf_private.err('SPLIT_LINKED');
  end if;
  return new;
end $$;
create trigger pf_tx_split_guard before update of status, category_id on public.pf_tx
  for each row execute function pf_private.split_guard_void();

-- The ledger leg that carries the bill's cost (the debit that is not a money account): the category of an EXPENSE,
-- the suspense account of an UNKNOWN_DEBIT.
create function pf_private.split_cost_leg(p_owner uuid, t public.pf_tx) returns uuid
language plpgsql stable set search_path = pg_catalog, public as $$
declare leg uuid;
begin
  if t.category_id is not null then
    select c.ledger_account_id into leg from public.pf_category c
     where c.id = t.category_id and exists (select 1 from public.pf_entry e where e.journal_id = t.current_journal_id
                                              and e.ledger_account_id = c.ledger_account_id and e.signed_amount > 0);
    if leg is not null then return leg; end if;
  end if;
  select e.ledger_account_id into leg from public.pf_entry e
   where e.journal_id = t.current_journal_id and e.signed_amount > 0
     and not exists (select 1 from public.pf_account a where a.owner_id = p_owner and a.ledger_account_id = e.ledger_account_id)
   order by e.signed_amount desc, e.line_no limit 1;
  return leg;
end $$;

-- One receivable debt for one person's share of the bill t (see header for the journal).
create function pf_private.split_debt_on_tx(p_owner uuid, t public.pf_tx, p_contact uuid, p_amount bigint, p_note text) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare did uuid := gen_random_uuid(); lid uuid := gen_random_uuid(); tx uuid := gen_random_uuid(); leg uuid; j uuid;
begin
  leg := pf_private.split_cost_leg(p_owner, t);
  if leg is null then perform pf_private.err('INVALID_STATE'); end if;
  insert into public.pf_ledger_account(id, owner_id, code, class, name)
    values (lid, p_owner, 'DEBT_' || did, 'ASSET'::public.pf_ledger_class, 'Công nợ');
  insert into public.pf_tx(id, owner_id, kind, status, effective_at, note, contact_id, amount, source)
    values (tx, p_owner, 'LOAN_GIVEN', 'DRAFT', t.effective_at, left(p_note, 1000), p_contact, p_amount, 'SYSTEM');
  insert into public.pf_debt(id, owner_id, contact_id, ledger_account_id, direction, principal, originated_at, origin_tx_id, note)
    values (did, p_owner, p_contact, lid, 'RECEIVABLE', p_amount, t.effective_at, tx, left(p_note, 500));
  j := pf_private.post_journal(p_owner, tx, t.effective_at, 'ORIGINAL',
         jsonb_build_array(jsonb_build_object('ledger_account_id', lid, 'signed_amount', p_amount::text, 'memo', 'Phần chia'),
                           jsonb_build_object('ledger_account_id', leg, 'signed_amount', (-p_amount)::text, 'memo', 'Phần chia')));
  update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
  perform pf_private.touch_change(p_owner, 'debt', did, 1);
  return did;
end $$;

-- Finds the owner's contact by name (case-insensitive) or creates it.
create function pf_private.split_contact(p_owner uuid, p_name text) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare cid uuid; n text := btrim(coalesce(p_name, ''));
begin
  if length(n) = 0 or length(n) > 80 then perform pf_private.err('VALIDATION_FAILED'); end if;
  select id into cid from public.pf_contact where owner_id = p_owner and not archived and lower(alias) = lower(n)
   order by version desc limit 1;
  if cid is null then cid := ((pf_private.cmd_contact_create(p_owner, jsonb_build_object('alias', n)))->>'contact_id')::uuid; end if;
  return cid;
end $$;

-- SPLIT_APPLY {tx_id, shares:[{contact_id | name, amount}], category_id?, merchant?, recurring_id?, occurrence_id?,
--              application_id? (a proposal being confirmed), source?, confidence?, note?}
create function pf_private.cmd_split_apply(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; c public.pf_category; a public.pf_split_application; s jsonb; cid uuid; amt bigint; did uuid;
        out_shares jsonb := '[]'::jsonb; total_shares bigint := 0; leg_amount bigint; label text; o public.pf_occurrence;
        app_id uuid := nullif(p->>'application_id', '')::uuid; src text := coalesce(nullif(p->>'source', ''), 'MANUAL');
begin
  select * into t from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.status <> 'POSTED' or t.kind not in ('EXPENSE', 'UNKNOWN_DEBIT') then perform pf_private.err('INVALID_STATE'); end if;
  if jsonb_typeof(p->'shares') <> 'array' or jsonb_array_length(p->'shares') > 20 then perform pf_private.err('VALIDATION_FAILED'); end if;
  if src not in ('RECURRING', 'BILL', 'MANUAL', 'AI') then perform pf_private.err('VALIDATION_FAILED'); end if;

  select * into a from public.pf_split_application where tx_id = t.id and state in ('PROPOSED', 'APPLIED') for update;
  if found and (a.state = 'APPLIED' or app_id is distinct from a.id) then
    -- A pending proposal for another rule gives way to the owner's explicit choice; an applied split never does.
    if a.state = 'APPLIED' then perform pf_private.err('SPLIT_EXISTS'); end if;
    update public.pf_split_application set state = 'DISMISSED', decided_at = now(), version = version + 1 where id = a.id;
    a := null;
  end if;
  if app_id is not null and a.id is null then
    select * into a from public.pf_split_application where id = app_id and owner_id = p_owner and tx_id = t.id;
    if not found or a.state <> 'PROPOSED' then perform pf_private.err('NOT_FOUND'); end if;
  end if;

  -- The bill's category first (in place, same transaction id), so the debts move money out of the right category.
  if nullif(p->>'category_id', '') is not null and ((p->>'category_id')::uuid is distinct from t.category_id or t.kind = 'UNKNOWN_DEBIT') then
    select * into c from public.pf_category where id = (p->>'category_id')::uuid and owner_id = p_owner and not archived and type = 'EXPENSE';
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
    perform pf_private.tx_reclassify(p_owner, t, c);
    select * into t from public.pf_tx where id = t.id;
  end if;
  if nullif(btrim(p->>'merchant'), '') is not null and coalesce(t.merchant, '') = '' then
    update public.pf_tx set merchant = left(btrim(p->>'merchant'), 120) where id = t.id;
  end if;

  select e.signed_amount into leg_amount from public.pf_entry e
   where e.journal_id = t.current_journal_id and e.ledger_account_id = pf_private.split_cost_leg(p_owner, t);
  label := coalesce(nullif(btrim(p->>'note'), ''), nullif(t.merchant, ''), nullif(btrim(p->>'merchant'), ''), 'hóa đơn');
  for s in select * from jsonb_array_elements(p->'shares') loop
    amt := pf_private.parse_money(s->>'amount');
    total_shares := total_shares + amt;
    -- Equal to the bill is allowed (owner paid entirely for others); more is not.
    if total_shares > coalesce(leg_amount, 0) then perform pf_private.err('SPLIT_TOO_LARGE'); end if;
    cid := nullif(s->>'contact_id', '')::uuid;
    if cid is null then
      cid := pf_private.split_contact(p_owner, s->>'name');
    else
      perform 1 from public.pf_contact where id = cid and owner_id = p_owner and not archived;
      if not found then perform pf_private.err('NOT_FOUND'); end if;
    end if;
    did := pf_private.split_debt_on_tx(p_owner, t, cid, amt, 'Phần chia ' || label);
    out_shares := out_shares || jsonb_build_array(jsonb_build_object('contact_id', cid,
                    'name', (select alias from public.pf_contact where id = cid), 'amount', amt::text, 'debt_id', did));
  end loop;

  -- The recurring occurrence this payment settles (if any, still expected and the tx not used elsewhere).
  if nullif(p->>'occurrence_id', '') is not null then
    select oc.* into o from public.pf_occurrence oc join public.pf_recurring r on r.id = oc.recurring_id
     where oc.id = (p->>'occurrence_id')::uuid and r.owner_id = p_owner for update of oc;
    if found and o.state = 'EXPECTED' and not exists (select 1 from public.pf_occurrence x where x.matched_tx_id = t.id) then
      update public.pf_occurrence set state = 'MATCHED', matched_tx_id = t.id, version = version + 1 where id = o.id returning * into o;
      perform pf_private.touch_change(p_owner, 'occurrence', o.id, o.version);
    end if;
  end if;

  if a.id is not null then
    update public.pf_split_application set state = 'APPLIED', shares = out_shares, owner_amount = leg_amount - total_shares,
           category_id = t.category_id, decided_at = now(), version = version + 1,
           recurring_id = coalesce(nullif(p->>'recurring_id', '')::uuid, recurring_id),
           occurrence_id = coalesce(nullif(p->>'occurrence_id', '')::uuid, occurrence_id)
     where id = a.id returning * into a;
  else
    insert into public.pf_split_application(owner_id, tx_id, recurring_id, occurrence_id, source, state, confidence, total,
                                            category_id, shares, owner_amount, note, hints, decided_at)
      values (p_owner, t.id, nullif(p->>'recurring_id', '')::uuid, nullif(p->>'occurrence_id', '')::uuid, src, 'APPLIED',
              least(greatest(coalesce((p->>'confidence')::numeric, 1), 0), 1), leg_amount, t.category_id, out_shares,
              leg_amount - total_shares, left(nullif(btrim(p->>'note'), ''), 300),
              coalesce(p->'hints', '[]'::jsonb), now())
      returning * into a;
  end if;
  update public.pf_tx set version = version + 1, updated_at = now() where id = t.id returning version into t.version;
  perform pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'SPLIT_APPLY', a.id, jsonb_build_object('tx_id', t.id, 'shares', jsonb_array_length(out_shares), 'source', a.source));
  return jsonb_build_object('application_id', a.id, 'tx_id', t.id, 'shares', out_shares, 'owner_amount', a.owner_amount::text,
                            'change_seq', pf_private.touch_change(p_owner, 'split', a.id, a.version));
end $$;

-- SPLIT_UNDO {application_id}: cancels the debts (reversal journals), puts the recurring occurrence back to expected.
create function pf_private.cmd_split_undo(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare a public.pf_split_application; s jsonb; d public.pf_debt; n integer := 0;
begin
  select * into a from public.pf_split_application where id = (p->>'application_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if a.state <> 'APPLIED' then perform pf_private.err('INVALID_STATE'); end if;
  -- Someone already paid back part of their share: undoing would erase real money, so refuse (undo that payment first).
  if exists (select 1 from jsonb_array_elements(a.shares) x join public.pf_debt dd on dd.id = nullif(x->>'debt_id', '')::uuid
              where exists (select 1 from pf_private.debt_active_payments(dd.id))) then
    perform pf_private.err('DEBT_HAS_PAYMENTS');
  end if;
  for s in select * from jsonb_array_elements(a.shares) loop
    select * into d from public.pf_debt where id = nullif(s->>'debt_id', '')::uuid and owner_id = p_owner;
    if found and d.state <> 'CANCELLED' then
      perform pf_private.cmd_debt_cancel(p_owner, jsonb_build_object('debt_id', d.id, 'expected_version', d.version, 'reason', 'Hoàn tác chia tiền'));
      n := n + 1;
    end if;
  end loop;
  if a.occurrence_id is not null then
    update public.pf_occurrence set state = 'EXPECTED', matched_tx_id = null, version = version + 1
     where id = a.occurrence_id and matched_tx_id = a.tx_id;
  end if;
  update public.pf_split_application set state = 'UNDONE', decided_at = now(), version = version + 1 where id = a.id returning * into a;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'SPLIT_UNDO', a.id, jsonb_build_object('tx_id', a.tx_id, 'debts_cancelled', n));
  return jsonb_build_object('application_id', a.id, 'state', a.state, 'debts_cancelled', n,
                            'change_seq', pf_private.touch_change(p_owner, 'split', a.id, a.version));
end $$;

-- SPLIT_DISMISS {application_id}: "Không chia" on a proposal; the same rule never proposes it again for that bill.
create function pf_private.cmd_split_dismiss(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare a public.pf_split_application;
begin
  select * into a from public.pf_split_application where id = (p->>'application_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if a.state <> 'PROPOSED' then perform pf_private.err('INVALID_STATE'); end if;
  update public.pf_split_application set state = 'DISMISSED', decided_at = now(), version = version + 1 where id = a.id returning * into a;
  return jsonb_build_object('application_id', a.id, 'state', a.state, 'change_seq', pf_private.touch_change(p_owner, 'split', a.id, a.version));
end $$;

-- RECURRING_SPLIT_UPSERT: RECURRING_UPSERT (expense) + its window / tolerance / keywords / participants / rounding.
create function pf_private.cmd_recurring_split_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare res jsonb; rid uuid; part jsonb; ws smallint := (p->>'window_start')::smallint; we smallint := (p->>'window_end')::smallint;
        kw text[];
begin
  if ws is null or we is null or ws not between 1 and 31 or we not between 1 and 31 or we < ws then perform pf_private.err('VALIDATION_FAILED'); end if;
  if jsonb_typeof(coalesce(p->'participants', '[]'::jsonb)) <> 'array' then perform pf_private.err('VALIDATION_FAILED'); end if;
  for part in select * from jsonb_array_elements(coalesce(p->'participants', '[]'::jsonb)) loop
    if part->>'mode' not in ('EQUAL', 'FIXED', 'PERCENT') then perform pf_private.err('VALIDATION_FAILED'); end if;
    perform 1 from public.pf_contact where id = (part->>'contact_id')::uuid and owner_id = p_owner and not archived;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
  end loop;
  select coalesce(array_agg(left(btrim(x), 40)) filter (where btrim(x) <> ''), '{}') into kw
    from jsonb_array_elements_text(coalesce(p->'payee_keywords', '[]'::jsonb)) x;
  res := pf_private.cmd_recurring_upsert(p_owner, (p - 'window_start' - 'window_end' - 'tolerance_pct' - 'payee_keywords' - 'rounding'
                                                    - 'owner_share' - 'auto_apply' - 'participants') || jsonb_build_object('kind', 'EXPENSE', 'interval', coalesce(p->>'interval', 'MONTHLY')));
  rid := (res->>'recurring_id')::uuid;
  insert into public.pf_recurring_split(recurring_id, owner_id, window_start, window_end, tolerance_pct, payee_keywords, rounding,
                                        owner_share, auto_apply, participants)
    values (rid, p_owner, ws, we, coalesce((p->>'tolerance_pct')::smallint, 10), kw, coalesce((p->>'rounding')::integer, 5000),
            coalesce((p->>'owner_share')::boolean, true), coalesce((p->>'auto_apply')::boolean, true), coalesce(p->'participants', '[]'::jsonb))
  on conflict (recurring_id) do update set window_start = excluded.window_start, window_end = excluded.window_end,
     tolerance_pct = excluded.tolerance_pct, payee_keywords = excluded.payee_keywords, rounding = excluded.rounding,
     owner_share = excluded.owner_share, auto_apply = excluded.auto_apply, participants = excluded.participants, updated_at = now();
  return res;
end $$;

-- Dispatcher: migration 014 + the four split commands.
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
    when 'RECURRING_SPLIT_UPSERT' then pf_private.cmd_recurring_split_upsert(p_owner, payload)
    when 'SPLIT_APPLY'      then pf_private.cmd_split_apply(p_owner, payload)
    when 'SPLIT_UNDO'       then pf_private.cmd_split_undo(p_owner, payload)
    when 'SPLIT_DISMISS'    then pf_private.cmd_split_dismiss(p_owner, payload)
    else null end;
  if res is null then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  res := res || jsonb_build_object('status', 'COMMITTED');
  update public.pf_command set result = res where owner_id = p_owner and command_id = p_command_id;
  return res;
end $$;

-- ---------------------------------------------------------------- Worker RPCs (server role only)

-- Same as SPLIT_APPLY for the Worker (automatic match, bill reader, /v1/splits/apply).
create function public.pf_split_apply(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.cmd_split_apply(p_owner, p);
end $$;

create function public.pf_split_undo(p_owner uuid, p_application uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.cmd_split_undo(p_owner, jsonb_build_object('application_id', p_application));
end $$;

create function public.pf_split_dismiss(p_owner uuid, p_application uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.cmd_split_dismiss(p_owner, jsonb_build_object('application_id', p_application));
end $$;

-- Stores a proposal the owner confirms with one tap. Replaces an older pending proposal for the same bill; never
-- overrides an applied split, and a rule the owner dismissed for this bill is not proposed again.
create function public.pf_split_propose(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx; a public.pf_split_application; rid uuid := nullif(p->>'recurring_id', '')::uuid;
begin
  perform pf_private.assert_owner(p_owner);
  select * into t from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.status <> 'POSTED' or t.kind not in ('EXPENSE', 'UNKNOWN_DEBIT') then perform pf_private.err('INVALID_STATE'); end if;
  if exists (select 1 from public.pf_split_application where tx_id = t.id and state = 'APPLIED') then perform pf_private.err('SPLIT_EXISTS'); end if;
  if rid is not null and exists (select 1 from public.pf_split_application where tx_id = t.id and recurring_id = rid and state = 'DISMISSED') then
    return jsonb_build_object('status', 'DISMISSED_BEFORE');
  end if;
  update public.pf_split_application set state = 'DISMISSED', decided_at = now(), version = version + 1
   where tx_id = t.id and state = 'PROPOSED';
  insert into public.pf_split_application(owner_id, tx_id, recurring_id, occurrence_id, source, state, confidence, total, category_id,
                                          shares, owner_amount, note, hints)
    values (p_owner, t.id, rid, nullif(p->>'occurrence_id', '')::uuid, coalesce(nullif(p->>'source', ''), 'MANUAL'), 'PROPOSED',
            least(greatest(coalesce((p->>'confidence')::numeric, 0.5), 0), 1), t.amount, nullif(p->>'category_id', '')::uuid,
            coalesce(p->'shares', '[]'::jsonb), coalesce((p->>'owner_amount')::bigint, 0), left(nullif(btrim(p->>'note'), ''), 300),
            coalesce(p->'hints', '[]'::jsonb))
    returning * into a;
  perform pf_private.touch_change(p_owner, 'split', a.id, a.version);
  return jsonb_build_object('status', 'PROPOSED', 'application_id', a.id);
end $$;

-- What the matcher needs about one bill: the transaction, whether it is already split / used, and the enabled rules
-- with their open occurrences (the caller syncs occurrences first).
create function public.pf_split_context(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx;
begin
  perform pf_private.assert_owner(p_owner);
  select * into t from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found then return null; end if;
  return jsonb_build_object(
    'tx', jsonb_build_object('id', t.id, 'kind', t.kind, 'status', t.status, 'amount', t.amount::text, 'account_id', t.account_id,
                             'effective_at', t.effective_at, 'note', t.note, 'merchant', t.merchant, 'category_id', t.category_id,
                             'source', t.source),
    'live', (select jsonb_build_object('id', a.id, 'state', a.state) from public.pf_split_application a
              where a.tx_id = t.id and a.state in ('PROPOSED', 'APPLIED')),
    'matched_occurrence', exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id),
    'dismissed_rules', coalesce((select jsonb_agg(distinct a.recurring_id) from public.pf_split_application a
                                  where a.tx_id = t.id and a.state = 'DISMISSED' and a.recurring_id is not null), '[]'::jsonb),
    'rules', pf_private.split_rules(p_owner, t.effective_at - interval '45 days', t.effective_at + interval '45 days'));
end $$;

-- Enabled expense rules with split settings, participant names and the expected occurrences in [p_from, p_to].
create function pf_private.split_rules(p_owner uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'name', r.name, 'amount', r.amount::text, 'account_id', r.account_id, 'interval', r.interval,
      'category_id', r.template->>'category_id',
      'window_start', s.window_start, 'window_end', s.window_end, 'tolerance_pct', coalesce(s.tolerance_pct, 10),
      'payee_keywords', to_jsonb(coalesce(s.payee_keywords, '{}')), 'rounding', coalesce(s.rounding, 5000),
      'owner_share', coalesce(s.owner_share, true), 'auto_apply', coalesce(s.auto_apply, true),
      'participants', coalesce((select jsonb_agg(x || jsonb_build_object('name', c.alias))
                                  from jsonb_array_elements(s.participants) x
                                  join public.pf_contact c on c.id = (x->>'contact_id')::uuid and not c.archived), '[]'::jsonb),
      'occurrences', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'due_date', o.due_date) order by o.due_date)
                                 from public.pf_occurrence o where o.recurring_id = r.id and o.state = 'EXPECTED'
                                  and o.due_date between (p_from at time zone 'Asia/Ho_Chi_Minh')::date and (p_to at time zone 'Asia/Ho_Chi_Minh')::date), '[]'::jsonb))
      order by r.name), '[]'::jsonb)
    from public.pf_recurring r left join public.pf_recurring_split s on s.recurring_id = r.id
   where r.owner_id = p_owner and r.enabled and r.kind = 'EXPENSE'
$$;

-- Splits for the app: by transaction, or every pending proposal (bell "Cần xử lý"), newest first.
create function public.pf_split_list(p_owner uuid, p_tx uuid, p_state text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'tx_id', a.tx_id, 'recurring_id', a.recurring_id, 'recurring_name', r.name, 'occurrence_id', a.occurrence_id,
      'source', a.source, 'state', a.state, 'confidence', a.confidence, 'total', a.total::text, 'category_id', a.category_id,
      'shares', a.shares, 'owner_amount', a.owner_amount::text, 'note', a.note, 'hints', a.hints,
      'created_at', a.created_at, 'decided_at', a.decided_at, 'version', a.version,
      'tx', jsonb_build_object('amount', t.amount::text, 'effective_at', t.effective_at, 'merchant', t.merchant, 'note', t.note,
                               'account_id', t.account_id, 'kind', t.kind, 'status', t.status),
      -- Undo stays possible while nobody has paid back yet.
      'can_undo', a.state = 'APPLIED' and not exists (select 1 from jsonb_array_elements(a.shares) x
                     join public.pf_debt d on d.id = nullif(x->>'debt_id', '')::uuid
                    where exists (select 1 from pf_private.debt_active_payments(d.id))))
      order by a.created_at desc)
    from (select * from public.pf_split_application x
           where x.owner_id = p_owner
             and (p_tx is null or x.tx_id = p_tx)
             and (p_state is null or x.state = p_state)
             and (p_tx is not null or p_state is not null or x.created_at > now() - interval '60 days')
           order by x.created_at desc limit 200) a
    join public.pf_tx t on t.id = a.tx_id
    left join public.pf_recurring r on r.id = a.recurring_id), '[]'::jsonb);
end $$;

-- Bill photo read: category / merchant / short item note set in place (TX_ANNOTATE rules of migration 015, same
-- transaction id). Returns what was there before so the app can offer "Hoàn tác".
create function public.pf_bill_annotate(p_owner uuid, p_tx uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx; res jsonb; args jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  select * into t from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  args := jsonb_build_object('tx_id', t.id, 'expected_version', t.version);
  if nullif(p->>'category_id', '') is not null then args := args || jsonb_build_object('category_id', p->>'category_id'); end if;
  if nullif(btrim(p->>'merchant'), '') is not null then args := args || jsonb_build_object('merchant', left(btrim(p->>'merchant'), 120)); end if;
  if p ? 'note' then args := args || jsonb_build_object('note', left(coalesce(p->>'note', ''), 1000)); end if;
  res := pf_private.cmd_tx_annotate(p_owner, args);
  return res || jsonb_build_object('previous', jsonb_build_object('kind', t.kind, 'category_id', t.category_id, 'merchant', t.merchant, 'note', t.note));
end $$;

-- Cron: money-out of the last p_hours that no split / occurrence has claimed yet (the matcher re-checks them; a rule
-- created after the payment, or a hook that failed, still gets its match).
create function public.pf_split_recent_debits(p_owner uuid, p_hours integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(t.id order by t.effective_at) from public.pf_tx t
    where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
      and t.effective_at > now() - make_interval(hours => least(greatest(coalesce(p_hours, 72), 1), 24 * 40))
      and not exists (select 1 from public.pf_split_application a where a.tx_id = t.id)
      and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)), '[]'::jsonb);
end $$;

-- Cron: rules whose window has passed (by up to 7 days) without a matched payment, for the "Chưa thấy..." push.
create function public.pf_split_missed(p_owner uuid, p_today date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('occurrence_id', o.id, 'recurring_id', r.id, 'name', r.name,
                                                       'amount', r.amount::text, 'due_date', o.due_date,
                                                       'window_start', s.window_start, 'window_end', s.window_end))
    from public.pf_occurrence o join public.pf_recurring r on r.id = o.recurring_id
    join public.pf_recurring_split s on s.recurring_id = r.id
   where r.owner_id = p_owner and r.enabled and o.state = 'EXPECTED'
     and make_date(extract(year from o.due_date)::int, extract(month from o.due_date)::int,
                   least(s.window_end, extract(day from (date_trunc('month', o.due_date) + interval '1 month - 1 day'))::int))
         between p_today - 7 and p_today - 1), '[]'::jsonb);
end $$;

-- "Có vẻ bạn trả 1.600.000đ vào ngày 6 hằng tháng — tạo quy tắc?": the same amount (±3%) paid from the same account in
-- at least 2 of the last 4 months, on similar days, not already covered by a rule.
create function public.pf_split_rule_suggestions(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(x order by x.months desc, x.amount desc) from (
    select g.account_id, round(avg(g.amount))::bigint::text as amount, count(distinct g.ym) as months,
           min(g.dom) as day_min, max(g.dom) as day_max,
           (array_agg(g.category_id order by g.effective_at desc))[1] as category_id,
           (array_agg(coalesce(nullif(g.merchant, ''), left(g.note, 60)) order by g.effective_at desc))[1] as label
      from (select t.account_id, t.amount, t.category_id, t.merchant, t.note, t.effective_at,
                   to_char(t.effective_at at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM') as ym,
                   extract(day from t.effective_at at time zone 'Asia/Ho_Chi_Minh')::int as dom,
                   round(t.amount / 50000.0) as bucket
              from public.pf_tx t
             where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
               and t.amount >= 200000 and t.effective_at > now() - interval '125 days') g
     group by g.account_id, g.bucket
    having count(distinct g.ym) >= 2 and max(g.dom) - min(g.dom) <= 7
       and max(g.amount) <= min(g.amount) * 1.03
       and not exists (select 1 from public.pf_recurring r where r.owner_id = p_owner and r.enabled and r.kind = 'EXPENSE'
                        and r.amount between min(g.amount) * 0.9 and max(g.amount) * 1.1)) x), '[]'::jsonb);
end $$;

-- Recurring list (migration 003) + the split settings and the latest automatic match of each rule.
create or replace function public.pf_read_recurring(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'kind', r.kind, 'account_id', r.account_id, 'amount', r.amount::text,
      'interval', r.interval, 'next_date', r.next_date, 'enabled', r.enabled, 'template', r.template, 'version', r.version,
      'expected', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'due_date', o.due_date, 'version', o.version) order by o.due_date)
                              from public.pf_occurrence o where o.recurring_id = r.id and o.state = 'EXPECTED'), '[]'::jsonb),
      'split', (select jsonb_build_object('window_start', s.window_start, 'window_end', s.window_end, 'tolerance_pct', s.tolerance_pct,
                                          'payee_keywords', to_jsonb(s.payee_keywords), 'rounding', s.rounding, 'owner_share', s.owner_share,
                                          'auto_apply', s.auto_apply,
                                          'participants', coalesce((select jsonb_agg(x || jsonb_build_object('name', c.alias))
                                                                      from jsonb_array_elements(s.participants) x
                                                                      join public.pf_contact c on c.id = (x->>'contact_id')::uuid), '[]'::jsonb))
                  from public.pf_recurring_split s where s.recurring_id = r.id),
      'last_application', (select jsonb_build_object('id', a.id, 'tx_id', a.tx_id, 'state', a.state, 'created_at', a.created_at,
                                                     'total', a.total::text, 'shares', a.shares)
                             from public.pf_split_application a where a.recurring_id = r.id and a.state in ('APPLIED', 'PROPOSED')
                            order by a.created_at desc limit 1)) order by r.name)
    from public.pf_recurring r where r.owner_id = p_owner), '[]'::jsonb);
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

-- ===================================================== 20261128000018_same_payment.sql
-- MoMa migration 018: one payment seen twice becomes ONE transaction (D-024).
-- Paying in MoMo / Grab / ShopeePay... with a linked bank (VCB...) produces two debits for the same money: the bank's
-- (content = the wallet's reference code, unreadable) and the wallet / app "thanh toán thành công" notification. Apps
-- also re-post a notification under a new key. Both used to be recorded, so spending was counted twice and the
-- wallet's balance went wrong.
--
-- A "same payment" pair = same direction, exact same amount, effective times <= 10 minutes apart, both POSTED and free
-- (no debt, occurrence, split, own-account transfer or earlier same-payment decision), never rejected before, and:
--   * same account: the same bank reference, or both from notifications (a re-post), or one typed by hand / by the
--     assistant and one captured (suggestion only);
--   * different accounts (money out only): one side is a wallet account, or the bank content names a payment
--     intermediary (MoMo, ZaloPay, ShopeePay, VNPAY, Grab...) or the other account;
--   * never when both carry bank references and they differ, when either content says top-up / transfer ("nạp tiền",
--     "chuyển tiền", "rút tiền"...), or when the wallet received the same amount within 15 minutes (a top-up then a
--     payment is an own-account transfer + an expense, migration 010).
-- Keep = the side where the money really moved (bank account over wallet, BANK over NOTIFICATION, the one already
-- classified over an unclassified one, then the earlier one). Dup = the other side.
-- Merge: keep is enriched with dup's category (when keep is unclassified, in place: same id, migration 015's
-- tx_reclassify), merchant and note; dup's receipt pictures move to keep; dup is reversed (history kept).
-- AUTO when unique both ways and certain: same reference; or different accounts <= 5 min with an intermediary /
-- account hint; or a wallet side <= 2 min; or a re-post with identical content <= 3 min. Otherwise SUGGESTED (the
-- ledger is unchanged until the owner accepts). Undo restores dup, reverts the enrichment if keep was not edited
-- since, and marks the pair REJECTED so the same two transactions are never matched again.
-- Hooked into pf_transfer_try_pair / pf_transfer_sweep (after own-account pairing found nothing), which the API
-- already calls after every bank event, captured notification and in the 15-minute sweep.
-- Keyword lists: pf_private.same_intermediaries() / same_topup_words() (one place to tune).
-- Requires migrations 010 (transfer helpers), 013 (attachments), 015 (tx_reclassify), 016 (split applications).
-- Server role only.
begin;

create table public.pf_same_payment (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  keep_tx uuid not null references public.pf_tx(id),
  dup_tx uuid not null references public.pf_tx(id),
  state text not null check (state in ('AUTO', 'CONFIRMED', 'SUGGESTED', 'REJECTED')),
  score integer not null default 0,
  hints text[] not null default '{}',
  -- keep's descriptive fields before / after the merge (undo restores "before" only if keep still equals "after")
  keep_before jsonb,
  keep_after jsonb,
  moved_attachments uuid[] not null default '{}',
  restored_dup uuid references public.pf_tx(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (keep_tx, dup_tx),
  check (keep_tx <> dup_tx)
);
create index pf_same_payment_owner_idx on public.pf_same_payment(owner_id, state, created_at desc);
create index pf_same_payment_dup_idx on public.pf_same_payment(dup_tx);
alter table public.pf_same_payment enable row level security;
revoke all on table public.pf_same_payment from public, anon, authenticated;
grant select on table public.pf_same_payment to service_role;
revoke insert, update, delete, truncate on table public.pf_same_payment from service_role;

-- ---------------------------------------------------------------- tunable word lists (normalised: pf_private.ai_norm)
-- Payment apps that charge a linked bank account: the bank's content names them (or carries their code).
create function pf_private.same_intermediaries() returns text[] language sql immutable as $$
  select array['momo', 'zalopay', 'zalo pay', 'shopeepay', 'shopee pay', 'shopee', 'airpay', 'vnpay', 'vnpayqr', 'vnpay qr',
               'grab', 'grabpay', 'grab pay', 'moca', 'viettel money', 'viettelpay', 'viettel pay', 'begroup', 'be group',
               'payoo', 'apple com bill', 'apple', 'google', 'smartpay', 'foxpay', 'vimo', 'onepay', 'napas247 qr', 'qr pay',
               'thanh toan qr', 'tt qr', 'thanh toan don hang', 'payment']
$$;

-- Words that mean money moved between accounts (top-up, withdrawal, transfer), never a purchase seen twice.
create function pf_private.same_topup_words() returns text[] language sql immutable as $$
  select array['nap tien', 'nap vi', 'chuyen tien', 'rut tien', 'nhan tien', 'chuyen khoan noi bo', 'top up', 'topup',
               'nap tk', 'chuyen tu', 'chuyen den', 'hoan tien', 'refund']
$$;

-- Words of a purchase (a bank debit naming a wallet with these is a payment through it, never a top-up).
create function pf_private.same_payment_words() returns text[] language sql immutable as $$
  select array['thanh toan', 'tt qr', 'thanh toan qr', 'payment', 'mua hang', 'don hang', 'hoa don', 'purchase', 'pos']
$$;

create function pf_private.same_has_any(p_text text, p_words text[]) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select exists (select 1 from unnest(p_words) w where position(' ' || w || ' ' in p_text) > 0)
$$;

-- Content without digits-only tokens (times, dates, balances, codes): what two copies of one notification share.
create function pf_private.same_content(t public.pf_tx) returns text
language sql stable set search_path = pg_catalog, public as $$
  select btrim(regexp_replace(' ' || pf_private.ai_norm(concat_ws(' ', t.note, t.merchant)) || ' ', '( [0-9]+)+ ', ' ', 'g'))
$$;

-- ---------------------------------------------------------------- matching
create function pf_private.same_leg_ok(t public.pf_tx) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select t.status = 'POSTED'
     and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT', 'INCOME', 'UNKNOWN_CREDIT')
     and t.source in ('BANK', 'NOTIFICATION', 'MANUAL', 'AI', 'IMPORT')
     and t.account_id is not null and t.amount is not null
     and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
     and not exists (select 1 from public.pf_debt_payment p where p.tx_id = t.id)
     and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)
     and not exists (select 1 from public.pf_split_application a where a.tx_id = t.id and a.state in ('PROPOSED', 'APPLIED'))
     and not exists (select 1 from public.pf_transfer_pair p where p.state <> 'REJECTED' and t.id in (p.out_tx, p.in_tx))
     and not exists (select 1 from public.pf_same_payment s where s.state in ('AUTO', 'CONFIRMED') and t.id in (s.keep_tx, s.dup_tx))
     and exists (select 1 from public.pf_account a where a.id = t.account_id and not a.archived)
$$;

create function pf_private.same_rejected(a uuid, b uuid) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select exists (select 1 from public.pf_same_payment s where s.state = 'REJECTED'
    and ((s.keep_tx = a and s.dup_tx = b) or (s.keep_tx = b and s.dup_tx = a)
      or (s.keep_tx = a and s.restored_dup = b) or (s.keep_tx = b and s.restored_dup = a)))
$$;

-- Which of x / y keeps the money (true = x). Bank account over wallet, BANK over NOTIFICATION over typed, the
-- classified one over an unclassified one, then the earlier one.
create function pf_private.same_keep_first(x public.pf_tx, y public.pf_tx) returns boolean
language plpgsql stable set search_path = pg_catalog, public as $$
declare xw boolean; yw boolean; rx integer; ry integer;
begin
  select kind = 'WALLET' into xw from public.pf_account where id = x.account_id;
  select kind = 'WALLET' into yw from public.pf_account where id = y.account_id;
  if xw is distinct from yw then return not coalesce(xw, false); end if;
  rx := case x.source when 'BANK' then 0 when 'NOTIFICATION' then 1 else 2 end;
  ry := case y.source when 'BANK' then 0 when 'NOTIFICATION' then 1 else 2 end;
  if rx <> ry then return rx < ry; end if;
  if (x.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')) <> (y.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')) then
    return x.kind not in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT');
  end if;
  return (x.effective_at, x.id::text) <= (y.effective_at, y.id::text);
end $$;

-- Possible other copies of p_tx. c_auto = strong enough for an automatic merge (uniqueness is checked by the caller).
create function pf_private.same_candidates(p_owner uuid, p_tx uuid)
returns table (c_tx uuid, c_keep uuid, c_dup uuid, c_seconds numeric, c_hints text[], c_score integer, c_auto boolean)
language plpgsql stable set search_path = pg_catalog, public as $$
declare x public.pf_tx; y public.pf_tx; x_out boolean; x_refs text[]; y_refs text[]; secs numeric; h text[]; tx text; ty text;
        same_acc boolean; x_wallet boolean; y_wallet boolean; score integer; auto boolean; captured_x boolean; captured_y boolean;
begin
  select * into x from public.pf_tx t where t.id = p_tx and t.owner_id = p_owner;
  if not found or not pf_private.same_leg_ok(x) then return; end if;
  x_out := x.kind in ('EXPENSE', 'UNKNOWN_DEBIT');
  x_refs := pf_private.transfer_refs(x.id);
  tx := ' ' || pf_private.ai_norm(concat_ws(' ', x.note, x.merchant)) || ' ';
  select kind = 'WALLET' into x_wallet from public.pf_account where id = x.account_id;
  captured_x := x.source in ('BANK', 'NOTIFICATION');
  for y in
    select t.* from public.pf_tx t
     where t.owner_id = p_owner and t.id <> x.id and t.status = 'POSTED' and t.amount = x.amount
       and t.effective_at between x.effective_at - interval '10 minutes' and x.effective_at + interval '10 minutes'
       and ((x_out and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')) or (not x_out and t.kind in ('INCOME', 'UNKNOWN_CREDIT')))
  loop
    if not pf_private.same_leg_ok(y) or pf_private.same_rejected(x.id, y.id) then continue; end if;
    captured_y := y.source in ('BANK', 'NOTIFICATION');
    if not (captured_x or captured_y) then continue; end if;          -- two typed entries: the owner meant both
    y_refs := pf_private.transfer_refs(y.id);
    if cardinality(x_refs) > 0 and cardinality(y_refs) > 0 and not (x_refs && y_refs) then continue; end if;
    ty := ' ' || pf_private.ai_norm(concat_ws(' ', y.note, y.merchant)) || ' ';
    if pf_private.same_has_any(tx || ty, pf_private.same_topup_words()) then continue; end if;
    secs := abs(extract(epoch from (y.effective_at - x.effective_at)))::numeric;
    same_acc := y.account_id = x.account_id;
    select kind = 'WALLET' into y_wallet from public.pf_account where id = y.account_id;
    h := '{}';
    if cardinality(x_refs) > 0 and x_refs && y_refs then h := array_append(h, 'reference'); end if;
    if same_acc then
      if 'reference' = any(h) then
        null;
      elsif x.source = 'NOTIFICATION' and y.source = 'NOTIFICATION' then
        h := array_append(h, 'repost');
        if pf_private.same_content(x) <> '' and pf_private.same_content(x) = pf_private.same_content(y) then
          h := array_append(h, 'same_content');
        end if;
      elsif captured_x <> captured_y and x.source in ('BANK', 'NOTIFICATION', 'MANUAL', 'AI') and y.source in ('BANK', 'NOTIFICATION', 'MANUAL', 'AI') then
        h := array_append(h, 'typed_and_captured');
      else
        continue;                                                      -- e.g. two SePay events (already unique by reference)
      end if;
    else
      if not x_out then continue; end if;                              -- cross-account copies are payments (money out)
      -- a top-up into the wallet side within 15 minutes = own-account transfer + expense (migration 010)
      if exists (select 1 from public.pf_tx w where w.owner_id = p_owner and w.status = 'POSTED' and w.amount = x.amount
                   and w.kind in ('INCOME', 'UNKNOWN_CREDIT', 'TRANSFER')
                   and (w.account_id in (case when x_wallet then x.account_id end, case when y_wallet then y.account_id end)
                        or w.to_account_id in (case when x_wallet then x.account_id end, case when y_wallet then y.account_id end))
                   and w.effective_at between least(x.effective_at, y.effective_at) - interval '15 minutes'
                                          and greatest(x.effective_at, y.effective_at) + interval '15 minutes') then
        continue;
      end if;
      if coalesce(x_wallet, false) or coalesce(y_wallet, false) then h := array_append(h, 'wallet'); end if;
      if pf_private.same_has_any(tx || ty, pf_private.same_intermediaries()) then h := array_append(h, 'intermediary'); end if;
      if pf_private.transfer_mentions(tx, y.account_id) or pf_private.transfer_mentions(ty, x.account_id) then
        h := array_append(h, 'account');
      end if;
      if not (h && array['reference', 'wallet', 'intermediary', 'account']) then continue; end if;
    end if;
    score := case when 'reference' = any(h) then 100 else
               (case when secs <= 60 then 50 when secs <= 180 then 40 when secs <= 300 then 30 else 15 end)
             + (case when 'same_content' = any(h) then 40 else 0 end)
             + (case when 'intermediary' = any(h) then 30 else 0 end)
             + (case when 'account' = any(h) then 25 else 0 end)
             + (case when 'wallet' = any(h) then 15 else 0 end) end;
    auto := 'reference' = any(h)
         or ('same_content' = any(h) and secs <= 180)
         or (not same_acc and secs <= 300 and h && array['intermediary', 'account'])
         or (not same_acc and secs <= 120 and 'wallet' = any(h));
    if 'typed_and_captured' = any(h) and not ('reference' = any(h)) then auto := false; end if;
    c_tx := y.id;
    if pf_private.same_keep_first(x, y) then c_keep := x.id; c_dup := y.id; else c_keep := y.id; c_dup := x.id; end if;
    c_seconds := secs; c_hints := h; c_score := least(score, 100); c_auto := auto;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------- ledger moves
-- Puts t back to unclassified money in/out (category leg -> suspense), same id. Used by undo only.
create function pf_private.same_unclassify(p_owner uuid, t public.pf_tx) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare old_leg uuid; new_leg uuid; lines jsonb; old_eff timestamptz; nj uuid; new_kind public.pf_tx_kind;
begin
  if t.status <> 'POSTED' or t.kind not in ('EXPENSE', 'INCOME') or t.category_id is null then return; end if;
  select ledger_account_id into old_leg from public.pf_category where id = t.category_id;
  new_kind := case when t.kind = 'EXPENSE' then 'UNKNOWN_DEBIT' else 'UNKNOWN_CREDIT' end;
  new_leg := pf_private.sys_ledger(p_owner, case when t.kind = 'EXPENSE' then 'SYS_SUSPENSE_DEBIT' else 'SYS_SUSPENSE_CREDIT' end);
  if old_leg is null or new_leg is null
     or not exists (select 1 from public.pf_entry where journal_id = t.current_journal_id and ledger_account_id = old_leg) then
    return;
  end if;
  select effective_at into old_eff from public.pf_journal where id = t.current_journal_id;
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo để tách khoản trùng') order by line_no)
    into lines from public.pf_entry where journal_id = t.current_journal_id;
  perform pf_private.post_journal(p_owner, t.id, old_eff, 'REVERSAL', lines, t.current_journal_id);
  select jsonb_agg(jsonb_build_object('ledger_account_id', case when e.ledger_account_id = old_leg then new_leg else e.ledger_account_id end,
                                      'signed_amount', e.signed_amount::text) order by e.line_no)
    into lines from public.pf_entry e where e.journal_id = t.current_journal_id;
  nj := pf_private.post_journal(p_owner, t.id, old_eff, 'REPLACEMENT', lines);
  update public.pf_tx set current_journal_id = nj, category_id = null, kind = new_kind where id = t.id;
end $$;

create function pf_private.same_snapshot(t public.pf_tx) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('kind', t.kind, 'category_id', t.category_id, 'merchant', t.merchant, 'note', t.note,
    'cls', (select to_jsonb(c) from public.pf_tx_classification c where c.tx_id = t.id))
$$;

-- A merchant that is only the raw bank content / a reference code (what bank ingest stores when nothing better is
-- known): the other copy's real merchant name replaces it.
create function pf_private.same_raw_merchant(t public.pf_tx) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(btrim(t.merchant), '') = ''
      or pf_private.ai_norm(t.merchant) = pf_private.ai_norm(t.note)
      or upper(t.merchant) ~ '[A-Z0-9]{10,}' and upper(t.merchant) ~ '[0-9]{6,}'
      or upper(t.merchant) ~ '^(MBVCB|IBFT|FT[0-9]|TKThe|TK |CT )'
$$;

-- The owner (not the classifier) decided this transaction's category.
create function pf_private.same_owner_classified(t public.pf_tx) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select t.source in ('MANUAL', 'IMPORT')
      or exists (select 1 from public.pf_tx_classification c where c.tx_id = t.id and c.status in ('CONFIRMED', 'CORRECTED'))
$$;

-- Merges dup into keep. Returns {keep_before, keep_after, moved}.
create function pf_private.same_merge(p_owner uuid, p_keep uuid, p_dup uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare k public.pf_tx; d public.pf_tx; c public.pf_category; before jsonb; nt text; mv uuid[]; acc text; v integer;
begin
  perform 1 from public.pf_tx where id in (p_keep, p_dup) and owner_id = p_owner order by id for update;
  select * into k from public.pf_tx where id = p_keep and owner_id = p_owner;
  select * into d from public.pf_tx where id = p_dup and owner_id = p_owner;
  if k.id is null or d.id is null then perform pf_private.err('NOT_FOUND'); end if;
  if not pf_private.same_leg_ok(k) or not pf_private.same_leg_ok(d) or k.amount <> d.amount
     or (k.kind in ('EXPENSE', 'UNKNOWN_DEBIT')) <> (d.kind in ('EXPENSE', 'UNKNOWN_DEBIT')) then
    perform pf_private.err('INVALID_STATE');
  end if;
  before := pf_private.same_snapshot(k);
  select coalesce(nullif(name, ''), institution) into acc from public.pf_account where id = k.account_id;
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', d.id, 'reason',
            'Trùng với giao dịch ở ' || coalesce(acc, 'tài khoản khác') || ' — đã gộp', 'expected_version', d.version));
  -- category: dup knows it and keep is unclassified or only guessed by the classifier (an opaque bank code is a
  -- weaker signal than the wallet's own receipt); never over the owner's own choice
  if d.category_id is not null and d.category_id is distinct from k.category_id
     and (k.kind in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT')
          or (not pf_private.same_owner_classified(k)
              and exists (select 1 from public.pf_tx_classification cl where cl.tx_id = k.id and cl.status in ('APPLIED', 'SUGGESTED')))) then
    select * into c from public.pf_category where id = d.category_id and owner_id = p_owner and not archived;
    if found then
      perform pf_private.tx_reclassify(p_owner, k, c);
      -- carry the decision over (migration 015): an owner-confirmed category stays confirmed, anything else is a rule
      -- application; notified_at set so the merged transaction never triggers a "chưa rõ loại" push.
      insert into public.pf_tx_classification(tx_id, owner_id, status, category_id, merchant, confidence, method, reason, notified_at)
      select k.id, p_owner,
             case when dc.status in ('CONFIRMED', 'CORRECTED') or d.source in ('MANUAL', 'AI') then 'CONFIRMED' else 'APPLIED' end,
             c.id, nullif(btrim(d.merchant), ''), coalesce(dc.confidence, 0.9),
             case when dc.status in ('CONFIRMED', 'CORRECTED') or d.source = 'MANUAL' then 'OWNER' else 'RULE' end,
             left('Lấy từ khoản trùng đã gộp', 300), now()
        from (select 1) one left join public.pf_tx_classification dc on dc.tx_id = d.id
      on conflict (tx_id) do update set status = excluded.status, category_id = excluded.category_id,
        merchant = coalesce(excluded.merchant, public.pf_tx_classification.merchant), confidence = excluded.confidence,
        method = excluded.method, reason = excluded.reason, notified_at = coalesce(public.pf_tx_classification.notified_at, now()),
        updated_at = now();
    end if;
  end if;
  nt := case
    when coalesce(btrim(d.note), '') = '' or position(btrim(d.note) in coalesce(k.note, '')) > 0 then k.note
    when coalesce(btrim(k.note), '') = '' then d.note
    else k.note || ' / ' || d.note end;
  update public.pf_tx set note = left(nt, 1000),
         merchant = case when nullif(btrim(d.merchant), '') is not null and pf_private.same_raw_merchant(k)
                              and not pf_private.same_raw_merchant(d)
                         then left(btrim(d.merchant), 120) else merchant end,
         version = version + 1, updated_at = now()
   where id = k.id returning * into k;
  v := k.version;
  perform pf_private.touch_change(p_owner, 'transaction', k.id, v);
  -- receipt pictures follow the transaction that stays
  with m as (update public.pf_tx_attachment set tx_id = k.id where tx_id = d.id and owner_id = p_owner returning id)
  select coalesce(array_agg(id), '{}') into mv from m;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'system', 'SAME_PAYMENT_MERGE', k.id, jsonb_build_object('dup_tx', d.id));
  return jsonb_build_object('keep_before', before, 'keep_after', pf_private.same_snapshot(k), 'moved', to_jsonb(mv));
end $$;

-- Entry point after a money-in/out transaction appears (and in the sweep). Same lock as transfer pairing.
-- Returns {status: NONE | AUTO | SUGGESTED, same_id?, keep_tx_id?, suggested?}.
create function pf_private.try_same_payment(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare n integer; back integer; best record; c record; sid uuid; res jsonb; k integer := 0; other uuid;
begin
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select count(*) into n from pf_private.same_candidates(p_owner, p_tx);
  if n = 0 then return jsonb_build_object('status', 'NONE'); end if;
  if n = 1 then
    select * into best from pf_private.same_candidates(p_owner, p_tx);
    select count(*) into back from pf_private.same_candidates(p_owner, best.c_tx);
    if best.c_auto and back = 1 then
      res := pf_private.same_merge(p_owner, best.c_keep, best.c_dup);
      insert into public.pf_same_payment(owner_id, keep_tx, dup_tx, state, score, hints, keep_before, keep_after, moved_attachments, decided_at)
        values (p_owner, best.c_keep, best.c_dup, 'AUTO', best.c_score, best.c_hints, res->'keep_before', res->'keep_after',
                coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(res->'moved')), '{}'), now())
        on conflict (keep_tx, dup_tx) do update set state = 'AUTO', score = excluded.score, hints = excluded.hints,
          keep_before = excluded.keep_before, keep_after = excluded.keep_after, moved_attachments = excluded.moved_attachments,
          decided_at = now()
        returning id into sid;
      return jsonb_build_object('status', 'AUTO', 'same_id', sid, 'keep_tx_id', best.c_keep);
    end if;
  end if;
  for c in select * from pf_private.same_candidates(p_owner, p_tx) order by c_score desc, c_seconds, c_tx limit 3 loop
    sid := null;
    insert into public.pf_same_payment(owner_id, keep_tx, dup_tx, state, score, hints)
      values (p_owner, c.c_keep, c.c_dup, 'SUGGESTED', c.c_score, c.c_hints)
      on conflict (keep_tx, dup_tx) do nothing returning id into sid;
    if sid is not null then k := k + 1; end if;
  end loop;
  return jsonb_build_object('status', case when k > 0 then 'SUGGESTED' else 'NONE' end, 'suggested', k);
end $$;

-- Migration 010's one-leg transfer step, plus: never while the leg is part of a same-payment suggestion (a bank debit
-- naming the wallet that also reported the purchase is one payment, not a top-up).
create or replace function pf_private.try_single_leg(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare x public.pf_tx; other uuid; tid uuid; pid uuid; x_in boolean;
begin
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into x from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found or not pf_private.transfer_leg_ok(x) or x.source not in ('BANK', 'NOTIFICATION')
     or x.effective_at > now() - interval '15 minutes' then
    return jsonb_build_object('status', 'NONE');
  end if;
  if exists (select 1 from public.pf_transfer_pair p where x.id in (p.out_tx, p.in_tx, p.restored_out, p.restored_in))
     or exists (select 1 from pf_private.transfer_candidates(p_owner, x.id))
     -- any same-payment decision (also a rejected one: the owner looked at this leg) or a possible copy
     or exists (select 1 from public.pf_same_payment s where x.id in (s.keep_tx, s.dup_tx, s.restored_dup))
     or exists (select 1 from pf_private.same_candidates(p_owner, x.id)) then
    return jsonb_build_object('status', 'NONE');
  end if;
  -- "MOMO 1234567890 THANH TOAN" is a purchase paid through the wallet app with this bank, not a top-up
  if x.kind in ('EXPENSE', 'UNKNOWN_DEBIT') and pf_private.same_has_any(
       ' ' || pf_private.ai_norm(concat_ws(' ', x.note, x.merchant)) || ' ', pf_private.same_payment_words())
     and not pf_private.same_has_any(' ' || pf_private.ai_norm(concat_ws(' ', x.note, x.merchant)) || ' ', pf_private.same_topup_words()) then
    return jsonb_build_object('status', 'NONE');
  end if;
  other := pf_private.transfer_own_counterpart(p_owner, x);
  if other is null then return jsonb_build_object('status', 'NONE'); end if;
  x_in := x.kind in ('INCOME', 'UNKNOWN_CREDIT');
  tid := pf_private.transfer_convert_single(p_owner, x.id, other);
  insert into public.pf_transfer_pair(owner_id, out_tx, in_tx, synth_account, transfer_tx, state, score, hints, decided_at)
    values (p_owner, case when x_in then null else x.id end, case when x_in then x.id else null end, other, tid, 'AUTO', 80,
            array['single_leg'] || pf_private.transfer_hints(p_owner, x.id, x.id), now())
    returning id into pid;
  return jsonb_build_object('status', 'AUTO', 'single', true, 'pair_id', pid, 'transfer_tx_id', tid);
end $$;

-- ---------------------------------------------------------------- hooks (replace migration 010's public entry points)
create or replace function public.pf_transfer_try_pair(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare res jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  res := pf_private.try_pair_transfer(p_owner, p_tx);
  if res->>'status' = 'NONE' then
    res := pf_private.try_same_payment(p_owner, p_tx);
    if res->>'status' <> 'NONE' then res := res || jsonb_build_object('kind', 'SAME_PAYMENT'); end if;
  end if;
  return res;
end $$;

create or replace function public.pf_transfer_sweep(p_owner uuid, p_hours integer) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; res jsonb; checked integer := 0; auto integer := 0; suggested integer := 0; failed integer := 0;
begin
  perform pf_private.assert_owner(p_owner);
  for r in select t.id from public.pf_tx t
            where t.owner_id = p_owner and t.status = 'POSTED' and t.source in ('BANK', 'NOTIFICATION')
              and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT', 'INCOME', 'UNKNOWN_CREDIT')
              and t.effective_at >= now() - make_interval(hours => least(greatest(coalesce(p_hours, 48), 1), 168))
            order by t.effective_at, t.id loop
    checked := checked + 1;
    begin
      res := pf_private.try_pair_transfer(p_owner, r.id);
      if res->>'status' = 'NONE' then res := pf_private.try_single_leg(p_owner, r.id); end if;
      if res->>'status' = 'NONE' then res := pf_private.try_same_payment(p_owner, r.id); end if;
      if res->>'status' in ('AUTO', 'ABSORBED') then auto := auto + 1;
      elsif res->>'status' = 'SUGGESTED' then suggested := suggested + coalesce((res->>'suggested')::integer, 0);
      end if;
    exception when others then
      failed := failed + 1;
    end;
  end loop;
  return jsonb_build_object('checked', checked, 'auto', auto, 'suggested', suggested, 'failed', failed);
end $$;

-- ---------------------------------------------------------------- read / decide / undo
create function pf_private.same_json(s public.pf_same_payment) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', s.id, 'state', s.state, 'score', s.score, 'hints', to_jsonb(s.hints),
    'created_at', s.created_at, 'decided_at', s.decided_at,
    'keep', (select pf_private.transfer_leg_json(t) from public.pf_tx t where t.id = s.keep_tx),
    'dup', (select pf_private.transfer_leg_json(t) from public.pf_tx t where t.id = s.dup_tx),
    'can_undo', s.state in ('AUTO', 'CONFIRMED') and exists (select 1 from public.pf_tx t where t.id = s.keep_tx and t.status = 'POSTED'))
$$;

create function public.pf_same_payment_suggestions(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.same_json(s) order by s.created_at desc, s.id) from (
      select s.* from public.pf_same_payment s
        join public.pf_tx k on k.id = s.keep_tx join public.pf_tx d on d.id = s.dup_tx
       where s.owner_id = p_owner and s.state = 'SUGGESTED' and k.status = 'POSTED' and d.status = 'POSTED'
       order by s.created_at desc limit 50) s), '[]'::jsonb);
end $$;

-- The merge a transaction took part in (as the kept or the merged-away side), or null.
create function public.pf_same_payment_for_tx(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare s public.pf_same_payment;
begin
  perform pf_private.assert_owner(p_owner);
  select * into s from public.pf_same_payment where owner_id = p_owner and state in ('AUTO', 'CONFIRMED')
     and p_tx in (keep_tx, dup_tx) order by decided_at desc nulls last limit 1;
  if not found then return null; end if;
  return pf_private.same_json(s);
end $$;

create function public.pf_same_payment_decide(p_owner uuid, p_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_same_payment; res jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  if p_accept is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into s from public.pf_same_payment where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if s.state <> 'SUGGESTED' then perform pf_private.err('INVALID_STATE'); end if;
  if not p_accept then
    update public.pf_same_payment set state = 'REJECTED', decided_at = now() where id = s.id;
    insert into public.pf_audit(owner_id, actor, action, target_id) values (p_owner, 'owner', 'SAME_PAYMENT_REJECT', s.id);
    return jsonb_build_object('id', s.id, 'state', 'REJECTED');
  end if;
  res := pf_private.same_merge(p_owner, s.keep_tx, s.dup_tx); -- INVALID_STATE when a side changed meanwhile
  update public.pf_same_payment set state = 'CONFIRMED', keep_before = res->'keep_before', keep_after = res->'keep_after',
         moved_attachments = coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(res->'moved')), '{}'),
         decided_at = now()
   where id = s.id;
  -- other open suggestions involving these two are moot now
  update public.pf_same_payment set state = 'REJECTED', decided_at = now()
   where owner_id = p_owner and state = 'SUGGESTED' and id <> s.id
     and (keep_tx in (s.keep_tx, s.dup_tx) or dup_tx in (s.keep_tx, s.dup_tx));
  return jsonb_build_object('id', s.id, 'state', 'CONFIRMED', 'keep_tx_id', s.keep_tx);
end $$;

-- Splits a merge back: dup is re-created, keep's category / merchant / note go back to what they were (only the
-- fields the owner has not changed since), pictures move to the restored copy, REJECTED.
create function public.pf_same_payment_undo(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_same_payment; k public.pf_tx; d public.pf_tx; c public.pf_category; rd uuid; b jsonb; a jsonb; v integer;
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into s from public.pf_same_payment where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if s.state not in ('AUTO', 'CONFIRMED') then perform pf_private.err('INVALID_STATE'); end if;
  select * into k from public.pf_tx where id = s.keep_tx and owner_id = p_owner for update;
  select * into d from public.pf_tx where id = s.dup_tx and owner_id = p_owner;
  if k.id is null or k.status <> 'POSTED' or d.id is null then perform pf_private.err('INVALID_STATE'); end if;
  b := s.keep_before; a := s.keep_after;
  -- category back to what it was, only if the merge changed it and nobody changed it since
  if b is not null and k.category_id::text is not distinct from a->>'category_id'
     and (b->>'category_id') is distinct from (a->>'category_id') then
    if b->>'kind' in ('UNKNOWN_DEBIT', 'UNKNOWN_CREDIT') then
      perform pf_private.same_unclassify(p_owner, k);
    else
      select * into c from public.pf_category where id = (b->>'category_id')::uuid and owner_id = p_owner;
      if found then perform pf_private.tx_reclassify(p_owner, k, c); end if;
    end if;
    -- the classifier's record goes back too (or disappears when there was none)
    delete from public.pf_tx_classification where tx_id = k.id;
    if jsonb_typeof(b->'cls') = 'object' then
      insert into public.pf_tx_classification select * from jsonb_populate_record(null::public.pf_tx_classification, b->'cls');
    end if;
  end if;
  update public.pf_tx set
         note = case when note is not distinct from a->>'note' then b->>'note' else note end,
         merchant = case when merchant is not distinct from a->>'merchant' then b->>'merchant' else merchant end,
         version = version + 1, updated_at = now()
   where id = k.id returning version into v;
  perform pf_private.touch_change(p_owner, 'transaction', k.id, v);
  rd := pf_private.transfer_restore(p_owner, d);
  update public.pf_tx_attachment set tx_id = rd where owner_id = p_owner and id = any(s.moved_attachments) and tx_id = k.id;
  update public.pf_same_payment set state = 'REJECTED', restored_dup = rd, decided_at = now() where id = s.id;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'SAME_PAYMENT_UNDO', s.id, jsonb_build_object('keep_tx', k.id, 'restored_dup', rd));
  return jsonb_build_object('id', s.id, 'state', 'REJECTED', 'keep_tx_id', k.id, 'restored_tx_id', rd);
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

-- ===================================================== 20261128000019_collect_goals.sql
-- MoMa migration 019 (1.3.0, D-025): polite debt collection with QR + automatic settlement, and self-running savings
-- goals.
--
-- Collection:
--   * Every open debt gets a short memo code ("MOMA 8F3A2B") printed in the reminder's VietQR. Money that arrives with
--     that code is certainly that debt.
--   * New money-in (bank / SePay / notification / import / manual / assistant) is matched against open RECEIVABLE debts,
--     money-out against open PAYABLE debts: memo code (certain), the person's full name in the content (strong), the
--     outstanding amount (full / partial) and "expected" (overdue or reminded in the last 30 days).
--     Certain or strong + unique -> AUTO: the captured transaction is reversed (history kept) and a DEBT_REPAY is posted
--     on the same account, amount and time, so the money is counted once (as a repayment, not as income / expense).
--     Weaker -> SUGGESTED, the ledger is untouched until the owner accepts. Undo re-creates the original transaction
--     and reverses the repayment; the pair is never suggested again.
--   * Reminder schedule per debt (remind count, last reminded, snooze) and a learned delay per person (how many days
--     they usually take to pay back).
--   * The creditor's bank account per contact, for "Trả ngay".
-- Goals:
--   * Plan per active goal (required monthly saving, ETA from the last 90 days, on track).
--   * Proposals "Trích X vào mục tiêu Y?" on income (salary) and on month-end under-spend; accepting runs GOAL_ALLOCATE
--     logic in the same transaction. Three dismissals in a row for a goal + reason stop further proposals of that kind.
--   * Milestones 25/50/75/100 % announced once.
-- Every money movement goes through the existing command functions (cmd_tx_reverse, cmd_debt_repay,
-- cmd_debt_payment_reverse, cmd_goal_allocate, transfer_restore); journal invariants are unchanged. Server role only.
begin;

-- ---------------------------------------------------------------- tables
create table public.pf_debt_collect (
  debt_id uuid primary key references public.pf_debt(id),
  owner_id uuid not null references public.pf_owner(user_id),
  memo_code text not null unique check (memo_code ~ '^[A-Z0-9]{6}$'),
  remind_count integer not null default 0 check (remind_count >= 0),
  last_reminded_at timestamptz,
  snooze_until date,
  created_at timestamptz not null default now()
);

create table public.pf_debt_settle (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  debt_id uuid not null references public.pf_debt(id),
  money_tx uuid not null references public.pf_tx(id),     -- the captured money-in / money-out
  repay_tx uuid references public.pf_tx(id),              -- the DEBT_REPAY transaction (AUTO / CONFIRMED)
  restored_tx uuid references public.pf_tx(id),           -- after an undo: the re-created original
  amount bigint not null check (amount > 0),
  state text not null check (state in ('AUTO', 'CONFIRMED', 'SUGGESTED', 'REJECTED')),
  score integer not null default 0,
  hints text[] not null default '{}',
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (money_tx, debt_id),
  check (state not in ('AUTO', 'CONFIRMED') or repay_tx is not null)
);
create index pf_debt_settle_owner_idx on public.pf_debt_settle(owner_id, state, created_at desc);
create unique index pf_debt_settle_repay_uq on public.pf_debt_settle(repay_tx) where repay_tx is not null;

create table public.pf_contact_bank (
  contact_id uuid primary key references public.pf_contact(id),
  owner_id uuid not null references public.pf_owner(user_id),
  bank text not null check (length(bank) between 1 and 60),
  bin text check (bin ~ '^[0-9]{6}$'),
  account_number text not null check (account_number ~ '^[0-9]{4,20}$'),
  holder text check (length(holder) <= 80),
  updated_at timestamptz not null default now()
);

create table public.pf_goal_proposal (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  goal_id uuid not null references public.pf_goal(id),
  account_id uuid not null references public.pf_account(id),
  amount bigint not null check (amount > 0),
  reason text not null check (reason in ('INCOME', 'MONTH_END')),
  period text not null check (length(period) between 1 and 60), -- income tx id or YYYY-MM
  source_tx uuid references public.pf_tx(id),
  state text not null default 'PENDING' check (state in ('PENDING', 'ACCEPTED', 'DISMISSED')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (goal_id, reason, period)
);
create index pf_goal_proposal_owner_idx on public.pf_goal_proposal(owner_id, state, created_at desc);

create table public.pf_goal_milestone (
  goal_id uuid primary key references public.pf_goal(id),
  owner_id uuid not null references public.pf_owner(user_id),
  last_pct integer not null default 0 check (last_pct between 0 and 100),
  updated_at timestamptz not null default now()
);

alter table public.pf_debt_collect enable row level security;
alter table public.pf_debt_settle enable row level security;
alter table public.pf_contact_bank enable row level security;
alter table public.pf_goal_proposal enable row level security;
alter table public.pf_goal_milestone enable row level security;
revoke all on table public.pf_debt_collect, public.pf_debt_settle, public.pf_contact_bank, public.pf_goal_proposal,
  public.pf_goal_milestone from public, anon, authenticated;

-- ---------------------------------------------------------------- collection: helpers
-- Memo code of a debt (created on first use): 6 characters, at least two letters and two digits so it never looks like
-- a word or a bank reference.
create function pf_private.collect_code(p_owner uuid, p_debt uuid) returns text
language plpgsql set search_path = pg_catalog, public as $$
declare c text; alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; tries integer := 0;
begin
  select memo_code into c from public.pf_debt_collect where debt_id = p_debt;
  if c is not null then return c; end if;
  perform 1 from public.pf_debt where id = p_debt and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  loop
    tries := tries + 1;
    select string_agg(substr(alphabet, 1 + floor(random() * 32)::integer, 1), '') into c from generate_series(1, 6);
    if c ~ '[A-Z].*[A-Z]' and c ~ '[0-9].*[0-9]' then
      begin
        insert into public.pf_debt_collect(debt_id, owner_id, memo_code) values (p_debt, p_owner, c)
          on conflict (debt_id) do nothing;
        select memo_code into c from public.pf_debt_collect where debt_id = p_debt;
        return c;
      exception when unique_violation then
        null; -- same code as another debt: draw again
      end;
    end if;
    if tries > 50 then perform pf_private.err('DB_ERROR'); end if;
  end loop;
end $$;

-- A captured transaction that may be (part of) a repayment: posted money in / out, not already part of a debt,
-- a transfer, a recurring occurrence or a bill split.
create function pf_private.collect_money_ok(t public.pf_tx) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select t.status = 'POSTED'
     and t.kind in ('INCOME', 'UNKNOWN_CREDIT', 'EXPENSE', 'UNKNOWN_DEBIT')
     and t.source in ('BANK', 'NOTIFICATION', 'IMPORT', 'MANUAL', 'AI')
     and t.account_id is not null and t.amount is not null
     and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
     and not exists (select 1 from public.pf_debt_payment p where p.tx_id = t.id)
     and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)
     and not exists (select 1 from public.pf_split_application a where a.tx_id = t.id and a.state in ('PROPOSED', 'APPLIED'))
$$;

-- Open debts this transaction could repay, with a score (0..100) and the reasons.
create function pf_private.collect_candidates(p_owner uuid, p_tx uuid)
returns table (c_debt uuid, c_contact uuid, c_score integer, c_hints text[], c_remaining numeric, c_originated timestamptz)
language plpgsql stable set search_path = pg_catalog, public as $$
declare x public.pf_tx; x_in boolean; t text; flat text; r record; h text[]; s integer; nm text; toks text[]; tok text; all_in boolean;
        today date;
begin
  select * into x from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found or not pf_private.collect_money_ok(x) then return; end if;
  x_in := x.kind in ('INCOME', 'UNKNOWN_CREDIT');
  t := ' ' || pf_private.ai_norm(concat_ws(' ', x.note, x.merchant)) || ' ';
  flat := regexp_replace(upper(concat_ws(' ', x.note, x.merchant)), '[^A-Z0-9]', '', 'g');
  today := (x.effective_at at time zone 'Asia/Ho_Chi_Minh')::date;
  for r in select d.id, d.contact_id, d.due_date, d.originated_at, c.alias, pf_private.debt_remaining(d.id) as rem,
                  dc.memo_code, dc.last_reminded_at
             from public.pf_debt d
             join public.pf_contact c on c.id = d.contact_id
             left join public.pf_debt_collect dc on dc.debt_id = d.id
            where d.owner_id = p_owner and d.state in ('OPEN', 'PARTIAL')
              and d.direction = case when x_in then 'RECEIVABLE' else 'PAYABLE' end
              and d.originated_at <= x.effective_at + interval '1 day' loop
    if r.rem <= 0 or x.amount > r.rem then continue; end if;
    -- never again for money the owner (or an undo) said is not this debt, including the re-created copy after an undo
    if exists (select 1 from public.pf_debt_settle s2 where s2.debt_id = r.id and s2.state = 'REJECTED'
                 and (s2.money_tx = x.id or s2.restored_tx = x.id)) then
      continue;
    end if;
    h := '{}'; s := 0;
    if r.memo_code is not null and position(r.memo_code in flat) > 0 then
      h := array_append(h, 'memo'); s := 100;
    end if;
    nm := pf_private.ai_norm(r.alias);
    if length(nm) >= 2 then
      toks := string_to_array(nm, ' ');
      all_in := true;
      foreach tok in array toks loop
        if position(' ' || tok || ' ' in t) = 0 then all_in := false; exit; end if;
      end loop;
      if all_in then
        if cardinality(toks) >= 2 then h := array_append(h, 'name'); s := s + 50;
        else h := array_append(h, 'name_weak'); s := s + 30; end if;
      end if;
    end if;
    if x.amount = r.rem then h := array_append(h, 'amount_full'); s := s + 30;
    else h := array_append(h, 'amount_partial'); s := s + 5; end if;
    if (r.due_date is not null and r.due_date < today) or r.last_reminded_at > x.effective_at - interval '30 days' then
      h := array_append(h, 'expected'); s := s + 10;
    end if;
    if s >= 40 then
      c_debt := r.id; c_contact := r.contact_id; c_score := least(s, 100); c_hints := h; c_remaining := r.rem;
      c_originated := r.originated_at;
      return next;
    end if;
  end loop;
end $$;

-- Books the captured transaction as a repayment of the debt: reverse it, post DEBT_REPAY with the same account, amount
-- and time, keep its text and source. Returns the repayment transaction id.
create function pf_private.collect_apply(p_owner uuid, p_tx uuid, p_debt uuid) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare x public.pf_tx; d public.pf_debt; res jsonb; rid uuid; v integer; who text;
begin
  select * into x from public.pf_tx where id = p_tx and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if not pf_private.collect_money_ok(x) then perform pf_private.err('INVALID_STATE'); end if;
  select * into d from public.pf_debt where id = p_debt and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.state not in ('OPEN', 'PARTIAL') or x.amount > pf_private.debt_remaining(d.id)
     or (d.direction = 'RECEIVABLE') <> (x.kind in ('INCOME', 'UNKNOWN_CREDIT')) then
    perform pf_private.err('INVALID_STATE');
  end if;
  select alias into who from public.pf_contact where id = d.contact_id;
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', x.id, 'expected_version', x.version,
    'reason', case when d.direction = 'RECEIVABLE' then 'Ghi thành ' || who || ' trả nợ' else 'Ghi thành trả nợ ' || who end));
  res := pf_private.cmd_debt_repay(p_owner, jsonb_build_object('debt_id', d.id, 'account_id', x.account_id,
    'principal', x.amount::text, 'effective_at', x.effective_at, 'expected_version', d.version));
  rid := (res->>'tx_id')::uuid;
  update public.pf_tx set note = left(x.note, 1000), source = x.source, version = version + 1, updated_at = now()
   where id = rid returning version into v;
  perform pf_private.touch_change(p_owner, 'transaction', rid, v);
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'system', 'DEBT_AUTO_SETTLE', d.id, jsonb_build_object('money_tx', x.id, 'repay_tx', rid, 'amount', x.amount::text));
  return rid;
end $$;

-- Entry point after a money-in / money-out lands. Serialised per owner.
-- {status: NONE | AUTO | SUGGESTED, settle_id?, repay_tx_id?, debt_id?, suggested?}
create function pf_private.collect_try(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare n integer; b_debt uuid; b_score integer; b_hints text[]; strong_contacts integer; sid uuid; rid uuid; k integer := 0; c record;
begin
  perform pg_advisory_xact_lock(hashtext('moma-debt-collect'), hashtext(p_owner::text));
  if exists (select 1 from public.pf_debt_settle where money_tx = p_tx and state in ('AUTO', 'CONFIRMED')) then
    return jsonb_build_object('status', 'NONE');
  end if;
  select count(*) into n from pf_private.collect_candidates(p_owner, p_tx);
  if n = 0 then return jsonb_build_object('status', 'NONE'); end if;
  -- memo code: certain
  select count(*) into n from pf_private.collect_candidates(p_owner, p_tx) where 'memo' = any(c_hints);
  if n = 1 then
    select c_debt, c_score, c_hints into b_debt, b_score, b_hints
      from pf_private.collect_candidates(p_owner, p_tx) where 'memo' = any(c_hints);
  else
    -- full name + full amount, one person: oldest debt of that person first
    select count(distinct c_contact) into strong_contacts from pf_private.collect_candidates(p_owner, p_tx)
     where 'name' = any(c_hints) and 'amount_full' = any(c_hints);
    if strong_contacts = 1 then
      select c_debt, c_score, c_hints into b_debt, b_score, b_hints from pf_private.collect_candidates(p_owner, p_tx)
       where 'name' = any(c_hints) and 'amount_full' = any(c_hints) order by c_originated, c_debt limit 1;
    end if;
  end if;
  if b_debt is not null then
    rid := pf_private.collect_apply(p_owner, p_tx, b_debt);
    insert into public.pf_debt_settle(owner_id, debt_id, money_tx, repay_tx, amount, state, score, hints, decided_at)
      select p_owner, b_debt, p_tx, rid, t.amount, 'AUTO', b_score, b_hints, now() from public.pf_tx t where t.id = p_tx
      on conflict (money_tx, debt_id) do update set repay_tx = excluded.repay_tx, state = 'AUTO', score = excluded.score,
        hints = excluded.hints, decided_at = now()
      returning id into sid;
    -- other suggestions for the same money are answered
    update public.pf_debt_settle set state = 'REJECTED', decided_at = now()
     where money_tx = p_tx and id <> sid and state = 'SUGGESTED';
    return jsonb_build_object('status', 'AUTO', 'settle_id', sid, 'repay_tx_id', rid, 'debt_id', b_debt);
  end if;
  for c in select * from pf_private.collect_candidates(p_owner, p_tx) order by c_score desc, c_originated, c_debt limit 3 loop
    sid := null;
    insert into public.pf_debt_settle(owner_id, debt_id, money_tx, amount, state, score, hints)
      select p_owner, c.c_debt, p_tx, t.amount, 'SUGGESTED', c.c_score, c.c_hints from public.pf_tx t where t.id = p_tx
      on conflict (money_tx, debt_id) do nothing returning id into sid;
    if sid is not null then k := k + 1; end if;
  end loop;
  return jsonb_build_object('status', case when k > 0 then 'SUGGESTED' else 'NONE' end, 'suggested', k);
end $$;

-- Undo of one AUTO / CONFIRMED settlement: reverse the repayment (if still in effect), re-create the original
-- transaction, REJECTED (never suggested again).
create function pf_private.collect_undo(p_owner uuid, p_settle uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare s public.pf_debt_settle; d public.pf_debt; pay public.pf_debt_payment; x public.pf_tx; restored uuid;
begin
  select * into s from public.pf_debt_settle where id = p_settle and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if s.state not in ('AUTO', 'CONFIRMED') then perform pf_private.err('INVALID_STATE'); end if;
  select * into d from public.pf_debt where id = s.debt_id;
  select p.* into pay from pf_private.debt_active_payments(d.id) p where p.tx_id = s.repay_tx;
  if found and d.state <> 'CANCELLED' then
    perform pf_private.cmd_debt_payment_reverse(p_owner, jsonb_build_object('debt_id', d.id, 'payment_id', pay.id, 'expected_version', d.version));
  end if;
  select * into x from public.pf_tx where id = s.money_tx;
  restored := pf_private.transfer_restore(p_owner, x);
  update public.pf_debt_settle set state = 'REJECTED', restored_tx = restored, decided_at = now() where id = s.id;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'DEBT_AUTO_SETTLE_UNDO', s.debt_id, jsonb_build_object('settle', s.id, 'restored_tx', restored));
  return jsonb_build_object('settle_id', s.id, 'state', 'REJECTED', 'restored_tx_id', restored, 'debt_id', s.debt_id);
end $$;

create function pf_private.collect_repair(p_owner uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare r record; x public.pf_tx; restored uuid; n integer := 0;
begin
  for r in select s.* from public.pf_debt_settle s join public.pf_tx t on t.id = s.repay_tx
            where s.owner_id = p_owner and s.state in ('AUTO', 'CONFIRMED') and t.status = 'VOID' loop
    select * into x from public.pf_tx where id = r.money_tx;
    restored := pf_private.transfer_restore(p_owner, x);
    update public.pf_debt_settle set state = 'REJECTED', restored_tx = restored, decided_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- collection: public RPCs
create function public.pf_collect_try(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.collect_try(p_owner, p_tx);
end $$;

-- Re-check recent captured money (1..168 hours) and repair settlements whose repayment was undone elsewhere (the
-- original money comes back). One failing transaction never stops the others.
create function public.pf_collect_sweep(p_owner uuid, p_hours integer) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r record; res jsonb; checked integer := 0; auto integer := 0; suggested integer := 0; repaired integer := 0; failed integer := 0;
        restored uuid; x public.pf_tx;
begin
  perform pf_private.assert_owner(p_owner);
  for r in select t.id from public.pf_tx t
            where t.owner_id = p_owner and t.status = 'POSTED'
              and t.kind in ('INCOME', 'UNKNOWN_CREDIT', 'EXPENSE', 'UNKNOWN_DEBIT')
              and t.source in ('BANK', 'NOTIFICATION', 'IMPORT')
              and t.effective_at >= now() - make_interval(hours => least(greatest(coalesce(p_hours, 72), 1), 168))
            order by t.effective_at, t.id loop
    checked := checked + 1;
    begin
      res := pf_private.collect_try(p_owner, r.id);
      if res->>'status' = 'AUTO' then auto := auto + 1;
      elsif res->>'status' = 'SUGGESTED' then suggested := suggested + coalesce((res->>'suggested')::integer, 0); end if;
    exception when others then failed := failed + 1;
    end;
  end loop;
  repaired := pf_private.collect_repair(p_owner);
  return jsonb_build_object('checked', checked, 'auto', auto, 'suggested', suggested, 'repaired', repaired, 'failed', failed);
end $$;

-- Right after DEBT_PAYMENT_REVERSE / DEBT_CANCEL (and in the sweep): the original money of a repayment that is no longer
-- in effect comes back exactly as it arrived (it really moved), and that pair is closed for good.
create function public.pf_collect_repair(p_owner uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-debt-collect'), hashtext(p_owner::text));
  return pf_private.collect_repair(p_owner);
end $$;

create function pf_private.collect_settle_json(s public.pf_debt_settle) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', s.id, 'state', s.state, 'score', s.score, 'hints', to_jsonb(s.hints), 'amount', s.amount::text,
    'created_at', s.created_at, 'decided_at', s.decided_at, 'repay_tx_id', s.repay_tx, 'restored_tx_id', s.restored_tx,
    'debt', jsonb_build_object('id', d.id, 'direction', d.direction, 'contact_id', d.contact_id, 'contact_alias', c.alias,
      'principal', d.principal::text, 'remaining', pf_private.debt_remaining(d.id)::text, 'note', d.note, 'state', d.state),
    'money', jsonb_build_object('tx_id', t.id, 'kind', t.kind, 'status', t.status, 'amount', t.amount::text,
      'effective_at', t.effective_at, 'note', t.note, 'merchant', t.merchant, 'source', t.source,
      'account_id', a.id, 'account_name', a.name, 'institution', a.institution))
  from public.pf_debt d join public.pf_contact c on c.id = d.contact_id
  join public.pf_tx t on t.id = s.money_tx
  left join public.pf_account a on a.id = t.account_id
  where d.id = s.debt_id
$$;

create function public.pf_collect_suggestions(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.collect_settle_json(s) order by t.effective_at desc, s.score desc, s.id)
    from public.pf_debt_settle s join public.pf_tx t on t.id = s.money_tx join public.pf_debt d on d.id = s.debt_id
   where s.owner_id = p_owner and s.state = 'SUGGESTED' and t.status = 'POSTED' and d.state in ('OPEN', 'PARTIAL')
     and t.amount <= pf_private.debt_remaining(d.id)), '[]'::jsonb);
end $$;

-- The settlement a transaction belongs to (as the captured money or as the repayment), or null.
create function public.pf_collect_for_tx(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare s public.pf_debt_settle;
begin
  perform pf_private.assert_owner(p_owner);
  select * into s from public.pf_debt_settle where owner_id = p_owner and state in ('AUTO', 'CONFIRMED')
     and (repay_tx = p_tx or money_tx = p_tx) order by created_at desc limit 1;
  if not found then return null; end if;
  return pf_private.collect_settle_json(s)
    || jsonb_build_object('can_undo', exists (select 1 from public.pf_tx t where t.id = s.repay_tx and t.status = 'POSTED'));
end $$;

-- Settlements recorded automatically in the last p_hours (for the batched "đã trả" push).
create function public.pf_collect_recent_auto(p_owner uuid, p_hours integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.collect_settle_json(s) order by s.created_at)
    from public.pf_debt_settle s
   where s.owner_id = p_owner and s.state = 'AUTO'
     and s.created_at >= now() - make_interval(hours => least(greatest(coalesce(p_hours, 24), 1), 168))), '[]'::jsonb);
end $$;

create function public.pf_collect_decide(p_owner uuid, p_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_debt_settle; rid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if p_accept is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform pg_advisory_xact_lock(hashtext('moma-debt-collect'), hashtext(p_owner::text));
  select * into s from public.pf_debt_settle where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if s.state <> 'SUGGESTED' then perform pf_private.err('INVALID_STATE'); end if;
  if not p_accept then
    update public.pf_debt_settle set state = 'REJECTED', decided_at = now() where id = s.id;
    return jsonb_build_object('settle_id', s.id, 'state', 'REJECTED');
  end if;
  rid := pf_private.collect_apply(p_owner, s.money_tx, s.debt_id); -- INVALID_STATE when either side changed meanwhile
  update public.pf_debt_settle set state = 'CONFIRMED', repay_tx = rid, decided_at = now() where id = s.id;
  -- the other suggestions for the same money are answered by this choice
  update public.pf_debt_settle set state = 'REJECTED', decided_at = now()
   where money_tx = s.money_tx and id <> s.id and state = 'SUGGESTED';
  return jsonb_build_object('settle_id', s.id, 'state', 'CONFIRMED', 'repay_tx_id', rid, 'debt_id', s.debt_id);
end $$;

create function public.pf_collect_undo(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-debt-collect'), hashtext(p_owner::text));
  return pf_private.collect_undo(p_owner, p_id);
end $$;

-- Undo by the repayment transaction (the debt sheet's "Hoàn tác"); null when that repayment was not automatic.
create function public.pf_collect_undo_by_tx(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare sid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-debt-collect'), hashtext(p_owner::text));
  select id into sid from public.pf_debt_settle where owner_id = p_owner and repay_tx = p_tx and state in ('AUTO', 'CONFIRMED');
  if sid is null then return null; end if;
  return pf_private.collect_undo(p_owner, sid);
end $$;

-- Days a person usually takes to pay back (median of first repayments of their past debts), null without history.
create function pf_private.collect_learned_days(p_owner uuid, p_contact uuid) returns integer
language sql stable set search_path = pg_catalog, public as $$
  select percentile_cont(0.5) within group (order by x.days)::integer from (
    select extract(epoch from (min(t.effective_at) - d.originated_at)) / 86400 as days
      from public.pf_debt d
      join public.pf_debt_payment p on p.debt_id = d.id and p.kind = 'REPAYMENT'
      join public.pf_tx t on t.id = p.tx_id and t.status = 'POSTED'
     where d.owner_id = p_owner and d.contact_id = p_contact and d.direction = 'RECEIVABLE'
     group by d.id, d.originated_at) x
  where x.days >= 0
$$;

-- When the next reminder of an open receivable is due: first one on the due date, or after the person's usual delay
-- + 2 days (default 7), then every 7 days (10 after the second). Snooze pushes it.
create function pf_private.collect_next_at(p_owner uuid, d public.pf_debt, dc public.pf_debt_collect) returns date
language plpgsql stable set search_path = pg_catalog, public as $$
declare base date; learned integer;
begin
  if coalesce(dc.remind_count, 0) = 0 then
    learned := pf_private.collect_learned_days(p_owner, d.contact_id);
    base := coalesce(d.due_date, (d.originated_at at time zone 'Asia/Ho_Chi_Minh')::date + coalesce(learned + 2, 7));
  else
    base := (dc.last_reminded_at at time zone 'Asia/Ho_Chi_Minh')::date + case when dc.remind_count >= 2 then 10 else 7 end;
  end if;
  if dc.snooze_until is not null and dc.snooze_until > base then base := dc.snooze_until; end if;
  return base;
end $$;

create function pf_private.collect_reminder_json(p_owner uuid, p_debt uuid, p_today date) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; c public.pf_contact; dc public.pf_debt_collect; code text; b public.pf_contact_bank;
begin
  select * into d from public.pf_debt where id = p_debt and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  select * into c from public.pf_contact where id = d.contact_id;
  code := pf_private.collect_code(p_owner, d.id);
  select * into dc from public.pf_debt_collect where debt_id = d.id;
  select * into b from public.pf_contact_bank where contact_id = d.contact_id;
  return jsonb_build_object('debt_id', d.id, 'direction', d.direction, 'contact_id', c.id, 'contact_alias', c.alias,
    'principal', d.principal::text, 'remaining', pf_private.debt_remaining(d.id)::text, 'state', d.state, 'note', d.note,
    'originated_at', d.originated_at, 'due_date', d.due_date, 'version', d.version,
    'overdue_days', case when d.due_date is not null and d.due_date < p_today then p_today - d.due_date else 0 end,
    'age_days', p_today - (d.originated_at at time zone 'Asia/Ho_Chi_Minh')::date,
    'memo_code', code, 'memo', 'MOMA ' || code,
    'remind_count', dc.remind_count, 'last_reminded_at', dc.last_reminded_at, 'snooze_until', dc.snooze_until,
    'next_at', pf_private.collect_next_at(p_owner, d, dc),
    'learned_days', pf_private.collect_learned_days(p_owner, d.contact_id),
    'contact_bank', case when b.contact_id is null then null else jsonb_build_object('bank', b.bank, 'bin', b.bin,
       'account_number', b.account_number, 'holder', b.holder) end);
end $$;

create function public.pf_collect_reminder(p_owner uuid, p_debt uuid, p_today date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.collect_reminder_json(p_owner, p_debt, p_today);
end $$;

-- Reminders due today: receivables whose next reminder date has come (max 6 reminders), payables due within 2 days or
-- overdue ("Trả ngay").
create function public.pf_collect_due(p_owner uuid, p_today date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.pf_debt; out jsonb := '[]'::jsonb; dc public.pf_debt_collect;
begin
  perform pf_private.assert_owner(p_owner);
  for r in select d.* from public.pf_debt d where d.owner_id = p_owner and d.state in ('OPEN', 'PARTIAL') order by d.originated_at loop
    select * into dc from public.pf_debt_collect where debt_id = r.id;
    if r.direction = 'RECEIVABLE' then
      if coalesce(dc.remind_count, 0) < 6 and pf_private.collect_next_at(p_owner, r, dc) <= p_today then
        out := out || jsonb_build_array(pf_private.collect_reminder_json(p_owner, r.id, p_today));
      end if;
    elsif r.due_date is not null and r.due_date <= p_today + 2
          and (dc.snooze_until is null or dc.snooze_until <= p_today) then
      out := out || jsonb_build_array(pf_private.collect_reminder_json(p_owner, r.id, p_today));
    end if;
  end loop;
  return out;
end $$;

create function public.pf_collect_mark_reminded(p_owner uuid, p_debt uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare dc public.pf_debt_collect;
begin
  perform pf_private.assert_owner(p_owner);
  perform pf_private.collect_code(p_owner, p_debt);
  update public.pf_debt_collect set remind_count = remind_count + 1, last_reminded_at = now(), snooze_until = null
   where debt_id = p_debt and owner_id = p_owner returning * into dc;
  return jsonb_build_object('debt_id', p_debt, 'remind_count', dc.remind_count, 'last_reminded_at', dc.last_reminded_at);
end $$;

create function public.pf_collect_snooze(p_owner uuid, p_debt uuid, p_until date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  if p_until is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform pf_private.collect_code(p_owner, p_debt);
  update public.pf_debt_collect set snooze_until = p_until where debt_id = p_debt and owner_id = p_owner;
  return jsonb_build_object('debt_id', p_debt, 'snooze_until', p_until);
end $$;

-- Creditor's bank account for "Trả ngay" (null p_account_number clears it).
create function public.pf_contact_bank_set(p_owner uuid, p_contact uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare num text := regexp_replace(coalesce(p->>'account_number', ''), '[^0-9]', '', 'g');
begin
  perform pf_private.assert_owner(p_owner);
  perform 1 from public.pf_contact where id = p_contact and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if num = '' then
    delete from public.pf_contact_bank where contact_id = p_contact and owner_id = p_owner;
    return jsonb_build_object('contact_id', p_contact, 'cleared', true);
  end if;
  if num !~ '^[0-9]{4,20}$' or coalesce(btrim(p->>'bank'), '') = '' or (p->>'bin' is not null and p->>'bin' !~ '^[0-9]{6}$') then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  insert into public.pf_contact_bank(contact_id, owner_id, bank, bin, account_number, holder, updated_at)
    values (p_contact, p_owner, left(btrim(p->>'bank'), 60), p->>'bin', num, nullif(left(btrim(upper(coalesce(p->>'holder', ''))), 80), ''), now())
    on conflict (contact_id) do update set bank = excluded.bank, bin = excluded.bin, account_number = excluded.account_number,
      holder = excluded.holder, updated_at = now();
  return jsonb_build_object('contact_id', p_contact, 'bank', left(btrim(p->>'bank'), 60), 'account_number', num);
end $$;

-- ---------------------------------------------------------------- goals
create function pf_private.account_available(p_account uuid) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select pf_private.ledger_total(a.ledger_account_id)
       - coalesce((select sum(signed_amount::numeric) from public.pf_allocation where account_id = a.id), 0)
    from public.pf_account a where a.id = p_account
$$;

-- Per active goal: allocated, required monthly saving to reach the target by its due date, pace of the last 90 days,
-- ETA and on-track flag.
create function public.pf_goal_plan(p_owner uuid, p_today date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.due_date nulls last, x.name) from (
    select g.id, g.name, g.target::text as target, g.due_date, g.version, g.state,
           alloc::text as allocated, greatest(g.target - alloc, 0)::text as left_amount,
           least(100, floor(alloc * 100 / g.target))::integer as pct,
           months_left,
           case when months_left is null then null else ceil(greatest(g.target - alloc, 0) / months_left)::bigint::text end as required_monthly,
           pace::bigint::text as pace_monthly,
           case when alloc >= g.target then p_today
                when pace > 0 then (p_today + (ceil(greatest(g.target - alloc, 0) / pace) * 30)::integer) end as eta,
           case when g.due_date is null then null
                when alloc >= g.target then true
                when pace <= 0 then false
                else p_today + (ceil(greatest(g.target - alloc, 0) / pace) * 30)::integer <= g.due_date end as on_track
      from public.pf_goal g
      cross join lateral (select pf_private.goal_allocated(g.id) as alloc) a
      cross join lateral (select case when g.due_date is null then null
                                      else greatest(1, (extract(year from age(g.due_date, p_today)) * 12
                                                         + extract(month from age(g.due_date, p_today))
                                                         + case when extract(day from age(g.due_date, p_today)) > 0 then 1 else 0 end)::integer) end as months_left) m
      cross join lateral (select coalesce(sum(al.signed_amount::numeric), 0) / 3 as pace from public.pf_allocation al
                           where al.goal_id = g.id and al.created_at >= p_today - 90) p
     where g.owner_id = p_owner and g.state = 'ACTIVE') x), '[]'::jsonb);
end $$;

-- Facts about one transaction for the income proposal: kind, amount, account, category name, average monthly income
-- of the last 90 days and what is still free on that account (balance minus goal reservations).
create function public.pf_goal_income_facts(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx;
begin
  perform pf_private.assert_owner(p_owner);
  select * into t from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found then return null; end if;
  return jsonb_build_object('tx_id', t.id, 'kind', t.kind, 'status', t.status, 'source', t.source, 'amount', t.amount::text,
    'effective_at', t.effective_at, 'account_id', t.account_id, 'note', t.note,
    'category_name', (select c.name from public.pf_category c where c.id = t.category_id),
    'avg_monthly_income', (select coalesce(sum(x.amount), 0) / 3 from public.pf_tx x
                            where x.owner_id = p_owner and x.status = 'POSTED' and x.kind in ('INCOME', 'UNKNOWN_CREDIT')
                              and x.effective_at >= t.effective_at - interval '90 days' and x.effective_at < t.effective_at)::bigint::text,
    'available', case when t.account_id is null then '0' else pf_private.account_available(t.account_id)::bigint::text end);
end $$;

-- Stores one proposal (unique per goal + reason + period). SKIPPED after three dismissals in a row of that kind.
create function public.pf_goal_propose(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare g public.pf_goal; acc uuid := (p->>'account_id')::uuid; amt bigint := pf_private.parse_money(p->>'amount');
        v_reason text := p->>'reason'; v_period text := btrim(coalesce(p->>'period', '')); pid uuid; dismissed integer;
begin
  perform pf_private.assert_owner(p_owner);
  if v_reason is null or v_reason not in ('INCOME', 'MONTH_END') or v_period = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  select * into g from public.pf_goal where id = (p->>'goal_id')::uuid and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if g.state <> 'ACTIVE' then return jsonb_build_object('status', 'SKIPPED', 'why', 'goal_inactive'); end if;
  perform 1 from public.pf_account where id = acc and owner_id = p_owner and not archived;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  select count(*) into dismissed from (
    select pr.state from public.pf_goal_proposal pr where pr.goal_id = g.id and pr.reason = v_reason and pr.state <> 'PENDING'
     order by pr.created_at desc limit 3) z where z.state = 'DISMISSED';
  if dismissed >= 3 then return jsonb_build_object('status', 'SKIPPED', 'why', 'dismissed'); end if;
  insert into public.pf_goal_proposal(owner_id, goal_id, account_id, amount, reason, period, source_tx)
    values (p_owner, g.id, acc, amt, v_reason, left(v_period, 60), nullif(p->>'source_tx', '')::uuid)
    on conflict (goal_id, reason, period) do nothing returning id into pid;
  if pid is null then return jsonb_build_object('status', 'EXISTS'); end if;
  return jsonb_build_object('status', 'PROPOSED', 'id', pid);
end $$;

create function public.pf_goal_proposals(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', pr.id, 'goal_id', g.id, 'goal_name', g.name, 'target', g.target::text,
      'allocated', pf_private.goal_allocated(g.id)::text, 'account_id', a.id, 'account_name', a.name, 'amount', pr.amount::text,
      'reason', pr.reason, 'period', pr.period, 'source_tx', pr.source_tx, 'created_at', pr.created_at,
      'available', pf_private.account_available(a.id)::bigint::text) order by pr.created_at desc)
    from public.pf_goal_proposal pr join public.pf_goal g on g.id = pr.goal_id join public.pf_account a on a.id = pr.account_id
   where pr.owner_id = p_owner and pr.state = 'PENDING' and g.state = 'ACTIVE' and not a.archived
     and pr.created_at >= now() - interval '7 days'), '[]'::jsonb);
end $$;

-- One tap "Trích": the allocation and the decision in one transaction (idempotent: an accepted proposal returns again).
create function public.pf_goal_proposal_accept(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare pr public.pf_goal_proposal; g public.pf_goal; res jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  select * into pr from public.pf_goal_proposal where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if pr.state = 'ACCEPTED' then return jsonb_build_object('proposal_id', pr.id, 'state', 'ACCEPTED', 'replayed', true); end if;
  if pr.state <> 'PENDING' then perform pf_private.err('INVALID_STATE'); end if;
  select * into g from public.pf_goal where id = pr.goal_id;
  res := pf_private.cmd_goal_allocate(p_owner, jsonb_build_object('goal_id', g.id, 'account_id', pr.account_id,
    'amount', pr.amount::text, 'expected_version', g.version));
  update public.pf_goal_proposal set state = 'ACCEPTED', decided_at = now() where id = pr.id;
  return res || jsonb_build_object('proposal_id', pr.id, 'state', 'ACCEPTED');
end $$;

create function public.pf_goal_proposal_dismiss(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_goal_proposal set state = 'DISMISSED', decided_at = now() where id = p_id and owner_id = p_owner and state = 'PENDING';
  get diagnostics n = row_count;
  if n = 0 then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('proposal_id', p_id, 'state', 'DISMISSED');
end $$;

-- Month spending vs the overall budget (or the average of the 3 previous months with spending) and the liquid account
-- with the most free money.
create function public.pf_goal_month_surplus(p_owner uuid, p_month text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare m date; spent numeric; base numeric; basis text; acc record;
begin
  perform pf_private.assert_owner(p_owner);
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform pf_private.err('VALIDATION_FAILED'); end if;
  m := (p_month || '-01')::date;
  select coalesce(sum(t.amount), 0) into spent from public.pf_tx t
   where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
     and (t.effective_at at time zone 'Asia/Ho_Chi_Minh')::date >= m
     and (t.effective_at at time zone 'Asia/Ho_Chi_Minh')::date < (m + interval '1 month')::date;
  select b.limit_amount into base from public.pf_budget b where b.owner_id = p_owner and b.month = m and b.category_id is null;
  if base is not null then basis := 'BUDGET';
  else
    select avg(s) into base from (
      select sum(t.amount) as s from public.pf_tx t
       where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
         and (t.effective_at at time zone 'Asia/Ho_Chi_Minh')::date >= (m - interval '3 months')::date
         and (t.effective_at at time zone 'Asia/Ho_Chi_Minh')::date < m
       group by date_trunc('month', t.effective_at at time zone 'Asia/Ho_Chi_Minh')) z where s > 0;
    if base is not null then basis := 'AVERAGE'; end if;
  end if;
  select a.id, a.name, pf_private.account_available(a.id) as available into acc
    from public.pf_account a join public.pf_ledger_account la on la.id = a.ledger_account_id and la.class = 'ASSET'
   where a.owner_id = p_owner and not a.archived and a.baseline_known and a.kind <> 'CREDIT_CARD'
   order by pf_private.account_available(a.id) desc, a.id limit 1;
  return jsonb_build_object('month', p_month, 'spent', spent::bigint::text, 'baseline', base::bigint::text, 'basis', basis,
    'surplus', case when base is null then null else greatest(base - spent, 0)::bigint::text end,
    'account_id', acc.id, 'account_name', acc.name, 'available', coalesce(acc.available, 0)::bigint::text);
end $$;

-- Milestones (25/50/75/100 %) newly reached since the last call; each one is returned once.
create function public.pf_goal_milestones_due(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare g record; pct integer; reached integer; prev integer; out jsonb := '[]'::jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  for g in select * from public.pf_goal where owner_id = p_owner and state in ('ACTIVE', 'COMPLETED') loop
    pct := least(100, floor(pf_private.goal_allocated(g.id) * 100 / g.target))::integer;
    reached := case when pct >= 100 then 100 when pct >= 75 then 75 when pct >= 50 then 50 when pct >= 25 then 25 else 0 end;
    select last_pct into prev from public.pf_goal_milestone where goal_id = g.id;
    if reached > coalesce(prev, 0) then
      insert into public.pf_goal_milestone(goal_id, owner_id, last_pct, updated_at) values (g.id, p_owner, reached, now())
        on conflict (goal_id) do update set last_pct = excluded.last_pct, updated_at = now();
      out := out || jsonb_build_array(jsonb_build_object('goal_id', g.id, 'name', g.name, 'pct', reached,
        'target', g.target::text, 'allocated', pf_private.goal_allocated(g.id)::text));
    end if;
  end loop;
  return out;
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

-- ===================================================== 20261128000020_budget_pacing.sql
-- MoMa migration 020: self-adjusting budgets (D-026). Read-only history for the budget proposer: one row per expense
-- transaction and category in a date range, with the posted (owner's) amount and whether it is a recurring / fixed
-- cost (matched to a recurring occurrence or applied by a recurring split rule). Reversed / corrected transactions net
-- out because all their journals are summed per transaction. Proposals, pacing and the monthly auto-apply are computed
-- in the API (apps/api/src/modules/budgets/plan.ts); budgets are still written only through BUDGET_UPSERT.
-- Server role only.
begin;

create function public.pf_budget_history(p_owner uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t_from timestamptz; t_to timestamptz;
begin
  perform pf_private.assert_owner(p_owner);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 200 then perform pf_private.err('VALIDATION_FAILED'); end if;
  t_from := p_from::timestamp at time zone 'Asia/Ho_Chi_Minh';
  t_to := (p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';
  return coalesce((
    with lines as (
      select j.tx_id, c.id as category_id, e.signed_amount::numeric as amt, j.effective_at
        from public.pf_entry e
        join public.pf_journal j on j.id = e.journal_id and j.posted
        join public.pf_ledger_account a on a.id = e.ledger_account_id and a.class = 'EXPENSE'
        join public.pf_category c on c.ledger_account_id = a.id and c.owner_id = p_owner
       where j.owner_id = p_owner and j.effective_at >= t_from and j.effective_at < t_to
         and a.code not in ('SYS_ADJUSTMENT_OUT')
    ), per_tx as (
      select tx_id, category_id, sum(amt) as amount, min(effective_at) as at
        from lines group by tx_id, category_id having sum(amt) > 0
    )
    select jsonb_agg(jsonb_build_object(
             'tx_id', p.tx_id,
             'day', to_char((p.at at time zone 'Asia/Ho_Chi_Minh')::date, 'YYYY-MM-DD'),
             'category_id', p.category_id,
             'amount', p.amount::text,
             'recurring', exists (select 1 from public.pf_occurrence o where o.matched_tx_id = p.tx_id)
                          or exists (select 1 from public.pf_split_application s
                                      where s.tx_id = p.tx_id and s.recurring_id is not null and s.state = 'APPLIED'))
           order by p.at, p.tx_id)
      from per_tx p), '[]'::jsonb);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;

-- ===================================================== 20261129000021_plans.sql
-- MoMa migration 021: Kế hoạch & Dự toán (D-027).
-- Event plans ("tối thứ 7 đi nhậu", "tiệc tốt nghiệp tháng 1"): an estimate (low / likely / high + breakdown, computed by
-- the API from the owner's own history) and, after the event, the actual money spent in its time window (plan vs actual).
-- Life plans ("mua nhà 2,5 tỷ", "mua xe"): price + down payment / loan / inflation assumptions; the API projects when the
-- owner can afford it from real income and spending. Saving itself goes through goals (pf_goal, GOAL_* commands).
-- Planning data only: nothing here writes the ledger. No new command types (the dispatcher is untouched); the assistant
-- and the app use the owner-scoped RPCs below through /v1/plans/*. Server role only.
begin;

create table public.pf_event_plan (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  title text not null check (length(title) between 1 and 120),
  kind text not null check (kind in ('NHAU', 'AN_UONG', 'CAFE', 'TIEC', 'SINH_NHAT', 'DU_LICH', 'KHAC')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  headcount integer not null default 1 check (headcount between 1 and 500),
  -- names of the other people (free text, matched to contacts by the API when useful)
  people jsonb not null default '[]'::jsonb check (jsonb_typeof(people) = 'array' and jsonb_array_length(people) <= 50),
  place text check (place is null or length(place) <= 120),
  owner_pays boolean not null default false,       -- "tôi bao": no split expected
  transport text not null default 'GRAB' check (transport in ('GRAB', 'OWN', 'NONE')),
  note text check (note is null or length(note) <= 300),
  estimate jsonb not null default '{}'::jsonb check (jsonb_typeof(estimate) = 'object'),
  budget bigint check (budget is null or budget >= 0),   -- the owner's expected share (likely)
  state text not null default 'PLANNED' check (state in ('PLANNED', 'DONE', 'CANCELLED')),
  actual jsonb check (actual is null or jsonb_typeof(actual) = 'object'),
  reminded_at timestamptz,
  alerted_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  check (ends_at > starts_at and ends_at - starts_at <= interval '31 days')
);
alter table public.pf_event_plan enable row level security;
revoke all on table public.pf_event_plan from public, anon, authenticated;
create index pf_event_plan_owner_idx on public.pf_event_plan(owner_id, starts_at desc);
create index pf_event_plan_open_idx on public.pf_event_plan(owner_id, state, starts_at) where state = 'PLANNED';

create table public.pf_life_plan (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  name text not null check (length(name) between 1 and 120),
  kind text not null check (kind in ('HOUSE', 'CAR', 'TRAVEL', 'WEDDING', 'EDUCATION', 'OTHER')),
  price bigint not null check (price > 0 and price <= 1000000000000),
  down_pct numeric(5, 2) not null default 100 check (down_pct > 0 and down_pct <= 100),
  loan_rate_pct numeric(5, 2) not null default 0 check (loan_rate_pct between 0 and 30),
  loan_years smallint not null default 0 check (loan_years between 0 and 35),
  inflation_pct numeric(5, 2) check (inflation_pct between -5 and 30),          -- null = market default for the kind
  income_growth_pct numeric(5, 2) check (income_growth_pct between -20 and 50),  -- null = keeps pace with inflation
  extra_saving bigint not null default 0 check (extra_saving between -1000000000 and 1000000000),
  goal_id uuid references public.pf_goal(id),
  target_date date,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1
);
alter table public.pf_life_plan enable row level security;
revoke all on table public.pf_life_plan from public, anon, authenticated;
create index pf_life_plan_owner_idx on public.pf_life_plan(owner_id, archived, created_at);

-- ---------------------------------------------------------------- event plans
create function pf_private.event_plan_json(e public.pf_event_plan) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', e.id, 'title', e.title, 'kind', e.kind, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
    'headcount', e.headcount, 'people', e.people, 'place', e.place, 'owner_pays', e.owner_pays, 'transport', e.transport,
    'note', e.note, 'estimate', e.estimate, 'budget', e.budget::text, 'state', e.state, 'actual', e.actual,
    'reminded_at', e.reminded_at, 'alerted_at', e.alerted_at, 'closed_at', e.closed_at, 'created_at', e.created_at,
    'updated_at', e.updated_at, 'version', e.version)
$$;

-- Create (id new / null) or update (same id, still PLANNED). The client may choose the id so a retry never doubles.
create function public.pf_plan_event_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan; pid uuid; s timestamptz; f timestamptz;
begin
  perform pf_private.assert_owner(p_owner);
  if jsonb_typeof(p) <> 'object' then perform pf_private.err('VALIDATION_FAILED'); end if;
  begin
    pid := nullif(p->>'id', '')::uuid;
    s := (p->>'starts_at')::timestamptz;
    f := coalesce((p->>'ends_at')::timestamptz, s + interval '4 hours');
  exception when others then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  if s is null or coalesce(btrim(p->>'title'), '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  if pid is not null then
    select * into e from public.pf_event_plan where id = pid for update;
    if found and e.owner_id <> p_owner then perform pf_private.err('NOT_FOUND'); end if;
    if found and e.state <> 'PLANNED' then perform pf_private.err('INVALID_STATE'); end if;
  end if;
  begin
    if e.id is null then
      insert into public.pf_event_plan(id, owner_id, title, kind, starts_at, ends_at, headcount, people, place, owner_pays,
                                       transport, note, estimate, budget)
      values (coalesce(pid, gen_random_uuid()), p_owner, left(btrim(p->>'title'), 120), coalesce(p->>'kind', 'KHAC'), s, f,
              coalesce((p->>'headcount')::integer, 1), coalesce(p->'people', '[]'::jsonb), nullif(left(btrim(p->>'place'), 120), ''),
              coalesce((p->>'owner_pays')::boolean, false), coalesce(p->>'transport', 'GRAB'), nullif(left(btrim(p->>'note'), 300), ''),
              coalesce(p->'estimate', '{}'::jsonb), nullif(p->>'budget', '')::bigint)
      returning * into e;
    else
      update public.pf_event_plan set
        title = left(btrim(p->>'title'), 120), kind = coalesce(p->>'kind', e.kind), starts_at = s, ends_at = f,
        headcount = coalesce((p->>'headcount')::integer, e.headcount), people = coalesce(p->'people', e.people),
        place = case when p ? 'place' then nullif(left(btrim(p->>'place'), 120), '') else e.place end,
        owner_pays = coalesce((p->>'owner_pays')::boolean, e.owner_pays), transport = coalesce(p->>'transport', e.transport),
        note = case when p ? 'note' then nullif(left(btrim(p->>'note'), 300), '') else e.note end,
        estimate = coalesce(p->'estimate', e.estimate), budget = coalesce(nullif(p->>'budget', '')::bigint, e.budget),
        reminded_at = case when e.starts_at <> s then null else e.reminded_at end,
        updated_at = now(), version = e.version + 1
      where id = e.id returning * into e;
    end if;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  return pf_private.event_plan_json(e);
end $$;

-- p_state null = every state. Newest first by start time, bounded.
create function public.pf_plan_event_list(p_owner uuid, p_state text, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.event_plan_json(e) order by e.starts_at desc)
                     from (select * from public.pf_event_plan
                            where owner_id = p_owner and (p_state is null or state = p_state)
                              and (p_from is null or ends_at >= p_from) and (p_to is null or starts_at < p_to)
                            order by starts_at desc limit 200) e), '[]'::jsonb);
end $$;

create function public.pf_plan_event_get(p_owner uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan;
begin
  perform pf_private.assert_owner(p_owner);
  select * into e from public.pf_event_plan where id = p_id and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return pf_private.event_plan_json(e);
end $$;

-- DONE (with the actual snapshot) or CANCELLED. A DONE plan can be closed again (refreshed actual), a cancelled one not.
create function public.pf_plan_event_close(p_owner uuid, p_id uuid, p_state text, p_actual jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare e public.pf_event_plan;
begin
  perform pf_private.assert_owner(p_owner);
  if p_state not in ('DONE', 'CANCELLED') then perform pf_private.err('VALIDATION_FAILED'); end if;
  select * into e from public.pf_event_plan where id = p_id and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if e.state = 'CANCELLED' then perform pf_private.err('INVALID_STATE'); end if;
  update public.pf_event_plan set state = p_state,
         actual = case when p_state = 'DONE' and jsonb_typeof(p_actual) = 'object' then p_actual else e.actual end,
         closed_at = now(), updated_at = now(), version = e.version + 1
   where id = e.id returning * into e;
  return pf_private.event_plan_json(e);
end $$;

-- Reminder / in-event alert bookkeeping (claimed once): true when this call set the flag.
create function public.pf_plan_event_mark(p_owner uuid, p_id uuid, p_what text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  if p_what = 'REMINDED' then
    update public.pf_event_plan set reminded_at = now() where id = p_id and owner_id = p_owner and reminded_at is null;
  elsif p_what = 'ALERTED' then
    update public.pf_event_plan set alerted_at = now() where id = p_id and owner_id = p_owner and alerted_at is null;
  else
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- ---------------------------------------------------------------- history reads for estimation / actuals
-- Money out between p_from and p_to (posted EXPENSE / UNKNOWN_DEBIT), with the owner's own share when a split was
-- applied (the others' shares became their debts) and the group size of that split. Debt money, recurring payments
-- (rent, bills) and transfers are not part of an outing, so they are left out.
create function public.pf_plan_spend_rows(p_owner uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  -- Text normalisation and the ride / food flags are computed here (Postgres), not in the Worker: the API has a
  -- 10 ms CPU budget per request on the free plan. The word lists mirror modules/plans/estimate.ts.
  return coalesce((select jsonb_agg(r.j order by r.at) from (
    select t.effective_at as at, jsonb_build_object(
             'id', t.id, 'at', t.effective_at, 'kind', t.kind, 'amount', t.amount::text,
             'owner_amount', coalesce(sa.owner_amount, t.amount)::text,
             'group_size', case when sa.id is not null then jsonb_array_length(sa.shares) + 1 end,
             'category', c.name, 'merchant', t.merchant, 'note', left(t.note, 160), 'account_id', t.account_id,
             'hour', extract(hour from t.effective_at at time zone 'Asia/Ho_Chi_Minh')::integer,
             'norm', x.c || x.t,
             'ride', x.t !~ '\m(xang|gui xe|do xe|bai xe|rua xe|sua xe|ve xe|ve may bay|bao duong)\M'
                     and (x.t ~ '\m(grab|be|xanh sm|xanhsm|gojek|taxi|xe om|uber|vinasun|mai linh|grabcar|grabbike|gsm)\M'
                          or (x.c ~ '\mdi chuyen\M' and t.amount between 12000 and 600000)),
             'food', x.c ~ '\m(an uong|an|nha hang|do uong|giai tri|nhau|cafe|ca phe)\M'
                     or x.t ~ '\m(nhau|bia|beer|lau|nuong|oc|quan|nha hang|buffet|karaoke|pub|bar|an|com|pho|bun|cafe|ca phe|tra sua|coffee|highlands|phuc long|katinat|starbucks)\M') as j
      from public.pf_tx t
      left join public.pf_category c on c.id = t.category_id
      cross join lateral (select ' ' || pf_private.ai_norm(c.name) || ' ' as c,
                                 ' ' || pf_private.ai_norm(concat_ws(' ', t.merchant, t.note)) || ' ' as t) x
      left join lateral (select a.id, a.owner_amount, a.shares from public.pf_split_application a
                          where a.tx_id = t.id and a.state = 'APPLIED' order by a.created_at desc limit 1) sa on true
     where t.owner_id = p_owner and t.status = 'POSTED' and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT')
       and t.effective_at >= p_from and t.effective_at < p_to
       and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
       and not exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id)
       and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)
     order by t.effective_at desc limit 1200) r), '[]'::jsonb);  -- bounded: the API must stay light (Workers free plan)
end $$;

-- Income / expense per Vietnam calendar month for the last p_months months (current month included, flagged partial).
create function public.pf_plan_months(p_owner uuid, p_months integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare n integer := least(greatest(coalesce(p_months, 12), 1), 36);
        cur date := date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('month', to_char(m.m, 'YYYY-MM'), 'income', coalesce(x.income, 0)::text,
                     'expense', coalesce(x.expense, 0)::text, 'partial', m.m = cur) order by m.m)
    from generate_series(cur - make_interval(months => n - 1), cur, interval '1 month') as m(m)
    left join (
      select date_trunc('month', j.effective_at at time zone 'Asia/Ho_Chi_Minh')::date as mm,
             -sum(e.signed_amount::numeric) filter (where a.class = 'INCOME') as income,
             sum(e.signed_amount::numeric) filter (where a.class = 'EXPENSE') as expense
        from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
        join public.pf_ledger_account a on a.id = e.ledger_account_id
       where j.owner_id = p_owner and a.code not in ('SYS_ADJUSTMENT_IN', 'SYS_ADJUSTMENT_OUT')
         and j.effective_at >= (cur - make_interval(months => n - 1))::timestamp at time zone 'Asia/Ho_Chi_Minh'
       group by 1) x on x.mm = m.m::date), '[]'::jsonb);
end $$;

-- What the owner has now: known assets / liabilities, debts both ways, and every active goal with its saved amount.
create function public.pf_plan_wealth(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare assets numeric; liabilities numeric; receivable numeric; payable numeric;
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(sum(b.debit_net) filter (where b.class = 'ASSET'), 0), coalesce(-sum(b.debit_net) filter (where b.class = 'LIABILITY'), 0)
    into assets, liabilities
    from public.pf_account a join pf_private.ledger_balance b on b.id = a.ledger_account_id
   where a.owner_id = p_owner and a.baseline_known and not a.archived;
  select coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'RECEIVABLE'), 0),
         coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'PAYABLE'), 0)
    into receivable, payable from public.pf_debt d where d.owner_id = p_owner and d.state in ('OPEN', 'PARTIAL');
  return jsonb_build_object('assets', assets::text, 'liabilities', liabilities::text, 'receivable', receivable::text,
    'payable', payable::text,
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'target', g.target::text,
                          'due_date', g.due_date, 'state', g.state,
                          'allocated', coalesce((select sum(al.signed_amount::numeric) from public.pf_allocation al where al.goal_id = g.id), 0)::text)
                        order by g.name)
                        from public.pf_goal g where g.owner_id = p_owner and g.state = 'ACTIVE'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- life plans
create function pf_private.life_plan_json(l public.pf_life_plan) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', l.id, 'name', l.name, 'kind', l.kind, 'price', l.price::text, 'down_pct', l.down_pct,
    'loan_rate_pct', l.loan_rate_pct, 'loan_years', l.loan_years, 'inflation_pct', l.inflation_pct,
    'income_growth_pct', l.income_growth_pct, 'extra_saving', l.extra_saving::text, 'goal_id', l.goal_id,
    'target_date', l.target_date, 'created_at', l.created_at, 'updated_at', l.updated_at, 'version', l.version)
$$;

create function public.pf_life_plan_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l public.pf_life_plan; pid uuid; gid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if jsonb_typeof(p) <> 'object' or coalesce(btrim(p->>'name'), '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  begin
    pid := nullif(p->>'id', '')::uuid;
    gid := nullif(p->>'goal_id', '')::uuid;
  exception when others then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  if gid is not null and not exists (select 1 from public.pf_goal where id = gid and owner_id = p_owner) then
    perform pf_private.err('NOT_FOUND');
  end if;
  if pid is not null then
    select * into l from public.pf_life_plan where id = pid for update;
    if found and (l.owner_id <> p_owner or l.archived) then perform pf_private.err('NOT_FOUND'); end if;
  end if;
  begin
    if l.id is null then
      insert into public.pf_life_plan(id, owner_id, name, kind, price, down_pct, loan_rate_pct, loan_years, inflation_pct,
                                      income_growth_pct, extra_saving, goal_id, target_date)
      values (coalesce(pid, gen_random_uuid()), p_owner, left(btrim(p->>'name'), 120), coalesce(p->>'kind', 'OTHER'),
              (p->>'price')::bigint, coalesce((p->>'down_pct')::numeric, 100), coalesce((p->>'loan_rate_pct')::numeric, 0),
              coalesce((p->>'loan_years')::smallint, 0), (p->>'inflation_pct')::numeric,
              (p->>'income_growth_pct')::numeric, coalesce((p->>'extra_saving')::bigint, 0), gid,
              nullif(p->>'target_date', '')::date)
      returning * into l;
    else
      update public.pf_life_plan set
        name = left(btrim(p->>'name'), 120), kind = coalesce(p->>'kind', l.kind), price = coalesce((p->>'price')::bigint, l.price),
        down_pct = coalesce((p->>'down_pct')::numeric, l.down_pct), loan_rate_pct = coalesce((p->>'loan_rate_pct')::numeric, l.loan_rate_pct),
        loan_years = coalesce((p->>'loan_years')::smallint, l.loan_years),
        inflation_pct = case when p ? 'inflation_pct' then (p->>'inflation_pct')::numeric else l.inflation_pct end,
        income_growth_pct = case when p ? 'income_growth_pct' then (p->>'income_growth_pct')::numeric else l.income_growth_pct end,
        extra_saving = coalesce((p->>'extra_saving')::bigint, l.extra_saving),
        goal_id = case when p ? 'goal_id' then gid else l.goal_id end,
        target_date = case when p ? 'target_date' then nullif(p->>'target_date', '')::date else l.target_date end,
        updated_at = now(), version = l.version + 1
      where id = l.id returning * into l;
    end if;
  exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range
                  or invalid_datetime_format then
    perform pf_private.err('VALIDATION_FAILED');
  end;
  return pf_private.life_plan_json(l);
end $$;

create function public.pf_life_plan_list(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.life_plan_json(l) order by l.created_at)
                     from public.pf_life_plan l where l.owner_id = p_owner and not l.archived), '[]'::jsonb);
end $$;

-- Archived, never deleted (the linked goal and its savings stay untouched).
create function public.pf_life_plan_delete(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_life_plan set archived = true, updated_at = now(), version = version + 1
   where id = p_id and owner_id = p_owner and not archived;
  get diagnostics n = row_count;
  if n = 0 then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('id', p_id, 'archived', true);
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

-- ===================================================== 20261129000022_lifecycle.sql
-- MoMa migration 022: data lifecycle (retention + distillation) and capacity monitoring. Free tiers only (D-028):
-- the whole app must live inside Supabase Free (500 MB) for years, so detail that has served its purpose is compacted
-- or deleted, while everything that makes the app smarter is kept or distilled first.
--
-- KEEP forever: the ledger (pf_tx / pf_journal / pf_entry, append-only), accounts, categories, contacts, debts and
--   payments, goals, budgets, recurring rules, splits, learned AI memory, owner classification decisions, rejected
--   pair decisions (so nothing is suggested twice), attachment metadata, monthly stats and capacity snapshots.
-- COMPACT: bank event payloads (essential fields only), classifier explanations, AI usage (monthly rollup),
--   audit detail (monthly counts).
-- DELETE: idempotency results past the client retry window, the sync change feed, push dedupe keys, finished jobs,
--   read notifications, expired rate-limit buckets, day-level insights, past meal skips, old capacity snapshots.
--
-- The policy is a table (pf_private.retention_policy): a table created later (4Life lf_*, knowledge kn_*) is covered
-- by inserting a row; a policy whose table or columns do not exist yet is skipped, never an error. Every run is a
-- bounded batch per table (LIMIT), so it fits the Worker cron and can be repeated by the GitHub Actions maintenance job
-- until "more" is false. Idempotent.
-- Server role only.
begin;

-- ---------------------------------------------------------------- policy
create table pf_private.retention_policy (
  tbl text primary key check (tbl ~ '^[a-z_][a-z0-9_]*$'),
  action text not null check (action in ('DELETE', 'COMPACT', 'ROLLUP', 'KEEP')),
  ts_col text check (ts_col is null or ts_col ~ '^[a-z_][a-z0-9_]*$'),
  keep_for interval,
  extra_where text,        -- trusted SQL predicate written in migrations only (never from requests)
  batch integer not null default 500 check (batch between 1 and 5000),
  why text not null
);

insert into pf_private.retention_policy(tbl, action, ts_col, keep_for, extra_where, batch, why) values
  -- idempotency: the app outbox holds offline commands for at most 30 days; 60 days leaves a full margin
  ('pf_command', 'DELETE', 'created_at', '60 days', null, 1000, 'Kết quả lệnh chỉ cần trong cửa sổ gửi lại (outbox ≤ 30 ngày)'),
  ('pf_change', 'DELETE', 'created_at', '30 days', null, 2000, 'Nhật ký đồng bộ: app làm mới toàn bộ khi thiếu, không ai đọc lịch sử'),
  ('pf_push_log', 'DELETE', 'sent_at', '90 days', null, 1000, 'Khóa chống gửi trùng theo ngày/tuần/tháng; cửa sổ dài nhất < 90 ngày'),
  ('pf_job', 'DELETE', 'due_at', '14 days', $$state in ('DONE', 'DEAD')$$, 1000, 'Việc nền đã xong'),
  ('pf_notification', 'DELETE', 'created_at', '120 days', 'read_at is not null', 1000, 'Thông báo đã đọc; vẫn giữ giới hạn 500 mục'),
  ('pf_rate_limit', 'DELETE', 'expires_at', '0 days', null, 2000, 'Bộ đếm giới hạn tốc độ đã hết hạn'),
  ('pf_reminder_skip', 'DELETE', 'created_at', '60 days', null, 1000, 'Lựa chọn "hôm nay không" chỉ có ý nghĩa trong ngày'),
  ('pf_insight', 'DELETE', 'created_at', '180 days', $$period = 'DAY'$$, 500, 'Nhận xét theo ngày; tuần/tháng giữ lại, số liệu đã chưng cất vào pf_month_stat'),
  ('pf_capacity_snapshot', 'DELETE', 'created_at', '730 days', null, 500, 'Ảnh chụp dung lượng giữ 2 năm'),
  ('pf_goal_proposal', 'DELETE', 'created_at', '180 days', $$state = 'DISMISSED'$$, 500, 'Đề xuất trích tiền đã bỏ qua'),
  ('pf_inbound_event', 'COMPACT', 'received_at', '90 days', null, 500, 'Sự kiện ngân hàng: chỉ giữ trường cốt lõi (mã tham chiếu, số tiền, thời điểm, nội dung ≤ 200 ký tự)'),
  ('pf_tx_classification', 'COMPACT', 'updated_at', '180 days', $$status in ('APPLIED', 'SUGGESTED')$$, 1000, 'Giữ quyết định phân loại, bỏ lời giải thích'),
  ('pf_ai_usage', 'ROLLUP', 'created_at', '90 days', null, 1000, 'Chi phí AI gộp theo tháng/model rồi xóa chi tiết'),
  ('pf_audit', 'ROLLUP', 'created_at', '365 days', null, 1000, 'Nhật ký kiểm toán gộp số lượng theo tháng rồi xóa chi tiết'),
  -- future tables: active as soon as they exist
  ('kn_item', 'DELETE', 'valid_until', '0 days', null, 1000, 'Tri thức đã hết hạn (4Life/MoMa, chưa có bảng)'),
  -- explicit KEEP rows document the core truth (the runner ignores them)
  ('pf_tx', 'KEEP', null, null, null, 1, 'Sổ cái: giao dịch (bất biến)'),
  ('pf_journal', 'KEEP', null, null, null, 1, 'Sổ cái: bút toán (bất biến)'),
  ('pf_entry', 'KEEP', null, null, null, 1, 'Sổ cái: dòng bút toán (bất biến)'),
  ('pf_ai_memory', 'KEEP', null, null, null, 1, 'Những gì Trợ lý đã học'),
  ('pf_transfer_pair', 'KEEP', null, null, null, 1, 'Quyết định ghép/không ghép, chống đề xuất lại'),
  ('pf_same_payment', 'KEEP', null, null, null, 1, 'Quyết định gộp/không trùng, chống đề xuất lại'),
  ('pf_split_application', 'KEEP', null, null, null, 1, 'Chia hóa đơn và nợ phát sinh'),
  ('pf_tx_attachment', 'KEEP', null, null, null, 1, 'Ảnh chứng từ (ảnh nằm trên R2)');

-- ---------------------------------------------------------------- distilled / summary tables
-- Monthly per-category totals from the ledger (owner share for split bills, reversals netted). category_id null =
-- the month's total for that type.
create table public.pf_month_stat (
  owner_id uuid not null references public.pf_owner(user_id),
  month date not null check (extract(day from month) = 1),
  type text not null check (type in ('EXPENSE', 'INCOME')),
  category_id uuid references public.pf_category(id),
  tx_count integer not null default 0,
  total numeric(20, 0) not null default 0,
  avg numeric(20, 0) not null default 0,
  p50 numeric(20, 0) not null default 0,
  computed_at timestamptz not null default now()
);
create unique index pf_month_stat_uq on public.pf_month_stat(owner_id, month, type, coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table public.pf_ai_usage_month (
  owner_id uuid not null references public.pf_owner(user_id),
  period date not null check (extract(day from period) = 1),
  model text not null,
  feature text not null default 'other',
  calls integer not null default 0,
  spent_micro_usd bigint not null default 0,
  unknown_calls integer not null default 0,
  primary key (owner_id, period, model, feature)
);

-- Which part of the app made each AI call (agent, classify, bill, insight, reflect, plan, knowledge...).
alter table public.pf_ai_usage add column if not exists feature text check (feature is null or feature ~ '^[a-z_]{1,20}$');

-- Same guard as 006, plus the feature tag. The 5-argument version stays for callers that do not tag.
create function public.pf_ai_reserve(p_owner uuid, p_estimate bigint, p_cap bigint, p_provider text, p_model text, p_feature text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare res jsonb;
begin
  res := public.pf_ai_reserve(p_owner, p_estimate, p_cap, p_provider, p_model);
  if p_feature ~ '^[a-z_]{1,20}$' then
    update public.pf_ai_usage set feature = p_feature where id = (res->>'id')::uuid;
  end if;
  return res;
end $$;

create table public.pf_audit_month (
  owner_id uuid not null references public.pf_owner(user_id),
  month date not null check (extract(day from month) = 1),
  action text not null,
  n integer not null default 0,
  primary key (owner_id, month, action)
);

create table public.pf_capacity_snapshot (
  owner_id uuid not null references public.pf_owner(user_id),
  week date not null,                       -- Monday (ISO week) in Vietnam time
  db_bytes bigint not null,
  r2_bytes bigint not null default 0,
  attachments integer not null default 0,
  tx_count bigint not null default 0,
  top jsonb not null default '[]'::jsonb,   -- [{table, bytes, rows}] largest relations
  ai_micro_usd bigint not null default 0,   -- AI spend of the snapshot's month so far
  created_at timestamptz not null default now(),
  primary key (owner_id, week)
);

create table public.pf_lifecycle_state (
  owner_id uuid primary key references public.pf_owner(user_id),
  last_run_at timestamptz,
  last_result jsonb not null default '{}'::jsonb,
  runs integer not null default 0,
  r2_cursor text,
  r2_swept_at timestamptz,
  month_stat_through date,                  -- last closed month already distilled (empty months included)
  warned_level integer not null default 0   -- 0 / 60 / 80: highest capacity warning already sent
);

alter table public.pf_month_stat enable row level security;
alter table public.pf_ai_usage_month enable row level security;
alter table public.pf_audit_month enable row level security;
alter table public.pf_capacity_snapshot enable row level security;
alter table public.pf_lifecycle_state enable row level security;
revoke all on table public.pf_month_stat, public.pf_ai_usage_month, public.pf_audit_month, public.pf_capacity_snapshot,
  public.pf_lifecycle_state from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
create function pf_private.lc_has_col(p_tbl text, p_col text) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = p_tbl and column_name = p_col)
$$;

-- Bank payload reduced to what anything still reads (transfer_refs uses 'reference') + what a human may want later.
create function pf_private.lc_compact_payload(p jsonb) returns jsonb
language sql immutable set search_path = pg_catalog as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'reference', coalesce(p->>'reference', p->>'referenceCode'),
    'amount', coalesce(p->>'amount', p->>'transferAmount'),
    'type', p->>'transferType',
    'at', coalesce(p->>'transactionDate', p->>'at'),
    'gateway', p->>'gateway',
    'last4', right(nullif(regexp_replace(coalesce(p->>'accountNumber', ''), '[^0-9]', '', 'g'), ''), 4),
    'content', left(coalesce(p->>'content', p->>'description'), 200),
    '_compacted', true))
$$;

-- One bounded step for one policy. Returns the number of rows touched.
create function pf_private.lc_apply(p_owner uuid, p pf_private.retention_policy) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare n integer := 0; owned boolean; cutoff timestamptz; w text;
begin
  if p.action = 'KEEP' or to_regclass('public.' || p.tbl) is null or p.ts_col is null
     or not pf_private.lc_has_col(p.tbl, p.ts_col) then
    return 0;
  end if;
  owned := pf_private.lc_has_col(p.tbl, 'owner_id');
  cutoff := now() - coalesce(p.keep_for, '0 days'::interval);
  w := format('%I < %L', p.ts_col, cutoff)
       || case when owned then format(' and owner_id = %L', p_owner) else '' end
       || case when p.extra_where is not null then ' and (' || p.extra_where || ')' else '' end;

  if p.action = 'DELETE' then
    execute format('delete from public.%I where ctid in (select ctid from public.%I where %s limit %s)', p.tbl, p.tbl, w, p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'COMPACT' and p.tbl = 'pf_inbound_event' then
    update public.pf_inbound_event set payload = pf_private.lc_compact_payload(payload)
     where id in (select id from public.pf_inbound_event
                   where owner_id = p_owner and received_at < cutoff and not (payload ? '_compacted') limit p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'COMPACT' and p.tbl = 'pf_tx_classification' then
    update public.pf_tx_classification set reason = null
     where tx_id in (select tx_id from public.pf_tx_classification
                      where owner_id = p_owner and updated_at < cutoff and status in ('APPLIED', 'SUGGESTED')
                        and reason is not null limit p.batch);
    get diagnostics n = row_count;

  elsif p.action = 'ROLLUP' and p.tbl = 'pf_ai_usage' then
    -- whole months only, so a month is never split between detail and summary
    cutoff := date_trunc('month', cutoff);
    with gone as (
      delete from public.pf_ai_usage where id in (
        select id from public.pf_ai_usage where owner_id = p_owner and period < cutoff::date
         order by period limit p.batch)
      returning period, model, coalesce(feature, 'other') as feature, spent_micro_usd, state)
    insert into public.pf_ai_usage_month(owner_id, period, model, feature, calls, spent_micro_usd, unknown_calls)
      select p_owner, period, model, feature, count(*), sum(spent_micro_usd), count(*) filter (where state = 'UNKNOWN_CHARGE')
        from gone group by period, model, feature
    on conflict (owner_id, period, model, feature) do update set
      calls = pf_ai_usage_month.calls + excluded.calls,
      spent_micro_usd = pf_ai_usage_month.spent_micro_usd + excluded.spent_micro_usd,
      unknown_calls = pf_ai_usage_month.unknown_calls + excluded.unknown_calls;
    get diagnostics n = row_count;

  elsif p.action = 'ROLLUP' and p.tbl = 'pf_audit' then
    with gone as (
      delete from public.pf_audit where id in (
        select id from public.pf_audit where owner_id = p_owner and created_at < cutoff order by id limit p.batch)
      returning created_at, action)
    insert into public.pf_audit_month(owner_id, month, action, n)
      select p_owner, date_trunc('month', created_at at time zone 'Asia/Ho_Chi_Minh')::date, action, count(*)
        from gone group by 2, 3
    on conflict (owner_id, month, action) do update set n = pf_audit_month.n + excluded.n;
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- Distils one closed month (Vietnam time) of the ledger into pf_month_stat. Net per transaction and category, so a
-- reversed transaction counts zero and a split bill counts only the owner's share.
create function pf_private.lc_month_stat(p_owner uuid, p_month date) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare n integer;
begin
  delete from public.pf_month_stat where owner_id = p_owner and month = p_month;
  with lines as (
    select c.id as cat, c.type, j.tx_id, sum(e.signed_amount::numeric) as amt
      from public.pf_journal j
      join public.pf_entry e on e.journal_id = j.id
      join public.pf_category c on c.ledger_account_id = e.ledger_account_id
     where j.owner_id = p_owner and j.posted
       and j.effective_at >= (p_month::timestamp at time zone 'Asia/Ho_Chi_Minh')
       and j.effective_at < ((p_month + interval '1 month')::timestamp at time zone 'Asia/Ho_Chi_Minh')
     group by c.id, c.type, j.tx_id),
  v as (
    select cat, type, case when type = 'EXPENSE' then amt else -amt end as v from lines where amt <> 0),
  agg as (
    select cat, type, count(*) filter (where v > 0) as cnt, sum(v) as total,
           coalesce(percentile_cont(0.5) within group (order by v) filter (where v > 0), 0) as p50
      from v group by grouping sets ((cat, type), (type)))
  insert into public.pf_month_stat(owner_id, month, type, category_id, tx_count, total, avg, p50)
    select p_owner, p_month, type, cat, cnt, round(total), case when cnt > 0 then round(total / cnt) else 0 end, round(p50)
      from agg where type is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- runner
-- One bounded maintenance pass: every policy once (batch-limited) + up to 3 closed months distilled (the previous
-- month is re-distilled during the first 10 days of a month, for late captures). Returns per-table counts and
-- more = true when any batch was full (call again).
create function public.pf_lifecycle_run(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p pf_private.retention_policy; n integer; res jsonb := '{}'::jsonb; more boolean := false;
        cur date; prev date; m date; first_m date; through date; done_months integer := 0; stats integer := 0; vn timestamp;
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-lifecycle'), hashtext(p_owner::text));
  for p in select * from pf_private.retention_policy where action <> 'KEEP' order by tbl loop
    n := pf_private.lc_apply(p_owner, p);
    if n > 0 then res := res || jsonb_build_object(p.tbl, n); end if;
    if n >= p.batch then more := true; end if;
  end loop;

  vn := now() at time zone 'Asia/Ho_Chi_Minh';
  cur := date_trunc('month', vn)::date;
  prev := (cur - interval '1 month')::date;
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  select month_stat_through into through from public.pf_lifecycle_state where owner_id = p_owner for update;
  -- first month with any income/expense category activity (opening balances and transfers do not count)
  select date_trunc('month', min(j.effective_at) at time zone 'Asia/Ho_Chi_Minh')::date into first_m
    from public.pf_journal j
   where j.owner_id = p_owner and j.posted
     and exists (select 1 from public.pf_entry e join public.pf_category c on c.ledger_account_id = e.ledger_account_id
                  where e.journal_id = j.id);
  if first_m is not null then
    m := greatest(first_m, coalesce((through + interval '1 month')::date, first_m));
    while m <= prev and done_months < 3 loop
      stats := stats + pf_private.lc_month_stat(p_owner, m);
      update public.pf_lifecycle_state set month_stat_through = m where owner_id = p_owner;
      through := m;
      done_months := done_months + 1;
      m := (m + interval '1 month')::date;
    end loop;
    if m <= prev then more := true; end if;
    -- late captures of the previous month: refresh it once a day during the first 10 days of a new month
    if done_months = 0 and through >= prev and extract(day from vn) <= 10
       and coalesce((select max(computed_at) from public.pf_month_stat where owner_id = p_owner and month = prev), 'epoch')
           < now() - interval '20 hours' then
      stats := stats + pf_private.lc_month_stat(p_owner, prev);
      done_months := 1;
    end if;
  end if;

  res := jsonb_build_object('tables', res, 'month_stats', stats, 'months', done_months, 'more', more, 'at', now());
  update public.pf_lifecycle_state set last_run_at = now(), last_result = res, runs = runs + 1 where owner_id = p_owner;
  return res;
end $$;

-- ---------------------------------------------------------------- capacity
create function pf_private.lc_r2_bytes(p_owner uuid) returns table (bytes bigint, files integer)
language plpgsql stable set search_path = pg_catalog, public as $$
declare b bigint := 0; f integer := 0; b2 bigint; f2 integer;
begin
  if to_regclass('public.pf_tx_attachment') is not null then
    select coalesce(sum(size_bytes), 0), count(*) into b, f from public.pf_tx_attachment where owner_id = p_owner;
  end if;
  select coalesce(sum(size_bytes), 0), count(*) into b2, f2 from public.pf_attachment where owner_id = p_owner;
  return query select b + b2, f + f2;
end $$;

create function pf_private.lc_top_tables(p_limit integer) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('table', t.relname, 'bytes', t.bytes, 'rows', t.rows) order by t.bytes desc), '[]'::jsonb)
    from (select c.relname, pg_total_relation_size(c.oid) as bytes, greatest(c.reltuples, 0)::bigint as rows
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'
           order by pg_total_relation_size(c.oid) desc limit p_limit) t
$$;

-- Records this week's snapshot (once per ISO week, Vietnam time). Returns the snapshot and the warning level that
-- should be pushed now (0 = none): 60 / 80 the first time the database crosses that share of p_limit_bytes.
create function public.pf_capacity_record(p_owner uuid, p_limit_bytes bigint) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare wk date; db bigint; r record; ai bigint; txn bigint; pct numeric; lvl integer := 0; warned integer;
begin
  perform pf_private.assert_owner(p_owner);
  wk := date_trunc('week', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  db := pg_database_size(current_database());
  select * into r from pf_private.lc_r2_bytes(p_owner);
  select coalesce(sum(spent_micro_usd), 0) into ai from public.pf_ai_usage
   where owner_id = p_owner and period = date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  select count(*) into txn from public.pf_tx where owner_id = p_owner;
  insert into public.pf_capacity_snapshot(owner_id, week, db_bytes, r2_bytes, attachments, tx_count, top, ai_micro_usd)
    values (p_owner, wk, db, r.bytes, r.files, txn, pf_private.lc_top_tables(8), ai)
    on conflict (owner_id, week) do update set db_bytes = excluded.db_bytes, r2_bytes = excluded.r2_bytes,
      attachments = excluded.attachments, tx_count = excluded.tx_count, top = excluded.top,
      ai_micro_usd = excluded.ai_micro_usd, created_at = now();
  pct := case when coalesce(p_limit_bytes, 0) > 0 then 100.0 * db / p_limit_bytes else 0 end;
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  select warned_level into warned from public.pf_lifecycle_state where owner_id = p_owner for update;
  if pct >= 80 and warned < 80 then lvl := 80;
  elsif pct >= 60 and warned < 60 then lvl := 60;
  end if;
  -- falling back under a level (after cleanup / archiving) re-arms it
  update public.pf_lifecycle_state set warned_level = case when lvl > 0 then lvl
                                                            when pct < 55 then 0
                                                            when pct < 75 then least(warned_level, 60)
                                                            else warned_level end
   where owner_id = p_owner;
  return jsonb_build_object('week', wk, 'db_bytes', db, 'pct', round(pct, 1), 'warn', lvl);
end $$;

-- Everything the capacity screen needs; the projection is computed by the API from 'history'.
create function public.pf_capacity_report(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r record; st public.pf_lifecycle_state; month_start date;
begin
  perform pf_private.assert_owner(p_owner);
  select * into r from pf_private.lc_r2_bytes(p_owner);
  select * into st from public.pf_lifecycle_state where owner_id = p_owner;
  month_start := date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh')::date;
  return jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'top', pf_private.lc_top_tables(8),
    'r2_bytes', r.bytes, 'attachments', r.files,
    'tx_count', (select count(*) from public.pf_tx where owner_id = p_owner),
    'history', coalesce((select jsonb_agg(jsonb_build_object('week', s.week, 'db_bytes', s.db_bytes, 'r2_bytes', s.r2_bytes)
                                           order by s.week)
                           from (select * from public.pf_capacity_snapshot where owner_id = p_owner
                                  order by week desc limit 26) s), '[]'::jsonb),
    'ai', jsonb_build_object(
      'this_month_micro_usd', (select coalesce(sum(spent_micro_usd), 0) from public.pf_ai_usage
                                where owner_id = p_owner and period = month_start),
      'this_month_calls', (select count(*) from public.pf_ai_usage
                            where owner_id = p_owner and period = month_start and state = 'SETTLED'),
      'by_feature', coalesce((select jsonb_agg(jsonb_build_object('feature', f.feature, 'calls', f.calls, 'micro_usd', f.spent)
                                                order by f.spent desc)
                                from (select coalesce(feature, 'other') as feature, count(*) as calls, sum(spent_micro_usd) as spent
                                        from public.pf_ai_usage
                                       where owner_id = p_owner and period = month_start and state <> 'RELEASED'
                                       group by 1) f), '[]'::jsonb),
      'months', coalesce((select jsonb_agg(jsonb_build_object('period', x.period, 'micro_usd', x.spent) order by x.period)
                            from (select period, sum(spent) as spent from (
                                    select period, spent_micro_usd as spent from public.pf_ai_usage where owner_id = p_owner
                                    union all
                                    select period, spent_micro_usd from public.pf_ai_usage_month where owner_id = p_owner) u
                                  where period >= month_start - interval '11 months'
                                  group by period) x), '[]'::jsonb)),
    'last_run_at', st.last_run_at, 'last_result', coalesce(st.last_result, '{}'::jsonb), 'runs', coalesce(st.runs, 0),
    'r2_swept_at', st.r2_swept_at);
end $$;

-- ---------------------------------------------------------------- R2 orphan sweep (bounded, driven by the API)
-- Of the given object keys (one page of an R2 listing under the owner's prefix), the ones no attachment row uses.
create function public.pf_lifecycle_r2_orphans(p_owner uuid, p_keys text[]) returns text[]
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare out text[];
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(array_agg(k), '{}') into out
    from unnest(coalesce(p_keys, '{}')) k
   where k like p_owner::text || '/%'
     and (to_regclass('public.pf_tx_attachment') is null
          or not exists (select 1 from public.pf_tx_attachment a where a.object_key = k))
     and not exists (select 1 from public.pf_attachment a where a.object_key = k);
  return out;
end $$;

create function public.pf_lifecycle_r2_cursor(p_owner uuid, p_cursor text, p_done boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  insert into public.pf_lifecycle_state(owner_id) values (p_owner) on conflict do nothing;
  update public.pf_lifecycle_state set r2_cursor = case when p_done then null else p_cursor end,
         r2_swept_at = case when p_done then now() else r2_swept_at end
   where owner_id = p_owner;
  return (select jsonb_build_object('r2_cursor', r2_cursor, 'r2_swept_at', r2_swept_at)
            from public.pf_lifecycle_state where owner_id = p_owner);
end $$;

create function public.pf_lifecycle_state_get(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select to_jsonb(s) - 'owner_id' from public.pf_lifecycle_state s where s.owner_id = p_owner), '{}'::jsonb);
end $$;

-- Reads for the assistant / reports: distilled monthly history (cheap, survives any detail trimming).
create function public.pf_month_stats(p_owner uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('month', s.month, 'type', s.type, 'category_id', s.category_id,
                     'category', c.name, 'tx_count', s.tx_count, 'total', s.total::text, 'avg', s.avg::text, 'p50', s.p50::text)
                     order by s.month, s.type, s.total desc)
                     from public.pf_month_stat s left join public.pf_category c on c.id = s.category_id
                    where s.owner_id = p_owner and s.month between coalesce(p_from, '2000-01-01') and coalesce(p_to, '2999-12-01')),
                  '[]'::jsonb);
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

