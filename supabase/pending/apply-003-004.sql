-- Bundle of migrations 003 + 004 for pasting into the Supabase SQL Editor (Run and enable RLS).
-- Generated from supabase/migrations; do not edit. Source of truth is the migrations folder.
-- MoMa migration 003: contacts, debts, savings goals, budgets, categories, recurring templates + read models.
-- Also corrects the dashboard: only SYS_ADJUSTMENT_* is excluded from classified income/expense (BR-15, BR-19: fees and
-- bad debt ARE expenses; docs/03 section 7). Append-only: replaces functions from migration 002 via CREATE OR REPLACE.
begin;

-- ---------------------------------------------------------------- extra system ledger accounts (new + existing owner)
create or replace function pf_private.seed_owner(p_owner uuid) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare cid uuid; lid uuid; r record;
begin
  insert into public.pf_ledger_account(owner_id, code, class, name) values
    (p_owner, 'SYS_OPENING_EQUITY', 'EQUITY', 'Vốn đầu kỳ'),
    (p_owner, 'SYS_SUSPENSE_CREDIT', 'CLEARING', 'Tiền vào chưa phân loại'),
    (p_owner, 'SYS_SUSPENSE_DEBIT', 'CLEARING', 'Tiền ra chưa phân loại'),
    (p_owner, 'SYS_TRANSFER_IN_TRANSIT', 'ASSET', 'Tiền đang chuyển'),
    (p_owner, 'SYS_ADJUSTMENT_IN', 'INCOME', 'Điều chỉnh tăng'),
    (p_owner, 'SYS_ADJUSTMENT_OUT', 'EXPENSE', 'Điều chỉnh giảm'),
    (p_owner, 'SYS_BAD_DEBT', 'EXPENSE', 'Nợ xấu'),
    (p_owner, 'SYS_FEE_EXPENSE', 'EXPENSE', 'Phí chuyển khoản'),
    (p_owner, 'SYS_INTEREST_INCOME', 'INCOME', 'Lãi nhận'),
    (p_owner, 'SYS_INTEREST_EXPENSE', 'EXPENSE', 'Lãi trả'),
    (p_owner, 'SYS_DEBT_FORGIVEN', 'INCOME', 'Nợ được xóa');
  for r in select * from (values
      ('EXPENSE','Ăn uống','restaurant'), ('EXPENSE','Di chuyển','directions_car'), ('EXPENSE','Nhà ở','home'),
      ('EXPENSE','Hóa đơn','receipt_long'), ('EXPENSE','Mua sắm','shopping_bag'), ('EXPENSE','Giải trí','sports_esports'),
      ('EXPENSE','Sức khỏe','favorite'), ('EXPENSE','Giáo dục','school'), ('EXPENSE','Khác','more_horiz'),
      ('INCOME','Lương','payments'), ('INCOME','Thưởng','redeem'), ('INCOME','Lãi','savings'), ('INCOME','Thu nhập khác','add_card')
    ) as t(type, name, icon) loop
    cid := gen_random_uuid(); lid := gen_random_uuid();
    insert into public.pf_ledger_account(id, owner_id, code, class, name) values (lid, p_owner, 'CAT_' || cid, r.type::public.pf_ledger_class, r.name);
    insert into public.pf_category(id, owner_id, type, name, ledger_account_id, icon) values (cid, p_owner, r.type, r.name, lid, r.icon);
  end loop;
end $$;

insert into public.pf_ledger_account(owner_id, code, class, name)
select o.user_id, v.code, v.class::public.pf_ledger_class, v.name
  from public.pf_owner o
  cross join (values ('SYS_INTEREST_INCOME', 'INCOME', 'Lãi nhận'),
                     ('SYS_INTEREST_EXPENSE', 'EXPENSE', 'Lãi trả'),
                     ('SYS_DEBT_FORGIVEN', 'INCOME', 'Nợ được xóa')) as v(code, class, name)
on conflict (owner_id, code) do nothing;

-- ---------------------------------------------------------------- helpers
create function pf_private.ledger_total(p_ledger uuid) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(sum(e.signed_amount::numeric), 0)
    from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
   where e.ledger_account_id = p_ledger
$$;

create function pf_private.debt_remaining(p_debt uuid) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select case d.direction when 'RECEIVABLE' then pf_private.ledger_total(d.ledger_account_id)
                          else -pf_private.ledger_total(d.ledger_account_id) end
    from public.pf_debt d where d.id = p_debt
$$;

create function pf_private.require_liquid_account(p_owner uuid, p_account uuid) returns public.pf_account
language plpgsql set search_path = pg_catalog, public as $$
declare a public.pf_account; cls public.pf_ledger_class;
begin
  select * into a from public.pf_account where id = p_account and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if a.archived then perform pf_private.err('ACCOUNT_ARCHIVED'); end if;
  select class into cls from public.pf_ledger_account where id = a.ledger_account_id;
  if cls <> 'ASSET' then perform pf_private.err('VALIDATION_FAILED'); end if;
  return a;
end $$;

-- ---------------------------------------------------------------- contacts
create function pf_private.cmd_contact_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare cid uuid := gen_random_uuid(); alias text := btrim(coalesce(p->>'alias', ''));
begin
  if length(alias) = 0 or length(alias) > 80 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_contact(id, owner_id, alias, note) values (cid, p_owner, alias, left(p->>'note', 500));
  return jsonb_build_object('contact_id', cid, 'change_seq', pf_private.touch_change(p_owner, 'contact', cid, 1));
end $$;

create function pf_private.cmd_contact_update(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare c public.pf_contact;
begin
  select * into c from public.pf_contact where id = (p->>'contact_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if c.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  update public.pf_contact set alias = coalesce(nullif(btrim(p->>'alias'), ''), alias),
         note = case when p ? 'note' then left(p->>'note', 500) else note end,
         archived = coalesce((p->>'archived')::boolean, archived), version = version + 1
   where id = c.id returning * into c;
  return jsonb_build_object('contact_id', c.id, 'change_seq', pf_private.touch_change(p_owner, 'contact', c.id, c.version));
end $$;

-- ---------------------------------------------------------------- debts (BR-07..BR-11, BR-19, BR-20)
create function pf_private.cmd_debt_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare dir text := p->>'direction'; princ bigint; hist boolean := coalesce((p->>'historical')::boolean, false);
        orig timestamptz := (p->>'originated_at')::timestamptz; acc public.pf_account; lines jsonb; j uuid; seq bigint;
        did uuid := gen_random_uuid(); lid uuid := gen_random_uuid(); tx uuid := gen_random_uuid(); eq uuid; counter uuid;
begin
  if dir not in ('RECEIVABLE', 'PAYABLE') then perform pf_private.err('VALIDATION_FAILED'); end if;
  if p ? 'existing_tx_id' then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  princ := pf_private.parse_money(p->>'principal');
  perform 1 from public.pf_contact where id = (p->>'contact_id')::uuid and owner_id = p_owner and not archived;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if hist then
    counter := pf_private.sys_ledger(p_owner, 'SYS_OPENING_EQUITY'); -- historical debt: no cash event
  else
    if not (p ? 'account_id') then perform pf_private.err('VALIDATION_FAILED'); end if;
    acc := pf_private.require_liquid_account(p_owner, (p->>'account_id')::uuid);
    counter := acc.ledger_account_id;
  end if;
  insert into public.pf_ledger_account(id, owner_id, code, class, name)
    values (lid, p_owner, 'DEBT_' || did, case dir when 'RECEIVABLE' then 'ASSET' else 'LIABILITY' end::public.pf_ledger_class, 'Công nợ');
  insert into public.pf_tx(id, owner_id, kind, status, effective_at, note, contact_id, account_id, amount)
    values (tx, p_owner, case dir when 'RECEIVABLE' then 'LOAN_GIVEN' else 'LOAN_RECEIVED' end::public.pf_tx_kind, 'DRAFT', orig,
            left(p->>'note', 1000), (p->>'contact_id')::uuid, acc.id, princ);
  insert into public.pf_debt(id, owner_id, contact_id, ledger_account_id, direction, principal, originated_at, due_date, origin_tx_id, note)
    values (did, p_owner, (p->>'contact_id')::uuid, lid, dir, princ, orig, nullif(p->>'due_date', '')::date, tx, left(p->>'note', 500));
  if dir = 'RECEIVABLE' then  -- receivable up (debit), counter-leg credit (cash out / equity)
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', lid, 'signed_amount', princ::text),
                               jsonb_build_object('ledger_account_id', counter, 'signed_amount', (-princ)::text));
  else                        -- payable up (credit), counter-leg debit (cash in / equity)
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', counter, 'signed_amount', princ::text),
                               jsonb_build_object('ledger_account_id', lid, 'signed_amount', (-princ)::text));
  end if;
  j := pf_private.post_journal(p_owner, tx, orig, 'ORIGINAL', lines);
  update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
  seq := pf_private.touch_change(p_owner, 'debt', did, 1);
  return jsonb_build_object('debt_id', did, 'tx_id', tx, 'change_seq', seq);
end $$;

create function pf_private.cmd_debt_repay(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; acc public.pf_account; princ bigint; intr bigint := 0; rem numeric; eff timestamptz := (p->>'effective_at')::timestamptz;
        tx uuid := gen_random_uuid(); lines jsonb; j uuid; st text; seq bigint;
begin
  if p ? 'existing_tx_id' then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  princ := pf_private.parse_money(p->>'principal');
  if p ? 'interest' then intr := pf_private.parse_money(p->>'interest', false); end if;
  if intr < 0 then perform pf_private.err('INVALID_AMOUNT'); end if;
  acc := pf_private.require_liquid_account(p_owner, (p->>'account_id')::uuid);       -- lock order: account, then debt
  select * into d from public.pf_debt where id = (p->>'debt_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if d.state in ('SETTLED', 'WRITTEN_OFF') then perform pf_private.err('INVALID_STATE'); end if;
  rem := pf_private.debt_remaining(d.id);
  if princ > rem then perform pf_private.err('INSUFFICIENT_PRINCIPAL'); end if;   -- never silently capped (BR-34)
  if d.direction = 'RECEIVABLE' then
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', acc.ledger_account_id, 'signed_amount', (princ + intr)::text),
                               jsonb_build_object('ledger_account_id', d.ledger_account_id, 'signed_amount', (-princ)::text));
    if intr > 0 then lines := lines || jsonb_build_array(jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_INTEREST_INCOME'), 'signed_amount', (-intr)::text)); end if;
  else
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', acc.ledger_account_id, 'signed_amount', (-(princ + intr))::text),
                               jsonb_build_object('ledger_account_id', d.ledger_account_id, 'signed_amount', princ::text));
    if intr > 0 then lines := lines || jsonb_build_array(jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_INTEREST_EXPENSE'), 'signed_amount', intr::text)); end if;
  end if;
  insert into public.pf_tx(id, owner_id, kind, status, effective_at, contact_id, account_id, amount, related_tx_id)
    values (tx, p_owner, case d.direction when 'RECEIVABLE' then 'LOAN_COLLECTED' else 'LOAN_REPAID' end::public.pf_tx_kind, 'DRAFT', eff,
            d.contact_id, acc.id, princ + intr, d.origin_tx_id);
  j := pf_private.post_journal(p_owner, tx, eff, 'ORIGINAL', lines);
  update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
  insert into public.pf_debt_payment(debt_id, tx_id, principal, interest, kind) values (d.id, tx, princ, intr, 'REPAYMENT');
  st := case when rem - princ = 0 then 'SETTLED' else 'PARTIAL' end;
  update public.pf_debt set state = st, version = version + 1 where id = d.id returning version into d.version;
  seq := pf_private.touch_change(p_owner, 'debt', d.id, d.version);
  return jsonb_build_object('debt_id', d.id, 'tx_id', tx, 'remaining', (rem - princ)::text, 'state', st, 'change_seq', seq);
end $$;

create function pf_private.cmd_debt_write_off(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare d public.pf_debt; amt bigint; rem numeric; eff timestamptz := (p->>'effective_at')::timestamptz; tx uuid := gen_random_uuid();
        lines jsonb; j uuid; st text; seq bigint; reason text := btrim(coalesce(p->>'reason', ''));
begin
  if length(reason) = 0 then perform pf_private.err('REASON_REQUIRED'); end if;
  amt := pf_private.parse_money(p->>'amount');
  select * into d from public.pf_debt where id = (p->>'debt_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if d.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if d.state in ('SETTLED', 'WRITTEN_OFF') then perform pf_private.err('INVALID_STATE'); end if;
  rem := pf_private.debt_remaining(d.id);
  if amt > rem then perform pf_private.err('INSUFFICIENT_PRINCIPAL'); end if;
  if d.direction = 'RECEIVABLE' then  -- BR-19: bad-debt expense, no cash
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_BAD_DEBT'), 'signed_amount', amt::text),
                               jsonb_build_object('ledger_account_id', d.ledger_account_id, 'signed_amount', (-amt)::text));
  else                                -- BR-20: payable forgiven = income, no cash
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', d.ledger_account_id, 'signed_amount', amt::text),
                               jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_DEBT_FORGIVEN'), 'signed_amount', (-amt)::text));
  end if;
  insert into public.pf_tx(id, owner_id, kind, status, effective_at, contact_id, amount, note, related_tx_id)
    values (tx, p_owner, case d.direction when 'RECEIVABLE' then 'DEBT_WRITEOFF' else 'DEBT_FORGIVEN' end::public.pf_tx_kind, 'DRAFT', eff,
            d.contact_id, amt, left(reason, 1000), d.origin_tx_id);
  j := pf_private.post_journal(p_owner, tx, eff, 'ORIGINAL', lines);
  update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
  insert into public.pf_debt_payment(debt_id, tx_id, principal, interest, kind) values (d.id, tx, amt, 0, 'WRITEOFF');
  st := case when rem - amt = 0 then 'WRITTEN_OFF' else 'PARTIAL' end;
  update public.pf_debt set state = st, version = version + 1 where id = d.id returning version into d.version;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe) values (p_owner, 'owner', 'DEBT_WRITE_OFF', d.id, jsonb_build_object('reason', left(reason, 200), 'amount', amt::text));
  seq := pf_private.touch_change(p_owner, 'debt', d.id, d.version);
  return jsonb_build_object('debt_id', d.id, 'tx_id', tx, 'remaining', (rem - amt)::text, 'state', st, 'change_seq', seq);
end $$;

-- Reversal must not bypass debt rules (docs/12 section 4): debt-linked transactions need their own domain correction.
create or replace function pf_private.cmd_tx_reverse(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; rj uuid; lines jsonb; seq bigint; reason text := coalesce(p->>'reason', '');
begin
  if length(btrim(reason)) = 0 then perform pf_private.err('REASON_REQUIRED'); end if;
  select * into t from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if t.status <> 'POSTED' or t.current_journal_id is null then perform pf_private.err('INVALID_STATE'); end if;
  if exists (select 1 from public.pf_debt where origin_tx_id = t.id) or exists (select 1 from public.pf_debt_payment where tx_id = t.id) then
    perform pf_private.err('DEBT_LINKED');
  end if;
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo bút toán') order by line_no)
    into lines from public.pf_entry where journal_id = t.current_journal_id;
  rj := pf_private.post_journal(p_owner, t.id, (select effective_at from public.pf_journal where id = t.current_journal_id), 'REVERSAL', lines, t.current_journal_id);
  update public.pf_tx set status = 'VOID', version = version + 1, updated_at = now() where id = t.id returning version into t.version;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe) values (p_owner, 'owner', 'TX_REVERSE', t.id, jsonb_build_object('reason', left(reason, 200)));
  seq := pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
  return jsonb_build_object('tx_id', t.id, 'reversal_journal_id', rj, 'change_seq', seq);
end $$;

-- ---------------------------------------------------------------- savings goals (virtual reservations, ledger untouched)
create function pf_private.goal_allocated(p_goal uuid) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(sum(signed_amount::numeric), 0) from public.pf_allocation where goal_id = p_goal
$$;

create function pf_private.cmd_goal_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare gid uuid := gen_random_uuid(); nm text := btrim(coalesce(p->>'name', ''));
begin
  if length(nm) = 0 or length(nm) > 120 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_goal(id, owner_id, name, target, due_date) values (gid, p_owner, nm, pf_private.parse_money(p->>'target'), nullif(p->>'due_date', '')::date);
  return jsonb_build_object('goal_id', gid, 'change_seq', pf_private.touch_change(p_owner, 'goal', gid, 1));
end $$;

create function pf_private.cmd_goal_move(p_owner uuid, p jsonb, p_sign integer) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare g public.pf_goal; acc public.pf_account; amt bigint := pf_private.parse_money(p->>'amount'); bal numeric; reserved numeric; mine numeric; total numeric; st text;
begin
  acc := pf_private.require_liquid_account(p_owner, (p->>'account_id')::uuid);        -- lock order: account, then goal
  if not acc.baseline_known then perform pf_private.err('BASELINE_UNKNOWN'); end if;
  select * into g from public.pf_goal where id = (p->>'goal_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if g.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if g.state = 'ARCHIVED' then perform pf_private.err('INVALID_STATE'); end if;
  if p_sign > 0 then
    bal := pf_private.ledger_total(acc.ledger_account_id);
    select coalesce(sum(signed_amount::numeric), 0) into reserved from public.pf_allocation where account_id = acc.id;
    if amt > bal - reserved then perform pf_private.err('INSUFFICIENT_AVAILABLE'); end if;
  else
    select coalesce(sum(signed_amount::numeric), 0) into mine from public.pf_allocation where goal_id = g.id and account_id = acc.id;
    if amt > mine then perform pf_private.err('INSUFFICIENT_PRINCIPAL'); end if;
  end if;
  insert into public.pf_allocation(goal_id, account_id, signed_amount, reason) values (g.id, acc.id, p_sign * amt, case when p_sign > 0 then 'ALLOCATE' else 'RELEASE' end);
  total := pf_private.goal_allocated(g.id);
  st := case when total >= g.target then 'COMPLETED' else 'ACTIVE' end;
  update public.pf_goal set state = st, version = version + 1 where id = g.id returning version into g.version;
  return jsonb_build_object('goal_id', g.id, 'allocated', total::text, 'state', st, 'change_seq', pf_private.touch_change(p_owner, 'goal', g.id, g.version));
end $$;

create function pf_private.cmd_goal_allocate(p_owner uuid, p jsonb) returns jsonb
language sql set search_path = pg_catalog, public as $$ select pf_private.cmd_goal_move(p_owner, p, 1) $$;
create function pf_private.cmd_goal_release(p_owner uuid, p jsonb) returns jsonb
language sql set search_path = pg_catalog, public as $$ select pf_private.cmd_goal_move(p_owner, p, -1) $$;

-- ---------------------------------------------------------------- budgets
create function pf_private.cmd_budget_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare m date; cat uuid := nullif(p->>'category_id', '')::uuid; b public.pf_budget; lim bigint := pf_private.parse_money(p->>'limit'); seq bigint;
begin
  if (p->>'month') !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform pf_private.err('VALIDATION_FAILED'); end if;
  m := ((p->>'month') || '-01')::date;
  if cat is not null then
    perform 1 from public.pf_category where id = cat and owner_id = p_owner and type = 'EXPENSE' and not archived;
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
  end if;
  select * into b from public.pf_budget where owner_id = p_owner and month = m and category_id is not distinct from cat for update;
  if found then
    if not (p ? 'expected_version') or b.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
    update public.pf_budget set limit_amount = lim, carryover = (p->>'carryover')::boolean, version = version + 1 where id = b.id returning * into b;
  else
    insert into public.pf_budget(owner_id, month, category_id, limit_amount, carryover) values (p_owner, m, cat, lim, (p->>'carryover')::boolean) returning * into b;
  end if;
  seq := pf_private.touch_change(p_owner, 'budget', b.id, b.version);
  return jsonb_build_object('budget_id', b.id, 'change_seq', seq);
end $$;

-- ---------------------------------------------------------------- categories
create function pf_private.cmd_category_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare c public.pf_category; cid uuid; lid uuid; typ text := p->>'type'; par uuid := nullif(p->>'parent_id', '')::uuid; nm text := btrim(coalesce(p->>'name', ''));
        cur uuid; depth integer := 0;
begin
  if typ not in ('INCOME', 'EXPENSE') or length(nm) = 0 or length(nm) > 80 then perform pf_private.err('VALIDATION_FAILED'); end if;
  if par is not null then
    perform 1 from public.pf_category where id = par and owner_id = p_owner and type = typ;
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
  end if;
  if p ? 'category_id' then
    select * into c from public.pf_category where id = (p->>'category_id')::uuid and owner_id = p_owner for update;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
    if c.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
    if c.type <> typ then perform pf_private.err('CATEGORY_MISMATCH'); end if;  -- class never changes after use
    cur := par;                                                                   -- cycle check up the parent chain
    while cur is not null loop
      if cur = c.id or depth > 10 then perform pf_private.err('VALIDATION_FAILED'); end if;
      select parent_id into cur from public.pf_category where id = cur; depth := depth + 1;
    end loop;
    update public.pf_category set name = nm, parent_id = par, icon = coalesce(p->>'icon', icon), archived = coalesce((p->>'archived')::boolean, archived), version = version + 1
     where id = c.id returning * into c;
    update public.pf_ledger_account set name = nm where id = c.ledger_account_id;
    cid := c.id;
  else
    cid := gen_random_uuid(); lid := gen_random_uuid();
    insert into public.pf_ledger_account(id, owner_id, code, class, name) values (lid, p_owner, 'CAT_' || cid, typ::public.pf_ledger_class, nm);
    insert into public.pf_category(id, owner_id, parent_id, type, name, ledger_account_id, icon) values (cid, p_owner, par, typ, nm, lid, p->>'icon');
    c.version := 1;
  end if;
  return jsonb_build_object('category_id', cid, 'change_seq', pf_private.touch_change(p_owner, 'category', cid, c.version));
end $$;

-- ---------------------------------------------------------------- recurring templates (never auto-post; occurrences matched once)
create function pf_private.cmd_recurring_upsert(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare r public.pf_recurring; rid uuid; k text := p->>'kind'; amt bigint := pf_private.parse_money(p->>'amount'); tpl jsonb := '{}'::jsonb;
begin
  if k not in ('INCOME', 'EXPENSE', 'TRANSFER') or p->>'interval' not in ('WEEKLY', 'MONTHLY', 'YEARLY') then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform 1 from public.pf_account where id = (p->>'account_id')::uuid and owner_id = p_owner and not archived;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if k in ('INCOME', 'EXPENSE') then
    perform 1 from public.pf_category where id = nullif(p->>'category_id', '')::uuid and owner_id = p_owner and type = k and not archived;
    if not found then perform pf_private.err('CATEGORY_MISMATCH'); end if;
    tpl := jsonb_build_object('category_id', p->>'category_id');
  else
    perform 1 from public.pf_account where id = nullif(p->>'to_account_id', '')::uuid and owner_id = p_owner and not archived and id <> (p->>'account_id')::uuid;
    if not found then perform pf_private.err('VALIDATION_FAILED'); end if;
    tpl := jsonb_build_object('to_account_id', p->>'to_account_id');
  end if;
  if p ? 'recurring_id' then
    select * into r from public.pf_recurring where id = (p->>'recurring_id')::uuid and owner_id = p_owner for update;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
    if r.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
    update public.pf_recurring set name = left(p->>'name', 120), kind = k, account_id = (p->>'account_id')::uuid, amount = amt, interval = p->>'interval',
           next_date = (p->>'next_date')::date, template = tpl, enabled = (p->>'enabled')::boolean, version = version + 1
     where id = r.id returning * into r;
    rid := r.id;
  else
    insert into public.pf_recurring(owner_id, name, kind, account_id, amount, interval, next_date, template, enabled)
      values (p_owner, left(p->>'name', 120), k, (p->>'account_id')::uuid, amt, p->>'interval', (p->>'next_date')::date, tpl, (p->>'enabled')::boolean)
      returning * into r;
    rid := r.id;
  end if;
  return jsonb_build_object('recurring_id', rid, 'change_seq', pf_private.touch_change(p_owner, 'recurring', rid, r.version));
end $$;

create function pf_private.cmd_occurrence_match(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare o public.pf_occurrence;
begin
  select oc.* into o from public.pf_occurrence oc join public.pf_recurring r on r.id = oc.recurring_id
   where oc.id = (p->>'occurrence_id')::uuid and r.owner_id = p_owner for update of oc;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if o.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if o.state <> 'EXPECTED' then perform pf_private.err('INVALID_STATE'); end if;
  perform 1 from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner and status = 'POSTED';
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  update public.pf_occurrence set state = 'MATCHED', matched_tx_id = (p->>'tx_id')::uuid, version = version + 1 where id = o.id returning * into o;
  return jsonb_build_object('occurrence_id', o.id, 'change_seq', pf_private.touch_change(p_owner, 'occurrence', o.id, o.version));
end $$;

-- ---------------------------------------------------------------- dispatcher (extends migration 002)
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
    when 'TX_CREATE'        then pf_private.cmd_tx_create(p_owner, payload)
    when 'TX_REVERSE'       then pf_private.cmd_tx_reverse(p_owner, payload)
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

-- ---------------------------------------------------------------- read models
create function public.pf_read_contacts(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'alias', alias, 'note', note, 'version', version) order by alias)
    from public.pf_contact where owner_id = p_owner and not archived), '[]'::jsonb);
end $$;

create function public.pf_read_debts(p_owner uuid, p_today date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.overdue desc, x.due_date nulls last, x.originated_at) from (
    select d.id, d.direction, d.contact_id, c.alias as contact_alias, d.principal::text as principal,
           pf_private.debt_remaining(d.id)::text as remaining, d.state, d.due_date, d.originated_at, d.note, d.version,
           (d.state in ('OPEN', 'PARTIAL') and d.due_date is not null and d.due_date < p_today) as overdue
      from public.pf_debt d join public.pf_contact c on c.id = d.contact_id where d.owner_id = p_owner) x), '[]'::jsonb);
end $$;

create function public.pf_read_goals(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return jsonb_build_object(
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'target', g.target::text, 'allocated', pf_private.goal_allocated(g.id)::text,
                'state', g.state, 'due_date', g.due_date, 'version', g.version) order by g.name) from public.pf_goal g where g.owner_id = p_owner and g.state <> 'ARCHIVED'), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_id', a.id, 'name', a.name,
                'available', (pf_private.ledger_total(a.ledger_account_id) - coalesce((select sum(signed_amount::numeric) from public.pf_allocation al where al.account_id = a.id), 0))::text) order by a.created_at)
                from public.pf_account a join public.pf_ledger_account la on la.id = a.ledger_account_id
               where a.owner_id = p_owner and not a.archived and a.baseline_known and la.class = 'ASSET'), '[]'::jsonb));
end $$;

-- Month is a local (Asia/Ho_Chi_Minh) calendar month; spent = net expense of the category and its direct children.
-- Carryover (deterministic): previous month's unused budget (limit - spent, floored at 0), without chaining.
create function public.pf_read_budgets(p_owner uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare m date := date_trunc('month', p_month)::date;
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'category_id', x.category_id, 'category_name', x.category_name, 'icon', x.icon,
        'limit_amount', x.limit_amount::text, 'carryover', x.carryover, 'version', x.version, 'spent', x.spent::text, 'carried', x.carried::text,
        'remaining', (x.limit_amount::numeric + x.carried - x.spent)::text) order by x.category_name)
    from (
      select b.id, b.category_id, coalesce(c.name, 'Tổng chi tiêu') as category_name, c.icon, b.limit_amount, b.carryover, b.version,
             pf_private.budget_spent(p_owner, b.category_id, m) as spent,
             case when b.carryover then greatest(coalesce((select pb.limit_amount::numeric from public.pf_budget pb
                  where pb.owner_id = p_owner and pb.month = (m - interval '1 month')::date and pb.category_id is not distinct from b.category_id), 0)
                  - pf_private.budget_spent(p_owner, b.category_id, (m - interval '1 month')::date), 0) else 0 end as carried
        from public.pf_budget b left join public.pf_category c on c.id = b.category_id where b.owner_id = p_owner and b.month = m) x), '[]'::jsonb);
end $$;

create function pf_private.budget_spent(p_owner uuid, p_category uuid, p_month date) returns numeric
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(sum(e.signed_amount::numeric), 0)
    from public.pf_entry e
    join public.pf_journal j on j.id = e.journal_id and j.posted
    join public.pf_ledger_account a on a.id = e.ledger_account_id and a.class = 'EXPENSE'
   where j.owner_id = p_owner
     and j.effective_at >= (p_month::timestamp at time zone 'Asia/Ho_Chi_Minh')
     and j.effective_at <  ((p_month + interval '1 month')::timestamp at time zone 'Asia/Ho_Chi_Minh')
     and a.code not in ('SYS_ADJUSTMENT_OUT')
     and (p_category is null
          or a.id in (select c.ledger_account_id from public.pf_category c where c.owner_id = p_owner and (c.id = p_category or c.parent_id = p_category)))
$$;

create function public.pf_sync_occurrences(p_owner uuid, p_today date) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.pf_recurring; n integer; due date; made integer := 0; horizon date := p_today + 14;
begin
  perform pf_private.assert_owner(p_owner);
  for r in select * from public.pf_recurring where owner_id = p_owner and enabled loop
    for n in 0..23 loop
      due := (r.next_date + (n * case r.interval when 'WEEKLY' then interval '1 week' when 'MONTHLY' then interval '1 month' else interval '1 year' end))::date;
      exit when due > horizon;
      insert into public.pf_occurrence(recurring_id, due_date) values (r.id, due) on conflict do nothing;
      if found then made := made + 1; end if;
    end loop;
  end loop;
  return made;
end $$;

create function public.pf_read_recurring(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'kind', r.kind, 'account_id', r.account_id, 'amount', r.amount::text,
      'interval', r.interval, 'next_date', r.next_date, 'enabled', r.enabled, 'template', r.template, 'version', r.version,
      'expected', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'due_date', o.due_date, 'version', o.version) order by o.due_date)
                              from public.pf_occurrence o where o.recurring_id = r.id and o.state = 'EXPECTED'), '[]'::jsonb)) order by r.name)
    from public.pf_recurring r where r.owner_id = p_owner), '[]'::jsonb);
end $$;

-- Corrected dashboard: only SYS_ADJUSTMENT_* is excluded from classified income/expense.
create or replace function public.pf_read_dashboard(p_owner uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare income numeric; expense numeric; assets numeric; liabilities numeric; unknown_n integer; by_cat jsonb; receivable numeric; payable numeric;
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(-sum(e.signed_amount::numeric) filter (where a.class = 'INCOME'), 0),
         coalesce(sum(e.signed_amount::numeric) filter (where a.class = 'EXPENSE'), 0)
    into income, expense
    from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
    join public.pf_ledger_account a on a.id = e.ledger_account_id
   where j.owner_id = p_owner and j.effective_at >= p_from and j.effective_at < p_to and a.code not in ('SYS_ADJUSTMENT_IN', 'SYS_ADJUSTMENT_OUT');
  select coalesce(sum(b.debit_net) filter (where b.class = 'ASSET'), 0), coalesce(-sum(b.debit_net) filter (where b.class = 'LIABILITY'), 0)
    into assets, liabilities
    from public.pf_account a join pf_private.ledger_balance b on b.id = a.ledger_account_id
   where a.owner_id = p_owner and a.baseline_known and not a.archived;
  select coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'RECEIVABLE'), 0),
         coalesce(sum(pf_private.debt_remaining(d.id)) filter (where d.direction = 'PAYABLE'), 0)
    into receivable, payable from public.pf_debt d where d.owner_id = p_owner and d.state in ('OPEN', 'PARTIAL');
  select count(*) into unknown_n from public.pf_account where owner_id = p_owner and not baseline_known and not archived;
  select coalesce(jsonb_agg(jsonb_build_object('category_id', c.id, 'name', c.name, 'icon', c.icon, 'amount', s.total::text) order by s.total desc), '[]'::jsonb) into by_cat
    from (select a.id as lid, sum(e.signed_amount::numeric) as total
            from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
            join public.pf_ledger_account a on a.id = e.ledger_account_id and a.class = 'EXPENSE' and a.code like 'CAT\_%' escape '\'
           where j.owner_id = p_owner and j.effective_at >= p_from and j.effective_at < p_to group by a.id having sum(e.signed_amount::numeric) <> 0) s
    join public.pf_category c on c.ledger_account_id = s.lid;
  -- Net worth = known assets + receivables - liabilities - payables (docs/03 section 7); goals/reservations excluded.
  return jsonb_build_object('income', income::text, 'expense', expense::text, 'net_worth', (assets - liabilities + receivable - payable)::text,
    'receivable', receivable::text, 'payable', payable::text, 'accounts_unknown_baseline', unknown_n, 'expense_by_category', by_cat);
end $$;

-- ---------------------------------------------------------------- grants: server role only
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on all functions in schema pf_private from public, anon, authenticated, service_role;

commit;

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
