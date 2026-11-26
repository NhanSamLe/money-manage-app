-- MoMa migration 002: core server-only RPCs (setup, device, execute_command, reads).
-- Status: WRITTEN, NOT RUN. Apply to a disposable Supabase/Postgres first (docs/12 section 6).
-- Decisions (see docs/decision-log.md): denormalised projection columns on pf_tx written only by RPC;
-- SYS_FEE_EXPENSE system ledger account for transfer fees (BR-15).
begin;

alter table public.pf_tx
  add column if not exists amount public.pf_positive,
  add column if not exists account_id uuid references public.pf_account(id),
  add column if not exists to_account_id uuid references public.pf_account(id),
  add column if not exists category_id uuid references public.pf_category(id),
  add column if not exists fee public.pf_money not null default 0;

-- ---------------------------------------------------------------- helpers
create function pf_private.err(code text) returns void language plpgsql as $$
begin raise exception using message = code, errcode = 'P0001'; end $$;

create function pf_private.parse_money(p text, p_positive boolean default true) returns bigint
language plpgsql immutable set search_path = pg_catalog, public as $$
declare v numeric;
begin
  if p is null or p !~ '^-?[0-9]{1,16}$' then perform pf_private.err('INVALID_AMOUNT'); end if;
  v := p::numeric;
  if abs(v) > 9000000000000000 or (p_positive and v <= 0) then perform pf_private.err('INVALID_AMOUNT'); end if;
  return v::bigint;
end $$;

create function pf_private.assert_owner(p_owner uuid) returns void
language plpgsql stable set search_path = pg_catalog, public as $$
begin
  if not exists (select 1 from public.pf_owner where user_id = p_owner) then perform pf_private.err('OWNER_NOT_BOUND'); end if;
end $$;

create function pf_private.sys_ledger(p_owner uuid, p_code text) returns uuid
language sql stable set search_path = pg_catalog, public as $$
  select id from public.pf_ledger_account where owner_id = p_owner and code = p_code
$$;

create function pf_private.touch_change(p_owner uuid, p_entity text, p_id uuid, p_version integer) returns bigint
language sql set search_path = pg_catalog, public as $$
  insert into public.pf_change(owner_id, entity, entity_id, version, op) values (p_owner, p_entity, p_id, p_version, 'UPSERT') returning seq
$$;

-- ---------------------------------------------------------------- setup (singleton owner)
create function public.pf_setup_reserve(p_lease uuid, p_expires timestamptz) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_setup;
begin
  select * into s from public.pf_setup where singleton = 1 for update;
  if s.state = 'BOUND' then perform pf_private.err('SETUP_ALREADY_BOUND'); end if;
  if s.lease_id is not null and s.lease_expires_at > now() and s.lease_id <> p_lease then perform pf_private.err('SETUP_LEASE_HELD'); end if;
  update public.pf_setup set lease_id = p_lease, lease_expires_at = p_expires, updated_at = now() where singleton = 1;
  return jsonb_build_object('state', s.state, 'invite_user_id', s.invite_user_id);
end $$;

create function public.pf_setup_record_invite(p_lease uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_setup;
begin
  select * into s from public.pf_setup where singleton = 1 for update;
  if s.state = 'BOUND' then perform pf_private.err('SETUP_ALREADY_BOUND'); end if;
  if s.lease_id is distinct from p_lease or s.lease_expires_at <= now() then perform pf_private.err('SETUP_LEASE_INVALID'); end if;
  if s.invite_user_id is not null and s.invite_user_id <> p_user then perform pf_private.err('IDENTITY_CONFLICT'); end if;
  update public.pf_setup set state = 'INVITE_PENDING', invite_user_id = p_user, updated_at = now() where singleton = 1;
  return jsonb_build_object('state', 'INVITE_PENDING');
end $$;

create function pf_private.seed_owner(p_owner uuid) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare cid uuid; lid uuid; r record;
begin
  insert into public.pf_ledger_account(owner_id, code, class, name) values
    (p_owner, 'SYS_OPENING_EQUITY', 'EQUITY', 'Vốn đầu kỳ'),
    (p_owner, 'SYS_SUSPENSE_CREDIT', 'CLEARING', 'Tiền vào chưa phân loại'),
    (p_owner, 'SYS_SUSPENSE_DEBIT', 'CLEARING', 'Tiền ra chưa phân loại'),
    (p_owner, 'SYS_TRANSFER_IN_TRANSIT', 'ASSET', 'Tiền đang chuyển'),
    (p_owner, 'SYS_ADJUSTMENT_IN', 'INCOME', 'Điều chỉnh tăng'),
    (p_owner, 'SYS_ADJUSTMENT_OUT', 'EXPENSE', 'Điều chỉnh giảm'),
    (p_owner, 'SYS_BAD_DEBT', 'EXPENSE', 'Nợ xấu'),
    (p_owner, 'SYS_FEE_EXPENSE', 'EXPENSE', 'Phí chuyển khoản');
  for r in select * from (values
      ('EXPENSE','Ăn uống','restaurant'), ('EXPENSE','Di chuyển','directions_car'), ('EXPENSE','Nhà ở','home'),
      ('EXPENSE','Hóa đơn','receipt_long'), ('EXPENSE','Mua sắm','shopping_bag'), ('EXPENSE','Giải trí','sports_esports'),
      ('EXPENSE','Sức khỏe','favorite'), ('EXPENSE','Giáo dục','school'), ('EXPENSE','Khác','more_horiz'),
      ('INCOME','Lương','payments'), ('INCOME','Thưởng','redeem'), ('INCOME','Lãi','savings'), ('INCOME','Thu nhập khác','add_card')
    ) as t(type, name, icon) loop
    cid := gen_random_uuid(); lid := gen_random_uuid();
    insert into public.pf_ledger_account(id, owner_id, code, class, name) values (lid, p_owner, 'CAT_' || cid, r.type::public.pf_ledger_class, r.name);
    insert into public.pf_category(id, owner_id, type, name, ledger_account_id, icon) values (cid, p_owner, r.type, r.name, lid, r.icon);
  end loop;
end $$;

create function public.pf_setup_claim(p_user uuid, p_display_name text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare s public.pf_setup; o public.pf_owner; verified boolean;
begin
  select * into s from public.pf_setup where singleton = 1 for update;
  select * into o from public.pf_owner where singleton = 1;
  if s.state = 'BOUND' then
    if o.user_id = p_user then
      return jsonb_build_object('user_id', o.user_id, 'display_name', o.display_name, 'wizard_step', o.wizard_step, 'replayed', true);
    end if;
    perform pf_private.err('SETUP_ALREADY_BOUND');
  end if;
  if s.state <> 'INVITE_PENDING' or s.invite_user_id is distinct from p_user then perform pf_private.err('IDENTITY_CONFLICT'); end if;
  select (email_confirmed_at is not null) into verified from auth.users where id = p_user;
  if verified is not true then perform pf_private.err('INVITE_NOT_VERIFIED'); end if;
  insert into public.pf_owner(user_id, display_name) values (p_user, left(coalesce(p_display_name, ''), 80));
  insert into public.pf_settings(owner_id) values (p_user);
  perform pf_private.seed_owner(p_user);
  update public.pf_setup set state = 'BOUND', updated_at = now() where singleton = 1;
  insert into public.pf_audit(owner_id, actor, action, target_id) values (p_user, 'owner', 'SETUP_CLAIM', p_user);
  return jsonb_build_object('user_id', p_user, 'display_name', left(coalesce(p_display_name, ''), 80), 'wizard_step', 'W06', 'replayed', false);
end $$;

-- ---------------------------------------------------------------- device
create function public.pf_device_register(p_owner uuid, p_session uuid, p_device uuid, p_label text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare d public.pf_device;
begin
  perform pf_private.assert_owner(p_owner);
  select * into d from public.pf_device where id = p_device for update;
  if found then
    if d.owner_id <> p_owner then perform pf_private.err('IDENTITY_CONFLICT'); end if;
    update public.pf_device set session_id = p_session, label = left(p_label, 80), active = true, revoked_at = null,
      last_seen_at = now(), version = version + 1 where id = p_device returning * into d;
  else
    insert into public.pf_device(id, owner_id, label, session_id, last_seen_at) values (p_device, p_owner, left(p_label, 80), p_session, now()) returning * into d;
  end if;
  return jsonb_build_object('device_id', d.id, 'config_version', d.config_version, 'version', d.version);
end $$;

-- ---------------------------------------------------------------- command handlers (private)
create function pf_private.cmd_account_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare kind text := p->>'kind'; lid uuid := gen_random_uuid(); aid uuid := gen_random_uuid(); cls public.pf_ledger_class;
        opening bigint; tx uuid; eq uuid; base_known boolean := false; base_at timestamptz; seq bigint;
begin
  if kind not in ('BANK','WALLET','CASH','SAVINGS','CREDIT_CARD','OTHER') then perform pf_private.err('VALIDATION_FAILED'); end if;
  cls := case when kind = 'CREDIT_CARD' then 'LIABILITY' else 'ASSET' end;
  if p ? 'opening_amount' then
    opening := pf_private.parse_money(p->>'opening_amount', false);
    base_at := (p->>'baseline_at')::timestamptz; base_known := true;
  end if;
  insert into public.pf_ledger_account(id, owner_id, code, class, name) values (lid, p_owner, 'ACC_' || aid, cls, left(p->>'name', 120));
  insert into public.pf_account(id, owner_id, ledger_account_id, kind, institution, name, last4, baseline_at, baseline_known)
    values (aid, p_owner, lid, kind, left(p->>'institution', 40), left(p->>'name', 120), p->>'last4', base_at, base_known);
  if base_known and opening <> 0 then
    eq := pf_private.sys_ledger(p_owner, 'SYS_OPENING_EQUITY');
    tx := gen_random_uuid();
    insert into public.pf_tx(id, owner_id, kind, status, effective_at, account_id, amount, note)
      values (tx, p_owner, 'OPENING', 'DRAFT', base_at, aid, abs(opening), 'Số dư đầu kỳ');
    -- asset: debit +opening; liability: credit -opening (opening is outstanding positive). Equity is the counter-leg.
    perform pf_private.post_journal(p_owner, tx, base_at, 'ORIGINAL', jsonb_build_array(
      jsonb_build_object('ledger_account_id', lid, 'signed_amount', (case when cls = 'ASSET' then opening else -opening end)::text),
      jsonb_build_object('ledger_account_id', eq,  'signed_amount', (case when cls = 'ASSET' then -opening else opening end)::text)));
    update public.pf_tx set status = 'POSTED', current_journal_id = (select id from public.pf_journal where tx_id = tx), version = version + 1 where id = tx;
  end if;
  seq := pf_private.touch_change(p_owner, 'account', aid, 1);
  return jsonb_build_object('account_id', aid, 'change_seq', seq);
end $$;

create function pf_private.cmd_tx_create(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare kind text := p->>'kind'; amt bigint; fee bigint := 0; eff timestamptz := (p->>'effective_at')::timestamptz;
        acc public.pf_account; acc2 public.pf_account; cat public.pf_category; tx uuid := gen_random_uuid(); j uuid;
        lines jsonb; src_l uuid; seq bigint;
begin
  if kind in ('REFUND_EXPENSE','REFUND_INCOME') or p ? 'splits' then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  if kind not in ('INCOME','EXPENSE','TRANSFER','UNKNOWN_CREDIT','UNKNOWN_DEBIT') then perform pf_private.err('VALIDATION_FAILED'); end if;
  amt := pf_private.parse_money(p->>'amount');
  if p ? 'fee' then fee := pf_private.parse_money(p->>'fee'); end if;
  if fee > 0 and kind <> 'TRANSFER' then perform pf_private.err('VALIDATION_FAILED'); end if;
  -- lock accounts in UUID order
  perform 1 from public.pf_account where owner_id = p_owner and id in ((p->>'account_id')::uuid, nullif(p->>'to_account_id','')::uuid) order by id for update;
  select * into acc from public.pf_account where id = (p->>'account_id')::uuid and owner_id = p_owner;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if acc.archived then perform pf_private.err('ACCOUNT_ARCHIVED'); end if;
  if kind in ('INCOME','EXPENSE') then
    select * into cat from public.pf_category where id = nullif(p->>'category_id','')::uuid and owner_id = p_owner and not archived;
    if not found or cat.type <> kind then perform pf_private.err('CATEGORY_MISMATCH'); end if;
  end if;
  src_l := acc.ledger_account_id;
  if kind = 'INCOME' then
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', src_l, 'signed_amount', amt::text),
                               jsonb_build_object('ledger_account_id', cat.ledger_account_id, 'signed_amount', (-amt)::text));
  elsif kind = 'EXPENSE' then
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', src_l, 'signed_amount', (-amt)::text),
                               jsonb_build_object('ledger_account_id', cat.ledger_account_id, 'signed_amount', amt::text));
  elsif kind = 'UNKNOWN_CREDIT' then
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', src_l, 'signed_amount', amt::text),
                               jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_SUSPENSE_CREDIT'), 'signed_amount', (-amt)::text));
  elsif kind = 'UNKNOWN_DEBIT' then
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', src_l, 'signed_amount', (-amt)::text),
                               jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_SUSPENSE_DEBIT'), 'signed_amount', amt::text));
  else -- TRANSFER: principal + optional fee leaves source; no P&L except fee
    select * into acc2 from public.pf_account where id = nullif(p->>'to_account_id','')::uuid and owner_id = p_owner;
    if not found then perform pf_private.err('NOT_FOUND'); end if;
    if acc2.id = acc.id then perform pf_private.err('VALIDATION_FAILED'); end if;
    if acc2.archived then perform pf_private.err('ACCOUNT_ARCHIVED'); end if;
    lines := jsonb_build_array(jsonb_build_object('ledger_account_id', src_l, 'signed_amount', (-(amt + fee))::text),
                               jsonb_build_object('ledger_account_id', acc2.ledger_account_id, 'signed_amount', amt::text));
    if fee > 0 then
      lines := lines || jsonb_build_array(jsonb_build_object('ledger_account_id', pf_private.sys_ledger(p_owner, 'SYS_FEE_EXPENSE'), 'signed_amount', fee::text));
    end if;
  end if;
  insert into public.pf_tx(id, owner_id, kind, status, effective_at, note, merchant, contact_id, account_id, to_account_id, category_id, amount, fee)
    values (tx, p_owner, kind::public.pf_tx_kind, 'DRAFT', eff, left(p->>'note', 1000), left(p->>'merchant', 120),
            nullif(p->>'contact_id','')::uuid, acc.id, acc2.id, cat.id, amt, fee);
  j := pf_private.post_journal(p_owner, tx, eff, 'ORIGINAL', lines);
  update public.pf_tx set status = 'POSTED', current_journal_id = j, version = version + 1 where id = tx;
  seq := pf_private.touch_change(p_owner, 'transaction', tx, 2);
  return jsonb_build_object('tx_id', tx, 'journal_id', j, 'change_seq', seq);
end $$;

create function pf_private.cmd_tx_reverse(p_owner uuid, p jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, public as $$
declare t public.pf_tx; rj uuid; lines jsonb; seq bigint; reason text := coalesce(p->>'reason', '');
begin
  if length(btrim(reason)) = 0 then perform pf_private.err('REASON_REQUIRED'); end if;
  select * into t from public.pf_tx where id = (p->>'tx_id')::uuid and owner_id = p_owner for update;
  if not found then perform pf_private.err('NOT_FOUND'); end if;
  if t.version <> (p->>'expected_version')::integer then perform pf_private.err('VERSION_CONFLICT'); end if;
  if t.status <> 'POSTED' or t.current_journal_id is null then perform pf_private.err('INVALID_STATE'); end if;
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'signed_amount', (-signed_amount)::text, 'memo', 'Đảo bút toán') order by line_no)
    into lines from public.pf_entry where journal_id = t.current_journal_id;
  rj := pf_private.post_journal(p_owner, t.id, (select effective_at from public.pf_journal where id = t.current_journal_id), 'REVERSAL', lines, t.current_journal_id);
  update public.pf_tx set status = 'VOID', version = version + 1, updated_at = now() where id = t.id returning version into t.version;
  insert into public.pf_audit(owner_id, actor, action, target_id, after_safe) values (p_owner, 'owner', 'TX_REVERSE', t.id, jsonb_build_object('reason', left(reason, 200)));
  seq := pf_private.touch_change(p_owner, 'transaction', t.id, t.version);
  return jsonb_build_object('tx_id', t.id, 'reversal_journal_id', rj, 'change_seq', seq);
end $$;

-- ---------------------------------------------------------------- execute_command (idempotent)
create function public.pf_execute_command(p_owner uuid, p_session uuid, p_device uuid, p_command_id uuid, p_hash text, p_command jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.pf_command; ctype text := p_command->>'command_type'; payload jsonb := p_command->'payload'; res jsonb; d public.pf_device;
begin
  perform pf_private.assert_owner(p_owner);
  if p_device is not null then
    select * into d from public.pf_device where id = p_device and owner_id = p_owner;
    if not found or not d.active or d.revoked_at is not null or d.session_id is distinct from p_session then perform pf_private.err('DEVICE_REVOKED'); end if;
  end if;
  if (p_command->>'command_id')::uuid is distinct from p_command_id or (p_command->>'schema_version')::int <> 1 then perform pf_private.err('VALIDATION_FAILED'); end if;
  insert into public.pf_command(owner_id, command_id, request_hash) values (p_owner, p_command_id, p_hash) on conflict do nothing;
  select * into r from public.pf_command where owner_id = p_owner and command_id = p_command_id for update;
  if r.request_hash <> p_hash then perform pf_private.err('DUPLICATE_KEY_MISMATCH'); end if;
  if r.result is not null then return r.result || jsonb_build_object('status', 'REPLAYED'); end if;
  res := case ctype
    when 'ACCOUNT_CREATE' then pf_private.cmd_account_create(p_owner, payload)
    when 'TX_CREATE'      then pf_private.cmd_tx_create(p_owner, payload)
    when 'TX_REVERSE'     then pf_private.cmd_tx_reverse(p_owner, payload)
    else null end;
  if res is null then perform pf_private.err('NOT_IMPLEMENTED'); end if;
  res := res || jsonb_build_object('status', 'COMMITTED');
  update public.pf_command set result = res where owner_id = p_owner and command_id = p_command_id;
  return res;
end $$;

-- ---------------------------------------------------------------- read models
create function public.pf_read_accounts(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'kind', a.kind, 'institution', a.institution, 'name', a.name, 'last4', a.last4, 'archived', a.archived, 'version', a.version,
      'balance', case when a.baseline_known then (case when b.class = 'ASSET' then b.debit_net else -b.debit_net end)::text end,
      'baseline_known', a.baseline_known) order by a.created_at)
    from public.pf_account a join pf_private.ledger_balance b on b.id = a.ledger_account_id where a.owner_id = p_owner and not a.archived), '[]'::jsonb);
end $$;

create function public.pf_read_categories(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'type', type, 'name', name, 'icon', icon, 'parent_id', parent_id) order by type, name)
    from public.pf_category where owner_id = p_owner and not archived), '[]'::jsonb);
end $$;

create function public.pf_read_transactions(p_owner uuid, p_limit integer, p_before_at timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform pf_private.assert_owner(p_owner);
  return coalesce((select jsonb_agg(row_to_json(x)::jsonb order by x.effective_at desc, x.id desc) from (
    select t.id, t.kind, t.status, t.effective_at, t.amount::text as amount, t.fee::text as fee, t.account_id, t.to_account_id, t.category_id,
           t.merchant, t.note, t.version
    from public.pf_tx t
    where t.owner_id = p_owner and t.status in ('POSTED','VOID')
      and (p_before_at is null or (t.effective_at, t.id) < (p_before_at, p_before_id))
    order by t.effective_at desc, t.id desc limit lim) x), '[]'::jsonb);
end $$;

-- Dashboard: half-open [from, to) already converted from Asia/Ho_Chi_Minh by the API. Excludes SYS_* ledger accounts.
create function public.pf_read_dashboard(p_owner uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare income numeric; expense numeric; assets numeric; liabilities numeric; unknown_n integer; by_cat jsonb;
begin
  perform pf_private.assert_owner(p_owner);
  select coalesce(-sum(e.signed_amount::numeric) filter (where a.class = 'INCOME'), 0),
         coalesce(sum(e.signed_amount::numeric) filter (where a.class = 'EXPENSE'), 0)
    into income, expense
    from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
    join public.pf_ledger_account a on a.id = e.ledger_account_id
   where j.owner_id = p_owner and j.effective_at >= p_from and j.effective_at < p_to and a.code not like 'SYS\_%' escape '\';
  select coalesce(sum(b.debit_net) filter (where b.class = 'ASSET'), 0), coalesce(-sum(b.debit_net) filter (where b.class = 'LIABILITY'), 0)
    into assets, liabilities
    from public.pf_account a join pf_private.ledger_balance b on b.id = a.ledger_account_id
   where a.owner_id = p_owner and a.baseline_known and not a.archived;
  select count(*) into unknown_n from public.pf_account where owner_id = p_owner and not baseline_known and not archived;
  select coalesce(jsonb_agg(jsonb_build_object('category_id', c.id, 'name', c.name, 'icon', c.icon, 'amount', s.total::text) order by s.total desc), '[]'::jsonb) into by_cat
    from (select a.id as lid, sum(e.signed_amount::numeric) as total
            from public.pf_entry e join public.pf_journal j on j.id = e.journal_id and j.posted
            join public.pf_ledger_account a on a.id = e.ledger_account_id and a.class = 'EXPENSE' and a.code not like 'SYS\_%' escape '\'
           where j.owner_id = p_owner and j.effective_at >= p_from and j.effective_at < p_to group by a.id having sum(e.signed_amount::numeric) <> 0) s
    join public.pf_category c on c.ledger_account_id = s.lid;
  return jsonb_build_object('income', income::text, 'expense', expense::text, 'net_worth', (assets - liabilities)::text,
    'accounts_unknown_baseline', unknown_n, 'expense_by_category', by_cat);
end $$;

-- Worker-side owner binding + public setup state (no secrets).
create function public.pf_get_owner() returns uuid
language sql stable security definer set search_path = pg_catalog, public as $$ select user_id from public.pf_owner where singleton = 1 $$;
create function public.pf_get_setup_state() returns text
language sql stable security definer set search_path = pg_catalog, public as $$ select state from public.pf_setup where singleton = 1 $$;
create function public.pf_read_profile(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare o public.pf_owner;
begin
  select * into o from public.pf_owner where user_id = p_owner;
  if not found then perform pf_private.err('OWNER_NOT_BOUND'); end if;
  return jsonb_build_object('user_id', o.user_id, 'display_name', o.display_name, 'locale', o.locale, 'timezone', o.timezone, 'wizard_step', o.wizard_step, 'version', o.version);
end $$;

-- ---------------------------------------------------------------- grants: server role only
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'pf\_%' escape '\' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on all functions in schema pf_private from public, anon, authenticated, service_role;
grant usage on schema pf_private to postgres;

commit;
