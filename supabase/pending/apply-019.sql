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
