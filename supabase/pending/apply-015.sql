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
