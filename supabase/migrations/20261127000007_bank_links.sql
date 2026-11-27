-- MoMa migration 007: real bank connections (SePay) and idempotent inbound bank events.
-- A MoMa account can be linked to exactly one bank account that SePay has already verified with the bank.
-- Inbound events (webhook or polling) are deduplicated by a provider key and posted through the normal ledger code
-- (pf_private.cmd_tx_create), so the ledger invariants are unchanged. Server role only.
begin;

create table public.pf_account_link (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  account_id uuid not null unique references public.pf_account(id),
  provider text not null check (provider in ('SEPAY')),
  external_id text not null,
  number_hash text not null,
  last4 text,
  holder_name text,
  bank_name text,
  bank_balance bigint,
  bank_balance_at timestamptz,
  cursor_id text,
  linked_at timestamptz not null default now(),
  unique (provider, external_id),
  unique (provider, number_hash)
);
alter table public.pf_account_link enable row level security;

create table public.pf_inbound_event (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  provider text not null,
  external_id text not null,
  received_at timestamptz not null default now(),
  state text not null check (state in ('APPLIED', 'UNMATCHED', 'IGNORED')),
  tx_id uuid references public.pf_tx(id),
  payload jsonb not null,
  unique (provider, external_id)
);
alter table public.pf_inbound_event enable row level security;

create function public.pf_link_account(
  p_owner uuid, p_account uuid, p_provider text, p_external text, p_number_hash text,
  p_last4 text, p_holder text, p_bank text, p_balance bigint
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare l public.pf_account_link;
begin
  perform pf_private.assert_owner(p_owner);
  perform 1 from public.pf_account where id = p_account and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  select * into l from public.pf_account_link where provider = p_provider and external_id = p_external;
  if found then
    if l.account_id <> p_account then perform pf_private.err('IDENTITY_CONFLICT'); end if;
    return jsonb_build_object('link_id', l.id, 'replayed', true);
  end if;
  insert into public.pf_account_link(owner_id, account_id, provider, external_id, number_hash, last4, holder_name, bank_name, bank_balance, bank_balance_at)
    values (p_owner, p_account, p_provider, p_external, p_number_hash, p_last4, p_holder, p_bank, p_balance, now())
    returning * into l;
  return jsonb_build_object('link_id', l.id, 'replayed', false);
end $$;

create function public.pf_read_account_links(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'account_id', l.account_id, 'provider', l.provider, 'external_id', l.external_id, 'last4', l.last4,
      'holder_name', l.holder_name, 'bank_name', l.bank_name, 'bank_balance', l.bank_balance::text,
      'bank_balance_at', l.bank_balance_at, 'cursor_id', l.cursor_id,
      'ledger_balance', (case when b.class = 'ASSET' then b.debit_net else -b.debit_net end)::text) order by l.linked_at)
    from public.pf_account_link l
    join public.pf_account a on a.id = l.account_id
    join pf_private.ledger_balance b on b.id = a.ledger_account_id
    where l.owner_id = p_owner), '[]'::jsonb);
end $$;

create function public.pf_link_find(p_provider text, p_number_hash text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare l public.pf_account_link;
begin
  select * into l from public.pf_account_link where provider = p_provider and number_hash = p_number_hash;
  if not found then return null; end if;
  return jsonb_build_object('owner_id', l.owner_id, 'account_id', l.account_id);
end $$;

create function public.pf_link_set_cursor(p_owner uuid, p_account uuid, p_cursor text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_account_link set cursor_id = p_cursor where account_id = p_account and owner_id = p_owner;
  return jsonb_build_object('ok', true);
end $$;

-- Posts one bank event exactly once. The account link decides the account; the category is chosen by the caller.
create function public.pf_ingest_bank_event(
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
  update public.pf_inbound_event set state = 'APPLIED', tx_id = (res->>'tx_id')::uuid where id = ev;
  if p_balance is not null and p_balance > 0 and (l.bank_balance_at is null or p_at >= l.bank_balance_at - interval '1 minute') then
    update public.pf_account_link set bank_balance = p_balance, bank_balance_at = greatest(p_at, coalesce(bank_balance_at, p_at)) where id = l.id;
  end if;
  return jsonb_build_object('status', 'APPLIED', 'tx_id', res->>'tx_id', 'owner_id', l.owner_id);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
