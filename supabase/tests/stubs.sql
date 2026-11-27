-- Minimal stand-ins for the Supabase-provided roles and auth schema, for plain Postgres test databases only.
-- Never run this on a real Supabase project.
-- Roles are cluster-wide, so creation must be idempotent when several test databases share one server.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;  -- real service_role bypasses RLS
end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz);
