-- MoMa: XÓA TOÀN BỘ DỮ LIỆU THỬ NGHIỆM của chủ sở hữu, giữ lại tài khoản đăng nhập.
-- Chạy MỘT lần trong Supabase SQL Editor khi muốn thiết lập lại từ đầu. KHÔNG hoàn tác được.
--
-- Giữ lại: tài khoản đăng nhập (auth), chủ sở hữu (pf_owner: tên hiển thị), thiết lập ban đầu (pf_setup),
--          thiết bị đã đăng ký (pf_device), cài đặt (pf_settings), cài đặt nhắc nhở (pf_reminder_settings),
--          lịch sử chi phí AI (pf_ai_usage).
-- Xóa: tài khoản tiền, giao dịch, sổ cái, danh mục, công nợ, người liên hệ, ngân sách, mục tiêu, định kỳ,
--      liên kết ngân hàng SePay, sự kiện ngân hàng, phân tích, ghi nhớ của Trợ lý, nhật ký lệnh/đồng bộ,
--      hộp thông báo, cặp chuyển khoản nội bộ, ảnh chứng từ (chỉ dòng dữ liệu; ảnh trên R2 không bị ảnh hưởng)...
-- Sau khi xóa: tạo lại danh mục mặc định và tài khoản sổ cái hệ thống (như lúc mới đăng ký).
-- Sau khi chạy: mở app, kéo xuống để làm mới; app tự mở các bước thiết lập ban đầu. Liên kết lại TPBank
-- trong Cài đặt → Kết nối ngân hàng.
begin;

-- Bỏ qua trigger bảo vệ sổ cái (chỉ cho phép ghi thêm) và kiểm tra khóa ngoại trong giao dịch này.
set local session_replication_role = replica;

do $$
declare
  o uuid;
  t text;
  n bigint;
  -- Every owner-scoped table to wipe (tables from later migrations are skipped if they don't exist yet).
  owned text[] := array[
    'pf_tx_tag', 'pf_tag', 'pf_event_link', 'pf_event_revision', 'pf_source_event', 'pf_inbound_event',
    'pf_account_link', 'pf_connection', 'pf_device_source', 'pf_import_row', 'pf_import', 'pf_attachment',
    'pf_reconciliation', 'pf_balance_snapshot', 'pf_review', 'pf_reminder', 'pf_reminder_skip', 'pf_push_log',
    'pf_insight', 'pf_ai_memory', 'pf_ai_proposal', 'pf_rule', 'pf_job', 'pf_change', 'pf_command', 'pf_audit',
    'pf_notification', 'pf_transfer_pair', 'pf_tx_attachment',
    'pf_tx', 'pf_journal', 'pf_debt', 'pf_contact', 'pf_goal', 'pf_budget', 'pf_recurring',
    'pf_account', 'pf_category', 'pf_ledger_account'];
begin
  select count(*) into n from public.pf_owner;
  if n <> 1 then raise exception 'Cần đúng 1 chủ sở hữu, đang có %', n; end if;
  select user_id into o from public.pf_owner;

  -- Child tables without owner_id: delete through their parents first.
  delete from public.pf_entry where journal_id in (select id from public.pf_journal where owner_id = o);
  get diagnostics n = row_count; raise notice 'pf_entry: % dòng', n;
  delete from public.pf_debt_payment where debt_id in (select id from public.pf_debt where owner_id = o);
  get diagnostics n = row_count; raise notice 'pf_debt_payment: % dòng', n;
  delete from public.pf_allocation where goal_id in (select id from public.pf_goal where owner_id = o);
  get diagnostics n = row_count; raise notice 'pf_allocation: % dòng', n;
  delete from public.pf_occurrence where recurring_id in (select id from public.pf_recurring where owner_id = o);
  get diagnostics n = row_count; raise notice 'pf_occurrence: % dòng', n;
  if to_regclass('public.pf_event_revision') is not null then
    delete from public.pf_event_revision where event_id in (select id from public.pf_source_event where owner_id = o);
  end if;
  if to_regclass('public.pf_event_link') is not null then
    delete from public.pf_event_link where event_id in (select id from public.pf_source_event where owner_id = o);
  end if;

  foreach t in array owned loop
    if to_regclass('public.' || t) is null then continue; end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t and column_name = 'owner_id') then continue; end if;
    execute format('delete from public.%I where owner_id = $1', t) using o;
    get diagnostics n = row_count;
    raise notice '%: % dòng', t, n;
  end loop;

  -- Fresh default categories + system ledger accounts, exactly like a new sign-up.
  perform pf_private.seed_owner(o);
  raise notice 'Đã tạo lại danh mục mặc định cho chủ sở hữu %', o;
end $$;

commit;
