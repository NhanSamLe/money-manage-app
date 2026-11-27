-- MoMa: chạy file này MỘT lần trong Supabase SQL Editor (Run and enable RLS)
-- MoMa migration 011: ACCOUNT_UPDATE edits the bank / wallet name (institution) and the last 4 digits, and can set
-- the account's current balance.
--   * "institution": new bank / wallet name (1..40 chars).
--   * "last4": 4 digits, or "" to clear.
--   * "balance" (+ optional "balance_at"): the balance the owner (or the bank's own notification) reports now.
--       - baseline unknown: posts the opening balance (OPENING, counter-leg SYS_OPENING_EQUITY) dated just before
--         the account's first transaction (or balance_at / now when it has none), so balance = the reported figure;
--       - baseline known: posts the difference as an ADJUSTMENT (counter-leg SYS_ADJUSTMENT_IN / _OUT, which the
--         dashboard already excludes from income and expense). No difference, nothing posted.
-- Only pf_private.cmd_account_update changes; the command dispatcher (pf_execute_command) is untouched.
begin;

create or replace function pf_private.cmd_account_update(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare a public.pf_account; nm text; inst text; l4 text; cls public.pf_ledger_class; net numeric; target bigint;
        diff bigint; s bigint; at timestamptz; first_at timestamptz; tx uuid; j uuid; adj_tx uuid;
begin
  select * into a from public.pf_account where id = (p->>'account_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if a.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  nm := coalesce(nullif(btrim(p->>'name'), ''), a.name);
  if length(nm) > 120 then perform pf_private.err('VALIDATION_FAILED'); end if;
  inst := case when p ? 'institution' then nullif(btrim(p->>'institution'), '') else a.institution end;
  if inst is null or length(inst) > 40 then perform pf_private.err('VALIDATION_FAILED'); end if;
  l4 := case when p ? 'last4' then nullif(btrim(p->>'last4'), '') else a.last4 end;
  if l4 is not null and l4 !~ '^[0-9]{4}$' then perform pf_private.err('VALIDATION_FAILED'); end if;
  update public.pf_account set name = nm, institution = inst, last4 = l4,
         archived = coalesce((p->>'archived')::boolean, archived),
         hidden = coalesce((p->>'hidden')::boolean, hidden), version = version + 1
   where id = a.id returning * into a;
  update public.pf_ledger_account set name = a.name where id = a.ledger_account_id;

  if p ? 'balance' then
    if a.archived then perform pf_private.err('ACCOUNT_ARCHIVED'); end if;
    target := pf_private.parse_money(p->>'balance', false);
    select b.class, b.debit_net into cls, net from pf_private.ledger_balance b where b.id = a.ledger_account_id;
    -- Shown balance: asset = debit net, liability (card) = outstanding = -debit net.
    diff := target - (case when cls = 'ASSET' then net else -net end)::bigint;
    s := case when cls = 'ASSET' then diff else -diff end; -- signed amount on the account's ledger line
    if not a.baseline_known then
      select min(effective_at) into first_at from public.pf_tx
       where owner_id = p_owner and (account_id = a.id or to_account_id = a.id) and status = 'POSTED';
      at := coalesce((p->>'balance_at')::timestamptz, now());
      if first_at is not null and at >= first_at then at := first_at - interval '1 second'; end if;
      if diff <> 0 then
        tx := gen_random_uuid();
        insert into public.pf_tx(id, owner_id, kind, status, effective_at, account_id, amount, note)
          values (tx, p_owner, 'OPENING', 'DRAFT', at, a.id, abs(diff), 'Số dư đầu kỳ');
        j := pf_private.post_journal(p_owner, tx, at, 'ORIGINAL', jsonb_build_array(
          jsonb_build_object('ledger_account_id', a.ledger_account_id, 'signed_amount', s::text),
          jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_OPENING_EQUITY'), 'signed_amount', (-s)::text)));
        update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
      end if;
      update public.pf_account set baseline_known = true, baseline_at = at where id = a.id returning * into a;
    elsif diff <> 0 then
      at := coalesce((p->>'balance_at')::timestamptz, now());
      adj_tx := gen_random_uuid();
      insert into public.pf_tx(id, owner_id, kind, status, effective_at, account_id, amount, note)
        values (adj_tx, p_owner, 'ADJUSTMENT', 'DRAFT', at, a.id, abs(diff), 'Điều chỉnh số dư');
      j := pf_private.post_journal(p_owner, adj_tx, at, 'ORIGINAL', jsonb_build_array(
        jsonb_build_object('ledger_account_id', a.ledger_account_id, 'signed_amount', s::text),
        jsonb_build_object('ledger_account_id',
          pf_private.sys_ledger(p_owner, case when s > 0 then 'SYS_ADJUSTMENT_IN' else 'SYS_ADJUSTMENT_OUT' end),
          'signed_amount', (-s)::text)));
      update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = adj_tx;
      perform pf_private.touch_change(p_owner, 'transaction', adj_tx, 2);
    end if;
  end if;
  return jsonb_build_object('account_id', a.id, 'adjustment_tx_id', adj_tx,
    'change_seq', pf_private.touch_change(p_owner, 'account', a.id, a.version));
end $$;

revoke all on function pf_private.cmd_account_update(uuid, jsonb) from public, anon, authenticated, service_role;

commit;
