-- PostgreSQL/Supabase baseline v1. Apply in a fresh development project first.
-- Core schema and ledger invariant, not full business RPC implementation.
begin;
create schema if not exists pf_private;
revoke all on schema pf_private from public, anon, authenticated;
create domain public.pf_money as bigint check (value between -9000000000000000 and 9000000000000000);
create domain public.pf_positive as bigint check (value between 1 and 9000000000000000);
create type public.pf_ledger_class as enum ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE','CLEARING');
create type public.pf_tx_kind as enum ('OPENING','INCOME','EXPENSE','TRANSFER','REFUND_EXPENSE','REFUND_INCOME','UNKNOWN_CREDIT','UNKNOWN_DEBIT','LOAN_GIVEN','LOAN_RECEIVED','LOAN_COLLECTED','LOAN_REPAID','DEBT_WRITEOFF','DEBT_FORGIVEN','ADJUSTMENT','SPLIT');
create type public.pf_source as enum ('API','NOTIFICATION','STATEMENT','MANUAL');
create table public.pf_setup (
 singleton smallint primary key default 1 check(singleton=1), state text not null check(state in ('UNINITIALIZED','INVITE_PENDING','BOUND')),
 invite_user_id uuid references auth.users(id), lease_id uuid, lease_expires_at timestamptz, updated_at timestamptz not null default now()
);
insert into public.pf_setup(state) values('UNINITIALIZED');
create table public.pf_owner (
 singleton smallint primary key default 1 check(singleton=1), user_id uuid not null unique references auth.users(id),
 display_name text not null default '', locale text not null default 'vi-VN', timezone text not null default 'Asia/Ho_Chi_Minh',
 wizard_step text not null default 'W06', session_epoch bigint not null default 1 check(session_epoch>0), created_at timestamptz not null default now(), version integer not null default 1
);
create table public.pf_device (
 id uuid primary key, owner_id uuid not null references public.pf_owner(user_id), label text not null, session_id uuid not null,
 active boolean not null default true, config_version bigint not null default 1, last_seen_at timestamptz, revoked_at timestamptz, version integer not null default 1, created_at timestamptz not null default now()
);
create table public.pf_device_source (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), device_id uuid not null references public.pf_device(id), account_id uuid not null, package_name text not null, signing_digest text, enabled boolean not null default false, version integer not null default 1, unique(device_id,account_id,package_name)
);
create table public.pf_settings (
 owner_id uuid primary key references public.pf_owner(user_id), api_global boolean not null default false, notification_global boolean not null default false,
 ai_mode text not null default 'OFF' check(ai_mode in ('OFF','FREE','PAID')), ai_cap_micro_usd bigint not null default 1000000 check(ai_cap_micro_usd>=0),
 preferences jsonb not null default '{}', version integer not null default 1
);
create table public.pf_ledger_account (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), code text not null,
 class public.pf_ledger_class not null, name text not null, currency char(3) not null default 'VND' check(currency='VND'), archived boolean not null default false,
 unique(owner_id,code), version integer not null default 1
);
create table public.pf_account (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), ledger_account_id uuid not null unique references public.pf_ledger_account(id),
 kind text not null check(kind in ('BANK','WALLET','CASH','SAVINGS','CREDIT_CARD','OTHER')), institution text not null, name text not null,
 last4 text check(last4 ~ '^[0-9]{4}$'), baseline_at timestamptz, baseline_known boolean not null default false,
 api_enabled boolean not null default false, notification_enabled boolean not null default false, api_epoch bigint not null default 1, notification_epoch bigint not null default 1,
 archived boolean not null default false, hidden boolean not null default false, version integer not null default 1, created_at timestamptz not null default now(),
 check(not baseline_known or baseline_at is not null)
);
alter table public.pf_device_source add constraint pf_device_source_account_fk foreign key(account_id) references public.pf_account(id);
create table public.pf_category (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), parent_id uuid references public.pf_category(id),
 type text not null check(type in ('INCOME','EXPENSE')), name text not null, ledger_account_id uuid not null unique references public.pf_ledger_account(id), archived boolean not null default false, icon text, version integer not null default 1, check(parent_id is distinct from id)
);
create table public.pf_contact (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), alias text not null, note text, archived boolean not null default false, version integer not null default 1
);
create table public.pf_tx (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), kind public.pf_tx_kind not null,
 status text not null check(status in ('DRAFT','POSTED','VOID','MERGED')), effective_at timestamptz not null, time_precision text not null default 'SECOND' check(time_precision in ('DAY','MINUTE','SECOND')),
 note text, merchant text, contact_id uuid references public.pf_contact(id), related_tx_id uuid references public.pf_tx(id), merged_into_id uuid references public.pf_tx(id),
 current_journal_id uuid, provisional boolean not null default false, version integer not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check(related_tx_id is distinct from id), check(merged_into_id is distinct from id)
);
create table public.pf_journal (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), tx_id uuid not null references public.pf_tx(id),
 purpose text not null check(purpose in ('ORIGINAL','REVERSAL','REPLACEMENT')), reversal_of uuid unique references public.pf_journal(id),
 effective_at timestamptz not null, posted boolean not null default false, created_at timestamptz not null default now(),
 check((purpose='REVERSAL')=(reversal_of is not null)), check(reversal_of is distinct from id)
);
alter table public.pf_tx add constraint pf_tx_current_journal_fk foreign key(current_journal_id) references public.pf_journal(id) deferrable initially deferred;
create table public.pf_entry (
 journal_id uuid not null references public.pf_journal(id), line_no smallint not null check(line_no>0), ledger_account_id uuid not null references public.pf_ledger_account(id),
 signed_amount public.pf_money not null check(signed_amount<>0), memo text, primary key(journal_id,line_no)
);
create index pf_entry_ledger_idx on public.pf_entry(ledger_account_id,journal_id);
create index pf_tx_time_idx on public.pf_tx(owner_id,effective_at desc,id);
create index pf_journal_tx_idx on public.pf_journal(tx_id,effective_at);
create table public.pf_connection (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), account_id uuid not null references public.pf_account(id), provider text not null,
 external_account_alias text not null, enabled boolean not null default false, epoch bigint not null default 1, capability jsonb not null default '{}',
 health text not null default 'UNVERIFIED' check(health in ('ACTIVE','DEGRADED','PAUSED','AUTH_REQUIRED','UNVERIFIED','UNSUPPORTED','BILLING_BLOCKED','OFFLINE','ERROR')), billing_state text not null default 'UNKNOWN' check(billing_state in ('UNKNOWN','SAFE','BLOCKED')), upstream_status text not null default 'UNKNOWN' check(upstream_status in ('UNKNOWN','ACTIVE','PAUSED','DISCONNECTED')), cursor text, last_success_at timestamptz, version integer not null default 1, unique(owner_id,provider,external_account_alias)
);
create table public.pf_source_event (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), source public.pf_source not null, account_id uuid references public.pf_account(id),
 connection_id uuid references public.pf_connection(id), device_id uuid references public.pf_device(id), delivery_id text not null, external_id text,
 epoch bigint not null, amount public.pf_positive, direction text check(direction in ('CREDIT','DEBIT')), currency char(3) not null default 'VND' check(currency='VND'),
 occurred_at timestamptz, received_at timestamptz not null default now(), reference_hash text, counterparty_alias text, description text, balance_after public.pf_money,
 settlement text not null check(settlement in ('SETTLED','PENDING','FAILED','UNKNOWN')), evidence_quality text not null check(evidence_quality in ('VERIFIED','PROVISIONAL','UNKNOWN')),
 parser_version text not null, content_hash text not null, sanitized_payload jsonb not null default '{}', state text not null default 'RECEIVED' check(state in ('RECEIVED','VALIDATED','NORMALIZED','MATCHED','NEEDS_REVIEW','POSTED','LINKED','IGNORED','FAILED_RETRY','DEAD_LETTER')),
 version integer not null default 1, check(source<>'API' or connection_id is not null), check(source<>'NOTIFICATION' or device_id is not null)
);
create unique index pf_event_external_uq on public.pf_source_event(connection_id,external_id) where external_id is not null;
create unique index pf_event_delivery_uq on public.pf_source_event(connection_id,delivery_id) where connection_id is not null;
create unique index pf_event_device_uq on public.pf_source_event(device_id,delivery_id) where device_id is not null;
create index pf_event_match_idx on public.pf_source_event(account_id,direction,amount,occurred_at);
create table public.pf_event_revision (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references public.pf_source_event(id), content_hash text not null, normalized jsonb not null, received_at timestamptz not null default now(), unique(event_id,content_hash)
);
create table public.pf_event_link (
 event_id uuid primary key references public.pf_source_event(id), tx_id uuid not null references public.pf_tx(id), role text not null check(role in ('PRIMARY','CORROBORATION','TRANSFER_LEG','MANUAL_MATCH')), created_at timestamptz not null default now()
);
create table public.pf_balance_snapshot (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), account_id uuid not null references public.pf_account(id),
 as_of timestamptz not null, amount public.pf_money not null, basis text not null check(basis in ('BOOKED','AVAILABLE','UNKNOWN')), source public.pf_source not null, verified boolean not null default false, event_id uuid references public.pf_source_event(id)
);
create index pf_snapshot_latest_idx on public.pf_balance_snapshot(account_id,as_of desc);
create table public.pf_review (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), event_id uuid references public.pf_source_event(id), tx_id uuid references public.pf_tx(id),
 type text not null, reason text not null, candidates jsonb not null default '[]', state text not null default 'OPEN' check(state in ('OPEN','RESOLVED','DEFERRED')), resolution jsonb,
 version integer not null default 1, created_at timestamptz not null default now(), resolved_at timestamptz
);
create table public.pf_reconciliation (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), account_id uuid not null references public.pf_account(id), snapshot_id uuid references public.pf_balance_snapshot(id),
 calculated_amount public.pf_money, difference public.pf_money, status text not null check(status in ('MATCHED','MISMATCH','INCOMPARABLE','UNKNOWN')), created_at timestamptz not null default now()
);
create table public.pf_debt (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), contact_id uuid not null references public.pf_contact(id), ledger_account_id uuid not null unique references public.pf_ledger_account(id),
 direction text not null check(direction in ('RECEIVABLE','PAYABLE')), principal public.pf_positive not null, originated_at timestamptz not null, due_date date, origin_tx_id uuid not null references public.pf_tx(id),
 state text not null default 'OPEN' check(state in ('OPEN','PARTIAL','SETTLED','WRITTEN_OFF')), note text, version integer not null default 1
);
create index pf_debt_due_idx on public.pf_debt(owner_id,state,due_date);
create table public.pf_debt_payment (
 id uuid primary key default gen_random_uuid(), debt_id uuid not null references public.pf_debt(id), tx_id uuid not null references public.pf_tx(id), principal public.pf_positive not null, interest public.pf_money not null default 0 check(interest>=0),
 kind text not null check(kind in ('REPAYMENT','WRITEOFF','REVERSAL')), reversal_of uuid unique references public.pf_debt_payment(id), unique(debt_id,tx_id,kind)
);
create table public.pf_goal (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), name text not null, target public.pf_positive not null, due_date date,
 state text not null default 'ACTIVE' check(state in ('ACTIVE','COMPLETED','ARCHIVED')), version integer not null default 1
);
create table public.pf_allocation (
 id uuid primary key default gen_random_uuid(), goal_id uuid not null references public.pf_goal(id), account_id uuid not null references public.pf_account(id), signed_amount public.pf_money not null check(signed_amount<>0),
 reason text, reversal_of uuid unique references public.pf_allocation(id), created_at timestamptz not null default now()
);
create index pf_alloc_account_idx on public.pf_allocation(account_id,goal_id);
create table public.pf_budget (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), month date not null check(extract(day from month)=1), category_id uuid references public.pf_category(id),
 limit_amount public.pf_positive not null, carryover boolean not null default false, version integer not null default 1, unique nulls not distinct(owner_id,month,category_id)
);
create table public.pf_recurring (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), name text not null, kind text not null check(kind in ('INCOME','EXPENSE','TRANSFER')), account_id uuid not null references public.pf_account(id),
 amount public.pf_positive not null, interval text not null check(interval in ('WEEKLY','MONTHLY','YEARLY')), next_date date not null, template jsonb not null default '{}', enabled boolean not null default true, version integer not null default 1
);
create table public.pf_occurrence (
 id uuid primary key default gen_random_uuid(), recurring_id uuid not null references public.pf_recurring(id), due_date date not null, matched_tx_id uuid unique references public.pf_tx(id), state text not null default 'EXPECTED' check(state in ('EXPECTED','MATCHED','SKIPPED')), version integer not null default 1, unique(recurring_id,due_date)
);
create table public.pf_rule (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), priority integer not null, matcher jsonb not null, result jsonb not null, enabled boolean not null default true, version integer not null default 1
);
create table public.pf_ai_proposal (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), payload jsonb not null, model text, prompt_version text not null, state text not null default 'PENDING' check(state in ('PENDING','ACCEPTED','DISMISSED','EXPIRED')),
 expires_at timestamptz not null, expected_version integer, created_at timestamptz not null default now()
);
create table public.pf_ai_usage (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), period date not null check(extract(day from period)=1), provider text not null, model text not null,
 reserved_micro_usd bigint not null check(reserved_micro_usd>=0), spent_micro_usd bigint not null default 0 check(spent_micro_usd>=0), state text not null check(state in ('RESERVED','SETTLED','UNKNOWN_CHARGE','RELEASED')), created_at timestamptz not null default now()
);
create index pf_ai_usage_period_idx on public.pf_ai_usage(owner_id,period,state);
create table public.pf_job (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), type text not null, job_key text not null unique, state text not null default 'QUEUED' check(state in ('QUEUED','RUNNING','RETRY','DONE','DEAD')),
 due_at timestamptz not null default now(), lease_until timestamptz, lease_token uuid, attempts integer not null default 0, payload jsonb not null default '{}', last_error_code text
);
create index pf_job_due_idx on public.pf_job(state,due_at);
create table public.pf_rate_limit (
 bucket_hash text not null, window_start timestamptz not null, count integer not null default 0 check(count>=0), expires_at timestamptz not null, primary key(bucket_hash,window_start)
);
create table public.pf_command (
 owner_id uuid not null references public.pf_owner(user_id), command_id uuid not null, request_hash text not null, result jsonb, created_at timestamptz not null default now(), primary key(owner_id,command_id)
);
create table public.pf_change (
 seq bigint generated always as identity primary key, owner_id uuid not null references public.pf_owner(user_id), entity text not null, entity_id uuid not null, version integer not null, op text not null check(op in ('UPSERT','DELETE')), created_at timestamptz not null default now()
);
create index pf_change_owner_seq on public.pf_change(owner_id,seq);
create table public.pf_audit (
 id bigint generated always as identity primary key, owner_id uuid not null references public.pf_owner(user_id), actor text not null, action text not null, target_id uuid, before_safe jsonb, after_safe jsonb, created_at timestamptz not null default now()
);
create table public.pf_attachment (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), tx_id uuid references public.pf_tx(id), object_key text not null unique, mime text not null, size_bytes integer not null check(size_bytes between 1 and 2097152), sha256 text not null, created_at timestamptz not null default now()
);
create table public.pf_reminder (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), kind text not null, target_id uuid not null, due_at timestamptz not null, enabled boolean not null default true, state text not null default 'PENDING', version integer not null default 1
);
create table public.pf_tag(id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), name text not null, unique(owner_id,name));
create table public.pf_tx_tag(tx_id uuid not null references public.pf_tx(id), tag_id uuid not null references public.pf_tag(id), primary key(tx_id,tag_id));
create table public.pf_import(id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.pf_owner(user_id), account_id uuid not null references public.pf_account(id), state text not null default 'PREVIEW', expires_at timestamptz not null, created_at timestamptz not null default now());
create table public.pf_import_row(id uuid primary key default gen_random_uuid(), import_id uuid not null references public.pf_import(id), row_no integer not null, content_hash text not null, normalized jsonb not null, state text not null default 'PREVIEW', event_id uuid references public.pf_source_event(id), unique(import_id,row_no));
-- Journal immutability: no direct insert as posted; entries only while draft.
create function pf_private.journal_guard() returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
 if tg_op='INSERT' then
   if new.posted then raise exception 'JOURNAL_MUST_START_DRAFT'; end if; return new;
 end if;
 if old.posted then raise exception 'JOURNAL_IMMUTABLE'; end if;
 if tg_op='DELETE' then return old; end if;
 if new.posted then
   if (select count(*) from public.pf_entry where journal_id=new.id)<2 or (select coalesce(sum(signed_amount::numeric),0) from public.pf_entry where journal_id=new.id)<>0 then raise exception 'UNBALANCED_JOURNAL'; end if;
   if exists(select 1 from public.pf_entry e join public.pf_ledger_account a on a.id=e.ledger_account_id where e.journal_id=new.id and (a.owner_id<>new.owner_id or a.currency<>'VND')) then raise exception 'LEDGER_ACCOUNT_MISMATCH'; end if;
   if not exists(select 1 from public.pf_tx t where t.id=new.tx_id and t.owner_id=new.owner_id) then raise exception 'TX_OWNER_MISMATCH'; end if;
   if new.reversal_of is not null then
     if not exists(select 1 from public.pf_journal j where j.id=new.reversal_of and j.posted and j.tx_id=new.tx_id and j.owner_id=new.owner_id and j.purpose<>'REVERSAL' and j.effective_at=new.effective_at) then raise exception 'INVALID_REVERSAL'; end if;
     if exists(select ledger_account_id from public.pf_entry where journal_id in(new.id,new.reversal_of) group by ledger_account_id having sum(signed_amount::numeric)<>0) then raise exception 'INVALID_REVERSAL_AMOUNT'; end if;
   end if;
 end if;
 return new;
end $$;
create trigger pf_journal_guard before insert or update or delete on public.pf_journal for each row execute function pf_private.journal_guard();
create function pf_private.entry_guard() returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare jid uuid; is_posted boolean;
begin
 if tg_op='UPDATE' then raise exception 'ENTRY_UPDATE_FORBIDDEN'; end if;
 jid:=case when tg_op='DELETE' then old.journal_id else new.journal_id end;
 select posted into is_posted from public.pf_journal where id=jid for update;
 if not found or is_posted then raise exception 'ENTRY_IMMUTABLE'; end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger pf_entry_guard before insert or update or delete on public.pf_entry for each row execute function pf_private.entry_guard();
-- Private primitive for subsequent SECURITY DEFINER command RPCs only.
-- Must be called in same transaction as domain validation, idempotency, current projection and audit.
create function pf_private.post_journal(p_owner uuid,p_tx uuid,p_effective_at timestamptz,p_purpose text,p_lines jsonb,p_reversal_of uuid default null)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare j uuid; n integer; total numeric;
begin
 if not exists(select 1 from public.pf_owner where user_id=p_owner) then raise exception 'NOT_OWNER'; end if;
 perform 1 from public.pf_tx where id=p_tx and owner_id=p_owner for update;
 if not found then raise exception 'TX_NOT_FOUND'; end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 2 and 100 then raise exception 'INVALID_LINES'; end if;
 select count(*),sum((x->>'signed_amount')::numeric) into n,total from jsonb_array_elements(p_lines) x;
 if total is distinct from 0::numeric then raise exception 'UNBALANCED_JOURNAL'; end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x where (x->>'signed_amount') is null or (x->>'signed_amount') !~ '^-?[0-9]+$') then raise exception 'INVALID_MONEY'; end if;
 perform a.id from public.pf_ledger_account a where a.id in(select (x->>'ledger_account_id')::uuid from jsonb_array_elements(p_lines) x) order by a.id for update;
 insert into public.pf_journal(owner_id,tx_id,purpose,reversal_of,effective_at) values(p_owner,p_tx,p_purpose,p_reversal_of,p_effective_at) returning id into j;
 insert into public.pf_entry(journal_id,line_no,ledger_account_id,signed_amount,memo)
 select j,ord::smallint,(v->>'ledger_account_id')::uuid,(v->>'signed_amount')::bigint,v->>'memo' from jsonb_array_elements(p_lines) with ordinality as q(v,ord);
 update public.pf_journal set posted=true where id=j;
 return j;
end $$;
-- Read models; monetary amounts cast to decimal text at wire boundary.
create view pf_private.ledger_balance as select a.id,a.owner_id,a.class,coalesce(sum(e.signed_amount::numeric) filter(where j.posted),0) as debit_net
from public.pf_ledger_account a left join public.pf_entry e on e.ledger_account_id=a.id left join public.pf_journal j on j.id=e.journal_id group by a.id,a.owner_id,a.class;
-- All tables are server-only, RLS enabled with no anon/authenticated policy.
do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' and tablename like 'pf\_%' escape '\' loop
  execute format('alter table public.%I enable row level security',t.tablename);
  execute format('revoke all on table public.%I from public,anon,authenticated',t.tablename);
  execute format('grant select,insert,update,delete on table public.%I to service_role',t.tablename);
 end loop;
end $$;
revoke all on all functions in schema pf_private from public,anon,authenticated,service_role;
revoke all on all tables in schema pf_private from public,anon,authenticated,service_role;
-- No direct service-role ledger DML; subsequent domain RPC SECURITY DEFINER owned by migration role.
revoke insert,update,delete,truncate on public.pf_journal,public.pf_entry,public.pf_tx,public.pf_ledger_account,public.pf_account,public.pf_debt,public.pf_debt_payment,public.pf_allocation,public.pf_goal,public.pf_command,public.pf_event_link,public.pf_change from service_role;
-- All mutation of the above requires later narrowly scoped server-only RPCs.
-- Baseline intentionally exposes no production write endpoint until those RPCs are tested.
revoke update,delete,truncate on public.pf_audit from service_role;
-- Sequence grants scoped to pf_* only.
do $$ declare s record; begin
 for s in select sequencename from pg_sequences where schemaname='public' and sequencename like 'pf\_%' escape '\' loop
  execute format('revoke all on sequence public.%I from public,anon,authenticated',s.sequencename);
  execute format('grant usage,select on sequence public.%I to service_role',s.sequencename);
 end loop;
end $$;
commit;
