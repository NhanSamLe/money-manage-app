-- MoMa migration 012: notification inbox. Every push the server sends (money in/out, reminders, insights, budget
-- alerts) is also stored here so the app's bell shows the same items, read/unread, with the route to open.
-- Server role only.
begin;

create table public.pf_notification (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.pf_owner(user_id),
  type text not null check (length(type) between 1 and 40),
  title text not null check (length(title) between 1 and 200),
  body text not null default '' check (length(body) <= 1000),
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
alter table public.pf_notification enable row level security;
revoke all on table public.pf_notification from public, anon, authenticated;
create index pf_notification_owner_idx on public.pf_notification(owner_id, created_at desc);

create function public.pf_notification_add(p_owner uuid, p_type text, p_title text, p_body text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare nid uuid;
begin
  perform pf_private.assert_owner(p_owner);
  if coalesce(p_type, '') = '' or coalesce(p_title, '') = '' then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_notification(owner_id, type, title, body, data)
    values (p_owner, left(p_type, 40), left(p_title, 200), left(coalesce(p_body, ''), 1000),
            case when jsonb_typeof(p_data) = 'object' then p_data else '{}'::jsonb end)
    returning id into nid;
  -- Keep the inbox bounded: the newest 500 per owner.
  delete from public.pf_notification where owner_id = p_owner and id in (
    select id from public.pf_notification where owner_id = p_owner order by created_at desc, id desc offset 500);
  return jsonb_build_object('id', nid);
end $$;

create function public.pf_notification_list(p_owner uuid, p_limit integer, p_before timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  perform pf_private.assert_owner(p_owner);
  return jsonb_build_object(
    'unread', (select count(*) from public.pf_notification where owner_id = p_owner and read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                 'data', n.data, 'created_at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc, n.id desc)
               from (select * from public.pf_notification where owner_id = p_owner
                       and (p_before is null or created_at < p_before)
                      order by created_at desc, id desc limit lim) n), '[]'::jsonb));
end $$;

-- p_ids null = mark everything read.
create function public.pf_notification_mark_read(p_owner uuid, p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare n integer;
begin
  perform pf_private.assert_owner(p_owner);
  update public.pf_notification set read_at = now()
   where owner_id = p_owner and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return jsonb_build_object('updated', n);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
