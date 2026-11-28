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
