-- Minimal stand-ins for the Supabase-provided roles and auth schema, for plain Postgres test databases only.
-- Never run this on a real Supabase project.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;  -- real Supabase service_role bypasses RLS
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz);
