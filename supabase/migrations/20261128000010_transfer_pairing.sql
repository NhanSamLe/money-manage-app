-- MoMa migration 010: money moved between the owner's own accounts becomes ONE transfer, not an expense + an income.
-- A money-out leg and a money-in leg pair when: different accounts of the owner, exact same amount, effective times
-- within 15 minutes, at least one leg from BANK or NOTIFICATION, neither leg debt / recurring linked, already paired
-- or previously rejected for the same two transactions.
-- The same bank reference on both legs (e.g. FT26332327719412) is certain: AUTO even up to 24 hours apart.
-- Unique and strong (both legs have exactly one counterpart; time <= 5 min, or <= 15 min with a content hint) ->
-- AUTO: both legs are reversed (history kept) and one TRANSFER is posted through the normal ledger code.
-- Several candidates or a weak match -> SUGGESTED: the ledger is unchanged until the owner accepts.
-- Content hints: wallet / transfer words, the owner's name, the other account's bank name or last 4 digits.
-- One leg only (the other side never notifies, e.g. MoMo sends no money-out notification): a money-in whose content
-- names the owner and exactly one other own account ("LE DAO NHAN SAM chuyen tien qua MoMo"), or a money-out naming
-- exactly one own wallet ("MOMO 0909...", "nap tien vi MoMo") or the owner + one own account, with no counterpart
-- after the 15-minute window -> the reconciliation sweep books a TRANSFER from / to that account (AUTO, the missing
-- side is synthesized: out_tx or in_tx null, synth_account set). If the missing leg arrives later it is absorbed
-- into that transfer instead of being counted twice.
-- Every money movement uses pf_private.cmd_tx_reverse / cmd_tx_create, so journal invariants are unchanged.
-- Server role only.
begin;

create table public.pf_transfer_pair (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  out_tx uuid references public.pf_tx(id),   -- null: money-out side synthesized (never notified)
  in_tx uuid references public.pf_tx(id),    -- null: money-in side synthesized
  synth_account uuid references public.pf_account(id), -- the own account of a synthesized side
  transfer_tx uuid references public.pf_tx(id),
  state text not null check (state in ('AUTO', 'CONFIRMED', 'REJECTED', 'SUGGESTED')),
  score integer not null default 0,
  hints text[] not null default '{}',
  -- after an undo: the re-created legs (they never pair with each other again)
  restored_out uuid references public.pf_tx(id),
  restored_in uuid references public.pf_tx(id),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  unique (out_tx, in_tx),
  check (out_tx <> in_tx),
  check ((out_tx is not null and in_tx is not null) or synth_account is not null),
  check (state not in ('AUTO', 'CONFIRMED') or transfer_tx is not null)
);
create index pf_transfer_pair_owner_idx on public.pf_transfer_pair(owner_id, state, created_at desc);
create index pf_transfer_pair_in_idx on public.pf_transfer_pair(in_tx);
create index pf_transfer_pair_synth_idx on public.pf_transfer_pair(synth_account) where synth_account is not null;
create unique index pf_transfer_pair_transfer_uq on public.pf_transfer_pair(transfer_tx) where transfer_tx is not null;
alter table public.pf_transfer_pair enable row level security;
revoke all on table public.pf_transfer_pair from public, anon, authenticated;
grant select on table public.pf_transfer_pair to service_role;
revoke insert, update, delete, truncate on table public.pf_transfer_pair from service_role;

-- ---------------------------------------------------------------- matching
-- A transaction that may be one leg of a transfer.
create function pf_private.transfer_leg_ok(t public.pf_tx) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select t.status = 'POSTED'
     and t.kind in ('EXPENSE', 'UNKNOWN_DEBIT', 'INCOME', 'UNKNOWN_CREDIT')
     and t.source in ('BANK', 'NOTIFICATION', 'MANUAL', 'AI', 'IMPORT')
     and t.account_id is not null and t.amount is not null
     and not exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id)
     and not exists (select 1 from public.pf_debt_payment p where p.tx_id = t.id)
     and not exists (select 1 from public.pf_occurrence o where o.matched_tx_id = t.id)
     and exists (select 1 from public.pf_account a where a.id = t.account_id and not a.archived)
$$;

-- The owner said "no" for these two transactions (or split them back after an automatic pairing).
create function pf_private.transfer_rejected(a uuid, b uuid) returns boolean
language sql stable set search_path = pg_catalog, public as $$
  select exists (select 1 from public.pf_transfer_pair p where p.state = 'REJECTED'
    and ((p.out_tx = a and p.in_tx = b) or (p.out_tx = b and p.in_tx = a)
      or (p.restored_out = a and p.restored_in = b) or (p.restored_out = b and p.restored_in = a)))
$$;

-- Does normalised text (padded with spaces) name this account: institution, account name, linked bank or last 4?
create function pf_private.transfer_mentions(p_text text, p_account uuid) returns boolean
language plpgsql stable set search_path = pg_catalog, public as $$
declare a public.pf_account; w text; l4 text;
begin
  select * into a from public.pf_account where id = p_account;
  if not found or p_text is null then return false; end if;
  for w in select pf_private.ai_norm(x) from unnest(array[a.institution, a.name,
             (select bank_name from public.pf_account_link where account_id = a.id)]) x loop
    if length(w) >= 3 and w not in ('ngan hang', 'tai khoan', 'the', 'khac', 'vi dien tu')
       and position(' ' || w || ' ' in p_text) > 0 then
      return true;
    end if;
  end loop;
  foreach l4 in array array[a.last4, (select last4 from public.pf_account_link where account_id = a.id)] loop
    if l4 ~ '^[0-9]{4}$' and p_text ~ ('[ 0-9]' || l4 || ' ') then return true; end if;
  end loop;
  return false;
end $$;

-- Content hints that both legs are the same money moving: wallet / transfer words, the owner's own name, the other
-- account named in a leg (out content names the receiving account or in content names the sending one).
create function pf_private.transfer_hints(p_owner uuid, p_out uuid, p_in uuid) returns text[]
language plpgsql stable set search_path = pg_catalog, public as $$
declare o public.pf_tx; i public.pf_tx; t_out text; t_in text; t_all text; nm text; k text; h text[] := '{}';
begin
  select * into o from public.pf_tx where id = p_out and owner_id = p_owner;
  select * into i from public.pf_tx where id = p_in and owner_id = p_owner;
  if o.id is null or i.id is null then return h; end if;
  t_out := ' ' || pf_private.ai_norm(concat_ws(' ', o.note, o.merchant)) || ' ';
  t_in := ' ' || pf_private.ai_norm(concat_ws(' ', i.note, i.merchant)) || ' ';
  t_all := t_out || t_in;
  foreach k in array array['momo', 'nap vi', 'zalopay', 'zalo pay', 'chuyen tien', 'nap tien', 'rut tien', 'shopeepay',
                           'vnpay', 'viettel money', 'chuyen khoan noi bo'] loop
    if position(' ' || k || ' ' in t_all) > 0 then h := array_append(h, 'keyword'); exit; end if;
  end loop;
  select pf_private.ai_norm(display_name) into nm from public.pf_owner where user_id = p_owner;
  if length(coalesce(nm, '')) >= 5 and position(' ' || nm || ' ' in t_all) > 0 then h := array_append(h, 'owner_name'); end if;
  if pf_private.transfer_mentions(t_out, i.account_id) or pf_private.transfer_mentions(t_in, o.account_id) then
    h := array_append(h, 'account');
  end if;
  return h;
end $$;

-- 0..100: closeness in time (<= 2 min: 50, <= 5 min: 40, <= 15 min: 10) + 25 per kind of hint (max 50).
create function pf_private.transfer_score(p_seconds numeric, p_hints text[]) returns integer
language sql immutable set search_path = pg_catalog as $$
  select (case when p_seconds <= 120 then 50 when p_seconds <= 300 then 40 else 10 end)
       + least(50, 25 * coalesce(cardinality(p_hints), 0))
$$;

-- Automatic pairing needs at least this score: <= 5 minutes apart, or <= 15 minutes with a content hint.
create function pf_private.transfer_auto_min() returns integer language sql immutable as $$ select 35 $$;

-- Bank reference codes in a leg: tokens of its note / merchant and of the SePay reference stored with its bank event.
-- A reference is "FT" + 6 or more digits, or any 10+ character letters-and-digits token that contains a digit
-- (e.g. MoMo: "LE DAO NHAN SAM chuyen FT26332327719412", SePay referenceCode "FT26332327719412").
create function pf_private.transfer_refs(p_tx uuid) returns text[]
language sql stable set search_path = pg_catalog, public as $$
  select coalesce(array_agg(distinct m[1]), '{}')
    from public.pf_tx t
    cross join lateral regexp_matches(upper(concat_ws(' ', t.note, t.merchant,
        (select string_agg(e.payload->>'reference', ' ') from public.pf_inbound_event e where e.tx_id = t.id))),
        '([A-Z0-9]{8,})', 'g') m
   where t.id = p_tx and (m[1] ~ '^FT[0-9]{6,}$' or (length(m[1]) >= 10 and m[1] ~ '[0-9]'))
$$;

-- Opposite-direction legs that could be the other half of p_tx: within 15 minutes, or within 24 hours when both legs
-- carry the same bank reference (c_ref: a certain match, score 100).
create function pf_private.transfer_candidates(p_owner uuid, p_tx uuid)
returns table (c_tx uuid, c_out uuid, c_in uuid, c_seconds numeric, c_hints text[], c_score integer, c_ref boolean)
language plpgsql stable set search_path = pg_catalog, public as $$
declare x public.pf_tx; x_out boolean; x_refs text[];
begin
  select * into x from public.pf_tx t where t.id = p_tx and t.owner_id = p_owner;
  if not found or not pf_private.transfer_leg_ok(x) then return; end if;
  x_out := x.kind in ('EXPENSE', 'UNKNOWN_DEBIT');
  x_refs := pf_private.transfer_refs(x.id);
  return query
    with m as materialized ( -- filter first; hints are computed for the few rows left
      select y.id, abs(extract(epoch from (y.effective_at - x.effective_at)))::numeric as secs
        from public.pf_tx y
       where y.owner_id = p_owner and y.id <> x.id and y.status = 'POSTED'
         and y.effective_at between x.effective_at - interval '24 hours' and x.effective_at + interval '24 hours'
         and ((x_out and y.kind in ('INCOME', 'UNKNOWN_CREDIT')) or (not x_out and y.kind in ('EXPENSE', 'UNKNOWN_DEBIT')))
         and y.account_id <> x.account_id
         and y.amount = x.amount
         and (x.source in ('BANK', 'NOTIFICATION') or y.source in ('BANK', 'NOTIFICATION'))
         and pf_private.transfer_leg_ok(y)
         and not pf_private.transfer_rejected(x.id, y.id)
         and not exists (select 1 from public.pf_transfer_pair p where p.state in ('AUTO', 'CONFIRMED')
                           and (p.out_tx in (x.id, y.id) or p.in_tx in (x.id, y.id)))),
    r as (
      select m.id, m.secs, (cardinality(x_refs) > 0 and x_refs && pf_private.transfer_refs(m.id)) as ref from m),
    hm as (
      select r.id, r.secs, r.ref,
             pf_private.transfer_hints(p_owner, case when x_out then x.id else r.id end, case when x_out then r.id else x.id end)
               || case when r.ref then array['reference'] else array[]::text[] end as hints
        from r where r.ref or r.secs <= 900)
    select hm.id, case when x_out then x.id else hm.id end, case when x_out then hm.id else x.id end,
           hm.secs, hm.hints, case when hm.ref then 100 else pf_private.transfer_score(hm.secs, hm.hints) end, hm.ref
      from hm;
end $$;

-- ---------------------------------------------------------------- ledger moves
-- Reverses both legs and posts one TRANSFER out-account -> in-account at the earlier time. Returns the new tx id.
create function pf_private.transfer_convert(p_owner uuid, p_out uuid, p_in uuid) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare o public.pf_tx; i public.pf_tx; res jsonb; note text; reason constant text := 'Ghép thành chuyển tiền giữa tài khoản của bạn';
begin
  perform 1 from public.pf_tx where id in (p_out, p_in) and owner_id = p_owner order by id for update;
  select * into o from public.pf_tx where id = p_out and owner_id = p_owner;
  select * into i from public.pf_tx where id = p_in and owner_id = p_owner;
  if o.id is null or i.id is null then perform pf_private.err('NOT_FOUND'); end if;
  if not pf_private.transfer_leg_ok(o) or not pf_private.transfer_leg_ok(i) or o.kind not in ('EXPENSE', 'UNKNOWN_DEBIT')
     or i.kind not in ('INCOME', 'UNKNOWN_CREDIT') or o.amount <> i.amount or o.account_id = i.account_id then
    perform pf_private.err('INVALID_STATE');
  end if;
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', o.id, 'reason', reason, 'expected_version', o.version));
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', i.id, 'reason', reason, 'expected_version', i.version));
  note := nullif(btrim(case
            when coalesce(btrim(o.note), '') = '' then coalesce(i.note, '')
            when coalesce(btrim(i.note), '') = '' or btrim(i.note) = btrim(o.note) then o.note
            else o.note || ' / ' || i.note end), '');
  res := pf_private.cmd_tx_create(p_owner, jsonb_build_object(
    'kind', 'TRANSFER', 'account_id', o.account_id, 'to_account_id', i.account_id, 'amount', o.amount::text,
    'effective_at', least(o.effective_at, i.effective_at), 'note', left(note, 1000)));
  update public.pf_tx set source = o.source where id = (res->>'tx_id')::uuid;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'system', 'TRANSFER_PAIR', (res->>'tx_id')::uuid, jsonb_build_object('out_tx', o.id, 'in_tx', i.id));
  return (res->>'tx_id')::uuid;
end $$;

-- Re-creates one original leg (same kind, account, amount, time, category, texts, source). A category archived since
-- then makes it unclassified money in/out instead of failing.
create function pf_private.transfer_restore(p_owner uuid, t public.pf_tx) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare k text := t.kind::text; cat uuid := t.category_id; res jsonb;
begin
  if k in ('INCOME', 'EXPENSE') and not exists (select 1 from public.pf_category c
       where c.id = cat and c.owner_id = p_owner and not c.archived and c.type = k) then
    k := case when k = 'INCOME' then 'UNKNOWN_CREDIT' else 'UNKNOWN_DEBIT' end;
  end if;
  if k not in ('INCOME', 'EXPENSE') then cat := null; end if;
  res := pf_private.cmd_tx_create(p_owner, jsonb_strip_nulls(jsonb_build_object(
    'kind', k, 'account_id', t.account_id, 'amount', t.amount::text, 'effective_at', t.effective_at, 'category_id', cat,
    'note', t.note, 'merchant', nullif(t.merchant, ''), 'contact_id', t.contact_id)));
  update public.pf_tx set source = t.source where id = (res->>'tx_id')::uuid;
  return (res->>'tx_id')::uuid;
end $$;

-- The other own account a lone leg names, or null. Money-in: the owner's name + exactly one other own account.
-- Money-out: exactly one other own account that is a wallet, or the owner's name + exactly one other own account.
create function pf_private.transfer_own_counterpart(p_owner uuid, x public.pf_tx) returns uuid
language plpgsql stable set search_path = pg_catalog, public as $$
declare t text; nm text; named boolean; a record; acc uuid; wallet boolean := false; n integer := 0;
begin
  t := ' ' || pf_private.ai_norm(concat_ws(' ', x.note, x.merchant)) || ' ';
  select pf_private.ai_norm(display_name) into nm from public.pf_owner where user_id = p_owner;
  named := length(coalesce(nm, '')) >= 5 and position(' ' || nm || ' ' in t) > 0;
  for a in select id, kind from public.pf_account where owner_id = p_owner and not archived and id <> x.account_id loop
    if pf_private.transfer_mentions(t, a.id) then
      n := n + 1; acc := a.id; wallet := a.kind = 'WALLET';
    end if;
  end loop;
  if n <> 1 then return null; end if;
  if x.kind in ('INCOME', 'UNKNOWN_CREDIT') then return case when named then acc end; end if;
  return case when named or wallet then acc end;
end $$;

-- Books one lone leg as a transfer with the named own account on the other side. Returns the new tx id.
create function pf_private.transfer_convert_single(p_owner uuid, p_leg uuid, p_other uuid) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare x public.pf_tx; res jsonb; x_in boolean;
begin
  select * into x from public.pf_tx where id = p_leg and owner_id = p_owner for update;
  if not found or not pf_private.transfer_leg_ok(x) or x.account_id = p_other then perform pf_private.err('INVALID_STATE'); end if;
  x_in := x.kind in ('INCOME', 'UNKNOWN_CREDIT');
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', x.id, 'reason', 'Ghép thành chuyển tiền giữa tài khoản của bạn', 'expected_version', x.version));
  res := pf_private.cmd_tx_create(p_owner, jsonb_build_object(
    'kind', 'TRANSFER', 'account_id', case when x_in then p_other else x.account_id end,
    'to_account_id', case when x_in then x.account_id else p_other end, 'amount', x.amount::text,
    'effective_at', x.effective_at, 'note', left(nullif(btrim(coalesce(x.note, '')), ''), 1000)));
  update public.pf_tx set source = x.source where id = (res->>'tx_id')::uuid;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'system', 'TRANSFER_PAIR', (res->>'tx_id')::uuid,
            jsonb_build_object(case when x_in then 'in_tx' else 'out_tx' end, x.id, 'synth_account', p_other));
  return (res->>'tx_id')::uuid;
end $$;

-- A late leg for the synthesized side of a one-leg transfer: reversed and attached to that pair (never counted twice).
-- Same account, same direction, same amount, within 15 minutes of the transfer or sharing its bank reference.
create function pf_private.transfer_absorb(p_owner uuid, x public.pf_tx) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare x_in boolean := x.kind in ('INCOME', 'UNKNOWN_CREDIT'); x_refs text[]; n integer; pid uuid; tid uuid; nt text; v integer;
begin
  if not pf_private.transfer_leg_ok(x) then return null; end if;
  x_refs := pf_private.transfer_refs(x.id);
  select count(*), min(p.id::text)::uuid, min(t.id::text)::uuid into n, pid, tid
    from public.pf_transfer_pair p join public.pf_tx t on t.id = p.transfer_tx
   where p.owner_id = p_owner and p.state in ('AUTO', 'CONFIRMED') and p.synth_account = x.account_id and t.status = 'POSTED'
     and t.amount = x.amount
     and ((x_in and p.in_tx is null and t.to_account_id = x.account_id) or (not x_in and p.out_tx is null and t.account_id = x.account_id))
     and (abs(extract(epoch from (t.effective_at - x.effective_at))) <= 900
          or (cardinality(x_refs) > 0 and x_refs && pf_private.transfer_refs(t.id)));
  if n <> 1 then return null; end if;
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', x.id, 'reason', 'Đã gộp vào chuyển tiền giữa tài khoản của bạn', 'expected_version', x.version));
  if x_in then update public.pf_transfer_pair set in_tx = x.id where id = pid;
  else update public.pf_transfer_pair set out_tx = x.id where id = pid; end if;
  -- the transfer note gains the late leg's text (descriptive projection only; amounts and journal unchanged)
  select note into nt from public.pf_tx where id = tid;
  if coalesce(btrim(x.note), '') <> '' and position(btrim(x.note) in coalesce(nt, '')) = 0 then
    update public.pf_tx set note = left(concat_ws(' / ', nullif(nt, ''), btrim(x.note)), 1000), version = version + 1, updated_at = now()
     where id = tid returning version into v;
    perform pf_private.touch_change(p_owner, 'transaction', tid, v);
  end if;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'system', 'TRANSFER_PAIR_ABSORB', tid, jsonb_build_object('tx', x.id, 'pair', pid));
  return pid;
end $$;

-- ---------------------------------------------------------------- pairing
-- Best effort entry point after a money-in/out transaction is created. Serialised per owner.
-- Returns {status: NONE | AUTO | SUGGESTED, pair_id?, transfer_tx_id?, suggested?}.
create function pf_private.try_pair_transfer(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare n integer; back integer; best record; c record; pid uuid; tid uuid; k integer := 0; certain boolean := false; x public.pf_tx;
begin
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into x from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found then return jsonb_build_object('status', 'NONE'); end if;
  -- the missing side of a one-leg transfer arrived late
  pid := pf_private.transfer_absorb(p_owner, x);
  if pid is not null then return jsonb_build_object('status', 'ABSORBED', 'pair_id', pid); end if;
  -- the same bank reference on both legs is certain (even hours apart, or among other same-amount candidates)
  select count(*) into n from pf_private.transfer_candidates(p_owner, p_tx) where c_ref;
  if n = 1 then
    select * into best from pf_private.transfer_candidates(p_owner, p_tx) where c_ref;
    select count(*) into back from pf_private.transfer_candidates(p_owner, best.c_tx) where c_ref;
    certain := back = 1;
  end if;
  if not certain then
    select count(*) into n from pf_private.transfer_candidates(p_owner, p_tx);
    if n = 0 then return jsonb_build_object('status', 'NONE'); end if;
    if n = 1 then
      select * into best from pf_private.transfer_candidates(p_owner, p_tx);
      select count(*) into back from pf_private.transfer_candidates(p_owner, best.c_tx);
      certain := back = 1 and best.c_score >= pf_private.transfer_auto_min()
        and not exists (select 1 from public.pf_transfer_pair p where p.out_tx = best.c_out and p.in_tx = best.c_in);
    end if;
  end if;
  if certain then
    tid := pf_private.transfer_convert(p_owner, best.c_out, best.c_in);
    insert into public.pf_transfer_pair(owner_id, out_tx, in_tx, transfer_tx, state, score, hints, decided_at)
      values (p_owner, best.c_out, best.c_in, tid, 'AUTO', best.c_score, best.c_hints, now())
      on conflict (out_tx, in_tx) do update set transfer_tx = excluded.transfer_tx, state = 'AUTO', score = excluded.score,
        hints = excluded.hints, decided_at = now()
      returning id into pid;
    return jsonb_build_object('status', 'AUTO', 'pair_id', pid, 'transfer_tx_id', tid);
  end if;
  for c in select * from pf_private.transfer_candidates(p_owner, p_tx) order by c_score desc, c_seconds, c_tx limit 3 loop
    pid := null;
    insert into public.pf_transfer_pair(owner_id, out_tx, in_tx, state, score, hints)
      values (p_owner, c.c_out, c.c_in, 'SUGGESTED', c.c_score, c.c_hints)
      on conflict (out_tx, in_tx) do nothing returning id into pid;
    if pid is not null then k := k + 1; end if;
  end loop;
  return jsonb_build_object('status', case when k > 0 then 'SUGGESTED' else 'NONE' end, 'suggested', k);
end $$;

-- Sweep step for a leg still alone after the 15-minute window: book it as a transfer with the own account it names.
create function pf_private.try_single_leg(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare x public.pf_tx; other uuid; tid uuid; pid uuid; x_in boolean;
begin
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into x from public.pf_tx where id = p_tx and owner_id = p_owner;
  if not found or not pf_private.transfer_leg_ok(x) or x.source not in ('BANK', 'NOTIFICATION')
     or x.effective_at > now() - interval '15 minutes' then
    return jsonb_build_object('status', 'NONE');
  end if;
  -- never after a decision / suggestion about this transaction, nor while it still has a possible counterpart
  if exists (select 1 from public.pf_transfer_pair p where x.id in (p.out_tx, p.in_tx, p.restored_out, p.restored_in))
     or exists (select 1 from pf_private.transfer_candidates(p_owner, x.id)) then
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

create function public.pf_transfer_try_pair(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return pf_private.try_pair_transfer(p_owner, p_tx);
end $$;

-- Reconciliation: every BANK / NOTIFICATION money-in/out of the last p_hours (1..168) that is still unpaired.
-- Idempotent (pairs are unique; converted legs are VOID). One failing transaction never stops the others.
create function public.pf_transfer_sweep(p_owner uuid, p_hours integer) returns jsonb
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
create function pf_private.transfer_leg_json(t public.pf_tx) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('tx_id', t.id, 'kind', t.kind, 'status', t.status, 'amount', t.amount::text,
    'effective_at', t.effective_at, 'note', t.note, 'merchant', t.merchant, 'source', t.source,
    'account_id', a.id, 'account_name', a.name, 'institution', a.institution, 'account_kind', a.kind, 'last4', a.last4)
  from public.pf_account a where a.id = t.account_id
$$;

create function public.pf_transfer_suggestions(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(x.j order by x.at desc, x.id) from (
      select p.id, greatest(o.effective_at, i.effective_at) as at,
             jsonb_build_object('id', p.id, 'state', p.state, 'score', p.score, 'hints', to_jsonb(p.hints), 'created_at', p.created_at,
               'out', pf_private.transfer_leg_json(o), 'in', pf_private.transfer_leg_json(i)) as j
        from public.pf_transfer_pair p
        join public.pf_tx o on o.id = p.out_tx
        join public.pf_tx i on i.id = p.in_tx
       where p.owner_id = p_owner and p.state = 'SUGGESTED' and o.status = 'POSTED' and i.status = 'POSTED'
       order by greatest(o.effective_at, i.effective_at) desc limit 50) x), '[]'::jsonb);
end $$;

-- The pair that produced a transfer transaction (null when the transfer was entered by hand).
create function public.pf_transfer_pair_for_tx(p_owner uuid, p_tx uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare p public.pf_transfer_pair; o public.pf_tx; i public.pf_tx;
begin
  perform pf_private.assert_owner(p_owner);
  select * into p from public.pf_transfer_pair where owner_id = p_owner and transfer_tx = p_tx;
  if not found then return null; end if;
  select * into o from public.pf_tx where id = p.out_tx;
  select * into i from public.pf_tx where id = p.in_tx;
  return jsonb_build_object('id', p.id, 'state', p.state, 'score', p.score, 'hints', to_jsonb(p.hints), 'transfer_tx_id', p.transfer_tx,
    'synth_account', (select jsonb_build_object('account_id', a.id, 'account_name', a.name, 'institution', a.institution, 'account_kind', a.kind)
                        from public.pf_account a where a.id = p.synth_account),
    'created_at', p.created_at, 'decided_at', p.decided_at, 'out', pf_private.transfer_leg_json(o), 'in', pf_private.transfer_leg_json(i),
    'can_undo', p.state in ('AUTO', 'CONFIRMED') and exists (select 1 from public.pf_tx t where t.id = p.transfer_tx and t.status = 'POSTED'));
end $$;

-- Accept: convert like the automatic path (CONFIRMED). Reject: REJECTED, the same two transactions are never suggested again.
create function public.pf_transfer_decide(p_owner uuid, p_pair uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p public.pf_transfer_pair; tid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if p_accept is null then perform pf_private.err('VALIDATION_FAILED'); end if;
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into p from public.pf_transfer_pair where id = p_pair and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if p.state <> 'SUGGESTED' then perform pf_private.err('INVALID_STATE'); end if;
  if not p_accept then
    update public.pf_transfer_pair set state = 'REJECTED', decided_at = now() where id = p.id;
    insert into public.pf_audit(owner_id, actor, action, target_id) values (p_owner, 'owner', 'TRANSFER_PAIR_REJECT', p.id);
    return jsonb_build_object('pair_id', p.id, 'state', 'REJECTED');
  end if;
  tid := pf_private.transfer_convert(p_owner, p.out_tx, p.in_tx); -- INVALID_STATE when a leg changed meanwhile
  update public.pf_transfer_pair set state = 'CONFIRMED', transfer_tx = tid, decided_at = now() where id = p.id;
  return jsonb_build_object('pair_id', p.id, 'state', 'CONFIRMED', 'transfer_tx_id', tid);
end $$;

-- Splits an automatic (or accepted) pairing back: reverses the transfer, re-creates both original legs, REJECTED.
create function public.pf_transfer_undo(p_owner uuid, p_pair uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p public.pf_transfer_pair; t public.pf_tx; o public.pf_tx; i public.pf_tx; ro uuid; ri uuid;
begin
  perform pf_private.assert_owner(p_owner);
  perform pg_advisory_xact_lock(hashtext('moma-transfer-pair'), hashtext(p_owner::text));
  select * into p from public.pf_transfer_pair where id = p_pair and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if p.state not in ('AUTO', 'CONFIRMED') then perform pf_private.err('INVALID_STATE'); end if;
  select * into t from public.pf_tx where id = p.transfer_tx and owner_id = p_owner for update;
  if not found or t.status <> 'POSTED' then perform pf_private.err('INVALID_STATE'); end if;
  perform pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', t.id, 'reason', 'Tách lại thành hai giao dịch', 'expected_version', t.version));
  if p.out_tx is not null then
    select * into o from public.pf_tx where id = p.out_tx;
    ro := pf_private.transfer_restore(p_owner, o);
  end if;
  if p.in_tx is not null then
    select * into i from public.pf_tx where id = p.in_tx;
    ri := pf_private.transfer_restore(p_owner, i);
  end if;
  update public.pf_transfer_pair set state = 'REJECTED', restored_out = ro, restored_in = ri, decided_at = now() where id = p.id;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe)
    values (p_owner, 'owner', 'TRANSFER_PAIR_UNDO', p.id, jsonb_build_object('transfer_tx', t.id, 'out_tx', ro, 'in_tx', ri));
  return jsonb_build_object('pair_id', p.id, 'state', 'REJECTED', 'voided_transfer_tx_id', t.id, 'out_tx_id', ro, 'in_tx_id', ri);
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
