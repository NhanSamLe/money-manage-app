-- MoMa migration 009: transaction provenance (pf_tx.source) and the assistant's per-owner memory.
-- 1) Every transaction records where it came from (MANUAL, BANK, AI, NOTIFICATION, IMPORT, RECURRING, SYSTEM).
--    Clients may only send MANUAL/AI/NOTIFICATION/IMPORT on TX_CREATE; BANK, RECURRING and SYSTEM are set by the
--    server paths. Edits keep the original's source.
-- 2) pf_ai_memory: explicit, inspectable memory (no fine-tuning). The assistant reads relevant entries before acting
--    and the server writes feedback after acting: owner corrections of AI-created transactions, undo, patterns the
--    model reports, nightly reflection (habits) and notes the owner adds. Weights are confidence in [0, 1]; entries
--    not seen for 30 days decay and are dropped below 0.15.
-- Keys are normalised: lowercase, no Vietnamese diacritics, words separated by one space. Server role only.
begin;

-- ---------------------------------------------------------------- transaction source
alter table public.pf_tx add column source text not null default 'MANUAL'
  check (source in ('MANUAL', 'BANK', 'AI', 'NOTIFICATION', 'IMPORT', 'RECURRING', 'SYSTEM'));

update public.pf_tx set source = 'SYSTEM' where kind = 'OPENING';
update public.pf_tx set source = 'BANK' where id in (select tx_id from public.pf_inbound_event where tx_id is not null);
update public.pf_tx set source = 'RECURRING' where source = 'MANUAL' and id in (select matched_tx_id from public.pf_occurrence where matched_tx_id is not null);
-- replacements made by TX_CORRECT inherit the source of the transaction they replaced
update public.pf_tx t set source = o.source from public.pf_tx o
 where t.related_tx_id = o.id and t.source = 'MANUAL' and o.source <> 'MANUAL' and o.status = 'VOID'
   and t.kind in ('INCOME', 'EXPENSE', 'TRANSFER', 'UNKNOWN_CREDIT', 'UNKNOWN_DEBIT');

create function pf_private.tx_source_default() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.kind = 'OPENING' then new.source := 'SYSTEM'; end if;
  return new;
end $$;
create trigger pf_tx_source_default before insert on public.pf_tx for each row execute function pf_private.tx_source_default();

-- TX_CREATE: the ledger code is unchanged (renamed to *_core); the wrapper validates and stores the client source.
alter function pf_private.cmd_tx_create(uuid, jsonb) rename to cmd_tx_create_core;

create function pf_private.cmd_tx_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare res jsonb; src text := coalesce(p->>'source', 'MANUAL');
begin
  if src not in ('MANUAL', 'AI', 'NOTIFICATION', 'IMPORT') then perform pf_private.err('VALIDATION_FAILED'); end if;
  res := pf_private.cmd_tx_create_core(p_owner, p - 'source');
  if src <> 'MANUAL' then update public.pf_tx set source = src where id = (res->>'tx_id')::uuid; end if;
  return res;
end $$;

-- TX_CORRECT keeps the original's source on the replacement.
create or replace function pf_private.cmd_tx_correct(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare rev jsonb; created jsonb; src text;
begin
  rev := pf_private.cmd_tx_reverse(p_owner, jsonb_build_object('tx_id', p->>'tx_id', 'reason', p->>'reason', 'expected_version', (p->>'expected_version')::integer));
  select source into src from public.pf_tx where id = (p->>'tx_id')::uuid;
  created := pf_private.cmd_tx_create(p_owner, (p->'replacement') - 'source');
  update public.pf_tx set related_tx_id = (p->>'tx_id')::uuid, source = coalesce(src, source) where id = (created->>'tx_id')::uuid;
  return jsonb_build_object('tx_id', created->>'tx_id', 'voided_tx_id', p->>'tx_id', 'journal_id', created->>'journal_id', 'change_seq', created->>'change_seq');
end $$;

-- Matching an expected recurring occurrence marks a manually entered transaction as RECURRING.
create or replace function pf_private.cmd_occurrence_match(p_owner uuid, p jsonb) returns jsonb
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
  update public.pf_tx set source = 'RECURRING' where id = (p->>'tx_id')::uuid and source = 'MANUAL';
  return jsonb_build_object('occurrence_id', o.id, 'change_seq', pf_private.touch_change(p_owner, 'occurrence', o.id, o.version));
end $$;

-- Bank events: same as migration 007, plus source = BANK.
create or replace function public.pf_ingest_bank_event(
  p_provider text, p_external text, p_number_hash text, p_direction text, p_amount bigint, p_at timestamptz,
  p_content text, p_category uuid, p_balance bigint, p_payload jsonb
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l public.pf_account_link; ev uuid; res jsonb; kind text := case when p_direction = 'in' then 'INCOME' else 'EXPENSE' end;
begin
  if p_provider is null or p_external is null or p_amount <= 0 or p_direction not in ('in', 'out') then perform pf_private.err('VALIDATION_FAILED'); end if;
  select * into l from public.pf_account_link where provider = p_provider and number_hash = p_number_hash;
  if not found then
    return jsonb_build_object('status', 'UNMATCHED');
  end if;
  insert into public.pf_inbound_event(owner_id, provider, external_id, state, payload)
    values (l.owner_id, p_provider, p_external, 'UNMATCHED', coalesce(p_payload, '{}'::jsonb))
    on conflict (provider, external_id) do nothing returning id into ev;
  if ev is null then return jsonb_build_object('status', 'DUPLICATE'); end if;
  res := pf_private.cmd_tx_create(l.owner_id, jsonb_build_object(
    'kind', kind, 'account_id', l.account_id, 'amount', p_amount::text, 'effective_at', p_at,
    'category_id', p_category, 'note', left(coalesce(p_content, ''), 1000), 'merchant', nullif(left(coalesce(p_content, ''), 120), '')));
  update public.pf_tx set source = 'BANK' where id = (res->>'tx_id')::uuid;
  update public.pf_inbound_event set state = 'APPLIED', tx_id = (res->>'tx_id')::uuid where id = ev;
  if p_balance is not null and p_balance > 0 and (l.bank_balance_at is null or p_at >= l.bank_balance_at - interval '1 minute') then
    update public.pf_account_link set bank_balance = p_balance, bank_balance_at = greatest(p_at, coalesce(bank_balance_at, p_at)) where id = l.id;
  end if;
  return jsonb_build_object('status', 'APPLIED', 'tx_id', res->>'tx_id', 'owner_id', l.owner_id);
end $$;

-- Transactions list: same as migration 004, plus source.
create or replace function public.pf_read_transactions(p_owner uuid, p_limit integer, p_before_at timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc, x.id desc) from (
    select t.id, t.kind, t.status, t.effective_at, t.amount::text as amount, t.fee::text as fee, t.account_id, t.to_account_id, t.category_id,
           t.merchant, t.note, t.version, t.related_tx_id, t.contact_id, t.source,
           exists (select 1 from public.pf_debt d where d.origin_tx_id = t.id) or exists (select 1 from public.pf_debt_payment dp where dp.tx_id = t.id) as debt_linked
    from public.pf_tx t
    where t.owner_id = p_owner and t.status in ('POSTED','VOID')
      and (p_before_at is null or (t.effective_at, t.id) < (p_before_at, p_before_id))
    order by t.effective_at desc, t.id desc limit lim) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- memory
-- Lowercase, Vietnamese diacritics removed, anything else than a-z0-9 becomes one space.
create function pf_private.ai_norm(p text) returns text
language sql immutable set search_path = pg_catalog as $$
  select btrim(regexp_replace(lower(translate(normalize(coalesce(p, ''), NFC),
    'àáạảãâầấậẩẫăằắặẳẵÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴèéẹẻẽêềếệểễÈÉẸẺẼÊỀẾỆỂỄìíịỉĩÌÍỊỈĨòóọỏõôồốộổỗơờớợởỡÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠùúụủũưừứựửữÙÚỤỦŨƯỪỨỰỬỮỳýỵỷỹỲÝỴỶỸđĐ',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaeeeeeeeeeeeeeeeeeeeeeeiiiiiiiiiioooooooooooooooooooooooooooooooooouuuuuuuuuuuuuuuuuuuuuuyyyyyyyyyydd')),
    '[^a-z0-9]+', ' ', 'g'))
$$;

create table public.pf_ai_memory (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  kind text not null check (kind in ('ALIAS', 'CATEGORY_RULE', 'HABIT', 'PREFERENCE', 'PERSON', 'NOTE')),
  key text not null check (length(key) between 1 and 80 and key = pf_private.ai_norm(key)),
  value jsonb not null check (jsonb_typeof(value) = 'object' and length(value::text) <= 1000),
  weight numeric(4, 3) not null default 0.5 check (weight between 0 and 1),
  hits integer not null default 1 check (hits >= 0),
  last_seen_at timestamptz not null default now(),
  source text not null check (source in ('correction', 'undo', 'pattern', 'reflection', 'user')),
  created_at timestamptz not null default now(),
  unique (owner_id, kind, key)
);
alter table public.pf_ai_memory enable row level security;
create index pf_ai_memory_owner_idx on public.pf_ai_memory(owner_id, kind, weight desc);
revoke all on table public.pf_ai_memory from public, anon, authenticated;

create function pf_private.ai_memory_json(m public.pf_ai_memory) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('id', m.id, 'kind', m.kind, 'key', m.key, 'value', m.value, 'weight', m.weight, 'hits', m.hits,
    'last_seen_at', m.last_seen_at, 'source', m.source, 'created_at', m.created_at)
$$;

-- Two values say the same thing (a CATEGORY_RULE to the same category, an ALIAS to the same words, ...).
create function pf_private.ai_same(p_kind text, a jsonb, b jsonb) returns boolean
language sql immutable set search_path = pg_catalog, public as $$
  select case p_kind
    when 'CATEGORY_RULE' then a->>'category_id' is not distinct from b->>'category_id'
    when 'ALIAS' then pf_private.ai_norm(a->>'to') = pf_private.ai_norm(b->>'to')
    when 'PERSON' then pf_private.ai_norm(a->>'name') = pf_private.ai_norm(b->>'name')
    when 'PREFERENCE' then coalesce(a->>'account_id', a->>'text') is not distinct from coalesce(b->>'account_id', b->>'text')
    else a = b end
$$;

-- The one write path. Reinforcement: weight = least(1, weight * 0.8 + 0.3). 'undo' weakens (x0.5) an entry whose
-- value contains p_value and deletes it below 0.15. Returns the stored entry, or null when nothing is stored.
create function pf_private.ai_memory_put(p_owner uuid, p_kind text, p_key text, p_value jsonb, p_source text, p_weight numeric)
returns public.pf_ai_memory
language plpgsql set search_path = pg_catalog, public as $$
declare k text := left(pf_private.ai_norm(p_key), 80); m public.pf_ai_memory; init numeric;
begin
  if p_kind is null or p_kind not in ('ALIAS', 'CATEGORY_RULE', 'HABIT', 'PREFERENCE', 'PERSON', 'NOTE')
     or p_source is null or p_source not in ('correction', 'undo', 'pattern', 'reflection', 'user')
     or k = '' or p_value is null or jsonb_typeof(p_value) <> 'object' or length(p_value::text) > 1000 then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  k := btrim(k);
  init := least(1, greatest(0.05, coalesce(p_weight, case p_source when 'user' then 0.9 when 'correction' then 0.7 when 'reflection' then 0.5 else 0.4 end)));
  select * into m from public.pf_ai_memory where owner_id = p_owner and kind = p_kind and key = k for update;
  if not found then
    if p_source = 'undo' then return null; end if;
    insert into public.pf_ai_memory(owner_id, kind, key, value, weight, source)
      values (p_owner, p_kind, k, p_value, round(init, 3), p_source) returning * into m;
    -- bounded memory: keep the 500 strongest entries (owner-added ones are never evicted)
    delete from public.pf_ai_memory where id in (
      select id from public.pf_ai_memory where owner_id = p_owner and source <> 'user'
       order by weight desc, last_seen_at desc offset 500);
    return m;
  end if;
  if p_source = 'undo' then
    if not (m.value @> p_value) or m.source = 'user' then return m; end if;
    if m.weight * 0.5 < 0.15 then
      delete from public.pf_ai_memory where id = m.id;
      return null;
    end if;
    update public.pf_ai_memory set weight = round(weight * 0.5, 3), source = 'undo', last_seen_at = now() where id = m.id returning * into m;
    return m;
  end if;
  if p_source = 'reflection' or pf_private.ai_same(p_kind, m.value, p_value) then
    update public.pf_ai_memory set value = case when m.source = 'user' then m.value else p_value end,
           weight = round(least(1, weight * 0.8 + 0.3), 3), hits = hits + 1, last_seen_at = now(),
           source = case when m.source = 'user' then 'user' when p_source = 'pattern' and m.source <> 'undo' then m.source else p_source end
     where id = m.id returning * into m;
  elsif p_source in ('user', 'correction') then
    update public.pf_ai_memory set value = p_value, weight = round(init, 3), hits = 1, last_seen_at = now(), source = p_source
     where id = m.id returning * into m;
  elsif m.weight < 0.4 and m.source <> 'user' then -- weak entry replaced by new evidence
    update public.pf_ai_memory set value = p_value, weight = round(init, 3), hits = 1, last_seen_at = now(), source = p_source
     where id = m.id returning * into m;
  else -- conflicting weak evidence against a strong entry: lower the confidence a little
    update public.pf_ai_memory set weight = round(weight * 0.9, 3), last_seen_at = now() where id = m.id returning * into m;
  end if;
  return m;
end $$;

create function public.pf_ai_memory_upsert(p_owner uuid, p_kind text, p_key text, p_value jsonb, p_source text, p_weight numeric default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m public.pf_ai_memory;
begin
  perform pf_private.assert_owner(p_owner);
  m := pf_private.ai_memory_put(p_owner, p_kind, p_key, p_value, p_source, p_weight);
  if m.id is null then return null; end if;
  return pf_private.ai_memory_json(m);
end $$;

-- Several learnings of one agent turn: [{kind, key, value, source, weight?}] (max 20).
create function public.pf_ai_memory_upsert_many(p_owner uuid, p_items jsonb) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare it jsonb; n integer := 0; m public.pf_ai_memory;
begin
  perform pf_private.assert_owner(p_owner);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 20 then perform pf_private.err('VALIDATION_FAILED'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    m := pf_private.ai_memory_put(p_owner, it->>'kind', it->>'key', it->'value', it->>'source', (it->>'weight')::numeric);
    if m.id is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Replaces the whole set of (kind, source) entries, e.g. the nightly HABIT reflection: entries still present are
-- reinforced, the others are removed. Never touches entries the owner added.
create function public.pf_ai_memory_replace(p_owner uuid, p_kind text, p_source text, p_items jsonb) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare it jsonb; n integer := 0; keys text[];
begin
  perform pf_private.assert_owner(p_owner);
  if p_source is null or p_source = 'user' or p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 40 then
    perform pf_private.err('VALIDATION_FAILED');
  end if;
  keys := array(select left(pf_private.ai_norm(x->>'key'), 80) from jsonb_array_elements(p_items) x);
  delete from public.pf_ai_memory where owner_id = p_owner and kind = p_kind and source = p_source and not (key = any(keys));
  for it in select * from jsonb_array_elements(p_items) loop
    perform pf_private.ai_memory_put(p_owner, p_kind, it->>'key', it->'value', p_source, (it->>'weight')::numeric);
    n := n + 1;
  end loop;
  return n;
end $$;

create function public.pf_ai_memory_list(p_owner uuid, p_kind text, p_limit integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(pf_private.ai_memory_json(x) order by x.kind, x.weight desc, x.last_seen_at desc) from (
      select * from public.pf_ai_memory where owner_id = p_owner and (p_kind is null or kind = p_kind)
       order by kind, weight desc, last_seen_at desc limit lim) x), '[]'::jsonb);
end $$;

-- Memory relevant to one request: ALIAS / CATEGORY_RULE / PERSON entries whose key words all occur in the request
-- (aliases expand the request with what they mean), then the strongest HABIT / PREFERENCE / NOTE entries.
-- Matched entries count as seen (last_seen_at).
create function public.pf_ai_memory_relevant(p_owner uuid, p_terms text[], p_limit integer) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 20), 1), 40); words text[]; matched uuid[]; general uuid[];
begin
  perform pf_private.assert_owner(p_owner);
  if p_terms is not null and cardinality(p_terms) > 300 then perform pf_private.err('VALIDATION_FAILED'); end if;
  words := array(select w from unnest(coalesce(p_terms, '{}'::text[])) t, regexp_split_to_table(pf_private.ai_norm(t), ' ') w where w <> '');
  words := words || array(select w from public.pf_ai_memory m, regexp_split_to_table(pf_private.ai_norm(m.value->>'to'), ' ') w
                           where m.owner_id = p_owner and m.kind = 'ALIAS' and m.weight >= 0.15 and string_to_array(m.key, ' ') <@ words and w <> '');
  matched := array(select id from public.pf_ai_memory m
                    where m.owner_id = p_owner and m.kind in ('ALIAS', 'CATEGORY_RULE', 'PERSON') and m.weight >= 0.15
                      and cardinality(words) > 0 and string_to_array(m.key, ' ') <@ words
                    order by m.weight desc, m.last_seen_at desc limit lim);
  general := array(select id from public.pf_ai_memory m
                    where m.owner_id = p_owner and m.kind in ('HABIT', 'PREFERENCE', 'NOTE') and m.weight >= 0.15
                    order by (m.source = 'user') desc, m.weight desc, m.last_seen_at desc limit 12);
  if cardinality(matched) > 0 then update public.pf_ai_memory set last_seen_at = now() where id = any(matched); end if;
  return coalesce((select jsonb_agg(pf_private.ai_memory_json(m) order by array_position(matched || general, m.id))
                     from public.pf_ai_memory m where m.id = any(matched || general)), '[]'::jsonb);
end $$;

create function public.pf_ai_memory_delete(p_owner uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  delete from public.pf_ai_memory where id = p_id and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  return jsonb_build_object('deleted', true);
end $$;

-- Forgetting: entries not seen for 30 days lose 10% per run (nightly); below 0.15 they are dropped.
-- Owner-added entries never decay.
create function public.pf_ai_memory_decay(p_owner uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare decayed integer; dropped integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_ai_memory set weight = round(weight * 0.9, 3)
   where owner_id = p_owner and source <> 'user' and last_seen_at < now() - interval '30 days';
  get diagnostics decayed = row_count;
  delete from public.pf_ai_memory where owner_id = p_owner and source <> 'user' and weight < 0.15;
  get diagnostics dropped = row_count;
  return jsonb_build_object('decayed', decayed, 'dropped', dropped);
end $$;

-- ---------------------------------------------------------------- learning from the ledger
-- Rule key of a transaction: its note (or merchant), normalised; null when too short / too long to be a keyword.
create function pf_private.ai_tx_key(p_note text, p_merchant text) returns text
language sql immutable set search_path = pg_catalog, public as $$
  select case when length(k) between 3 and 60 and cardinality(string_to_array(k, ' ')) <= 6 then k end
    from (select pf_private.ai_norm(left(coalesce(nullif(btrim(p_note), ''), p_merchant), 60)) as k) x
$$;

create function pf_private.ai_rule_value(p_note text, p_merchant text, p_category uuid) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select jsonb_build_object('phrase', left(btrim(coalesce(nullif(btrim(p_note), ''), p_merchant, '')), 60), 'category_id', c.id, 'category', c.name, 'type', c.type)
    from public.pf_category c where c.id = p_category
$$;

-- Called by the Worker after a committed command. Only transactions the assistant created (source = AI) teach:
-- a category change (TX_ANNOTATE / TX_CORRECT) records "keyword -> new category" (correction); a reversal weakens
-- the rule that pointed to the reversed category (undo).
create function public.pf_ai_observe_command(p_owner uuid, p_type text, p_payload jsonb, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.pf_tx; o public.pf_tx; k text; learned text;
begin
  perform pf_private.assert_owner(p_owner);
  if p_type = 'TX_ANNOTATE' and p_payload ? 'category_id' then
    select * into t from public.pf_tx where id = (p_payload->>'tx_id')::uuid and owner_id = p_owner;
    if found and t.source = 'AI' and t.category_id is not null then
      k := pf_private.ai_tx_key(t.note, t.merchant);
      if k is not null then
        perform pf_private.ai_memory_put(p_owner, 'CATEGORY_RULE', k, pf_private.ai_rule_value(t.note, t.merchant, t.category_id), 'correction', null);
        learned := 'correction';
      end if;
    end if;
  elsif p_type = 'TX_CORRECT' then
    select * into o from public.pf_tx where id = (p_result->>'voided_tx_id')::uuid and owner_id = p_owner;
    select * into t from public.pf_tx where id = (p_result->>'tx_id')::uuid and owner_id = p_owner;
    if o.id is not null and t.id is not null and o.source = 'AI' and t.category_id is not null and t.category_id is distinct from o.category_id then
      k := coalesce(pf_private.ai_tx_key(t.note, t.merchant), pf_private.ai_tx_key(o.note, o.merchant));
      if k is not null then
        perform pf_private.ai_memory_put(p_owner, 'CATEGORY_RULE', k,
          pf_private.ai_rule_value(coalesce(nullif(btrim(t.note), ''), o.note), coalesce(t.merchant, o.merchant), t.category_id), 'correction', null);
        learned := 'correction';
      end if;
    end if;
  elsif p_type = 'TX_REVERSE' then
    select * into t from public.pf_tx where id = (p_payload->>'tx_id')::uuid and owner_id = p_owner;
    if found and t.source = 'AI' and t.status = 'VOID' and t.category_id is not null then
      k := pf_private.ai_tx_key(t.note, t.merchant);
      if k is not null then
        perform pf_private.ai_memory_put(p_owner, 'CATEGORY_RULE', k, jsonb_build_object('category_id', t.category_id), 'undo', null);
        learned := 'undo';
      end if;
    end if;
  end if;
  return jsonb_build_object('learned', learned);
end $$;

-- Positive feedback (nightly): assistant-created income/expense of the last day that the owner kept unchanged
-- for 20+ hours reinforces "keyword -> category". The 24-hour window means each transaction counts once.
create function public.pf_ai_confirm_recent(p_owner uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t record; n integer := 0;
begin
  perform pf_private.assert_owner(p_owner);
  for t in select x.note, x.merchant, x.category_id, pf_private.ai_tx_key(x.note, x.merchant) as k from public.pf_tx x
            where x.owner_id = p_owner and x.source = 'AI' and x.status = 'POSTED' and x.kind in ('INCOME', 'EXPENSE')
              and x.category_id is not null and x.created_at >= now() - interval '44 hours' and x.created_at < now() - interval '20 hours' loop
    continue when t.k is null;
    perform pf_private.ai_memory_put(p_owner, 'CATEGORY_RULE', t.k, pf_private.ai_rule_value(t.note, t.merchant, t.category_id), 'pattern', null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Reflection inputs for the last p_days local days (today included): meals (food categories by local window),
-- frequent keywords, spending by ISO weekday and the dominant account per (category, part of day).
create function public.pf_ai_reflect_stats(p_owner uuid, p_days integer) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare d integer := least(greatest(coalesce(p_days, 30), 7), 90); t_to date; t_from date; r jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  t_to := (now() at time zone 'Asia/Ho_Chi_Minh')::date + 1;
  t_from := t_to - d;
  with tx as (
    select t.amount::numeric as amt, t.category_id, t.account_id, t.note, t.merchant, (t.effective_at at time zone 'Asia/Ho_Chi_Minh') as lt
      from public.pf_tx t
     where t.owner_id = p_owner and t.status = 'POSTED' and t.kind = 'EXPENSE'
       and t.effective_at >= (t_from::timestamp at time zone 'Asia/Ho_Chi_Minh') and t.effective_at < (t_to::timestamp at time zone 'Asia/Ho_Chi_Minh')
  ), meal as (
    select x.*, case when x.lt::time >= '04:00' and x.lt::time < '10:30' then 'breakfast'
                     when x.lt::time >= '10:30' and x.lt::time < '15:00' then 'lunch'
                     when x.lt::time >= '15:00' and x.lt::time < '23:00' then 'dinner' end as meal
      from tx x where x.category_id in (select pf_private.food_categories(p_owner))
  ), meals as (
    select meal, count(distinct lt::date) as days, count(*) as n, percentile_disc(0.5) within group (order by amt) as median,
           mode() within group (order by category_id) as category_id, mode() within group (order by account_id) as account_id
      from meal where meal is not null group by meal
  ), kw as (
    select pf_private.ai_tx_key(note, merchant) as k, min(left(btrim(coalesce(nullif(btrim(note), ''), merchant)), 60)) as phrase,
           count(*) as n, percentile_disc(0.5) within group (order by amt) as median, mode() within group (order by category_id) as category_id
      from tx where pf_private.ai_tx_key(note, merchant) is not null group by 1 having count(*) >= 3
  ), wd as (
    select extract(isodow from g)::int as weekday, count(*) as days from generate_series(t_from, t_to - 1, interval '1 day') g group by 1
  ), wsum as (
    select extract(isodow from lt)::int as weekday, sum(amt) as total from tx group by 1
  ), dp as (
    select x.category_id, x.account_id,
           case when x.lt::time >= '04:00' and x.lt::time < '11:00' then 'morning'
                when x.lt::time >= '11:00' and x.lt::time < '14:00' then 'noon'
                when x.lt::time >= '14:00' and x.lt::time < '18:00' then 'afternoon' else 'evening' end as daypart
      from tx x where x.category_id is not null
  ), pref as (
    select category_id, daypart, account_id, count(*) as c, sum(count(*)) over (partition by category_id, daypart) as n,
           row_number() over (partition by category_id, daypart order by count(*) desc, account_id) as rn
      from dp group by category_id, daypart, account_id
  )
  select jsonb_build_object(
      'from', to_char(t_from, 'YYYY-MM-DD'), 'to', to_char(t_to - 1, 'YYYY-MM-DD'), 'days', d,
      'meals', (select coalesce(jsonb_agg(jsonb_build_object('meal', m.meal, 'days', m.days, 'count', m.n, 'median', m.median::bigint::text,
                    'category_id', m.category_id, 'category', c.name, 'account_id', m.account_id, 'account', a.name)
                    order by array_position(array['breakfast', 'lunch', 'dinner'], m.meal)), '[]'::jsonb)
                  from meals m left join public.pf_category c on c.id = m.category_id left join public.pf_account a on a.id = m.account_id),
      'keywords', (select coalesce(jsonb_agg(jsonb_build_object('key', k.k, 'phrase', k.phrase, 'count', k.n, 'median', k.median::bigint::text,
                    'category_id', k.category_id, 'category', c.name) order by k.n desc, k.k), '[]'::jsonb)
                  from (select * from kw order by n desc, k limit 8) k left join public.pf_category c on c.id = k.category_id),
      'weekdays', (select coalesce(jsonb_agg(jsonb_build_object('weekday', w.weekday, 'days', w.days, 'total', coalesce(s.total, 0)::bigint::text)
                    order by w.weekday), '[]'::jsonb) from wd w left join wsum s on s.weekday = w.weekday),
      'preferences', (select coalesce(jsonb_agg(jsonb_build_object('category_id', p.category_id, 'category', c.name, 'daypart', p.daypart,
                    'account_id', p.account_id, 'account', a.name, 'count', p.c, 'total', p.n) order by p.n desc, c.name, p.daypart), '[]'::jsonb)
                  from pref p join public.pf_category c on c.id = p.category_id join public.pf_account a on a.id = p.account_id and not a.archived
                 where p.rn = 1 and p.n >= 4))
    into r;
  return r;
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
