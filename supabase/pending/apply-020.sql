-- MoMa migration 020: self-adjusting budgets (D-026). Read-only history for the budget proposer: one row per expense
-- transaction and category in a date range, with the posted (owner's) amount and whether it is a recurring / fixed
-- cost (matched to a recurring occurrence or applied by a recurring split rule). Reversed / corrected transactions net
-- out because all their journals are summed per transaction. Proposals, pacing and the monthly auto-apply are computed
-- in the API (apps/api/src/modules/budgets/plan.ts); budgets are still written only through BUDGET_UPSERT.
-- Server role only.
begin;

create function public.pf_budget_history(p_owner uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare t_from timestamptz; t_to timestamptz;
begin
  perform pf_private.assert_owner(p_owner);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 200 then perform pf_private.err('VALIDATION_FAILED'); end if;
  t_from := p_from::timestamp at time zone 'Asia/Ho_Chi_Minh';
  t_to := (p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh';
  return coalesce((
    with lines as (
      select j.tx_id, c.id as category_id, e.signed_amount::numeric as amt, j.effective_at
        from public.pf_entry e
        join public.pf_journal j on j.id = e.journal_id and j.posted
        join public.pf_ledger_account a on a.id = e.ledger_account_id and a.class = 'EXPENSE'
        join public.pf_category c on c.ledger_account_id = a.id and c.owner_id = p_owner
       where j.owner_id = p_owner and j.effective_at >= t_from and j.effective_at < t_to
         and a.code not in ('SYS_ADJUSTMENT_OUT')
    ), per_tx as (
      select tx_id, category_id, sum(amt) as amount, min(effective_at) as at
        from lines group by tx_id, category_id having sum(amt) > 0
    )
    select jsonb_agg(jsonb_build_object(
             'tx_id', p.tx_id,
             'day', to_char((p.at at time zone 'Asia/Ho_Chi_Minh')::date, 'YYYY-MM-DD'),
             'category_id', p.category_id,
             'amount', p.amount::text,
             'recurring', exists (select 1 from public.pf_occurrence o where o.matched_tx_id = p.tx_id)
                          or exists (select 1 from public.pf_split_application s
                                      where s.tx_id = p.tx_id and s.recurring_id is not null and s.state = 'APPLIED'))
           order by p.at, p.tx_id)
      from per_tx p), '[]'::jsonb);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

commit;
