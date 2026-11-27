-- Allows re-sending the owner invite: drops the pending (unconfirmed) invite binding so a fresh invite can be recorded.
-- Never touches a BOUND owner. Server role only.
begin;

create function public.pf_setup_reset_invite(p_lease uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_setup;
begin
  select * into s from public.pf_setup where singleton = 1 for update;
  if s.state = 'BOUND' then perform pf_private.err('SETUP_ALREADY_BOUND'); end if;
  if s.lease_id is distinct from p_lease or s.lease_expires_at is null or s.lease_expires_at <= now() then perform pf_private.err('SETUP_LEASE_INVALID'); end if;
  update public.pf_setup set state = 'UNINITIALIZED', invite_user_id = null, updated_at = now() where singleton = 1;
  return jsonb_build_object('old_invite_user_id', s.invite_user_id);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
