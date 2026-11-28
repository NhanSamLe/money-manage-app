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
