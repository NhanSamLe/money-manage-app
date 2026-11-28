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
