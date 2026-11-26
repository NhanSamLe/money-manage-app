-- Shared psql test helpers (session-local pg_temp functions). Included with \ir by the numbered test files.
create or replace function pg_temp.cmd(p_type text, p_payload jsonb) returns jsonb language plpgsql as $$
declare id uuid := gen_random_uuid();
begin
  return public.pf_execute_command('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444',
    id, md5(id::text), jsonb_build_object('command_id', id, 'command_type', p_type, 'schema_version', 1, 'payload', p_payload));
end $$;

create or replace function pg_temp.expect_error(p_code text, p_type text, p_payload jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.cmd(p_type, p_payload);
  raise exception 'expected %', p_code;
exception when others then
  if sqlerrm <> p_code then raise exception 'wanted %, got %', p_code, sqlerrm; end if;
end $$;

create or replace function pg_temp.acc(p_name text) returns uuid language sql as $$
  select (x->>'id')::uuid from jsonb_array_elements(public.pf_read_accounts('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;
create or replace function pg_temp.bal(p_name text) returns bigint language sql as $$
  select (x->>'balance')::bigint from jsonb_array_elements(public.pf_read_accounts('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;
create or replace function pg_temp.cat(p_name text) returns uuid language sql as $$
  select (x->>'id')::uuid from jsonb_array_elements(public.pf_read_categories('11111111-1111-1111-1111-111111111111')) x where x->>'name' = p_name
$$;

