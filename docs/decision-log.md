# Decision log

| ID | Date | Decision | Why |
|---|---|---|---|
| D-001 | 2026-11-27 | Brand MoMa (MoneyManage). Repo `moma/` with spec copied to `spec/` unchanged. | Owner request; spec requires repo layout in docs/11 section 2. |
| D-002 | 2026-11-27 | Owner decision: write code first, run tests later (single-user app). Nothing is reported as tested until actually run. | Owner instruction overrides the test-first workflow in docs/11 section 6. Release gates in docs/11 section 5 still apply before any production use. |
| D-003 | 2026-11-27 | Additive columns on `pf_tx` (amount, account_id, to_account_id, category_id, fee) as RPC-written projections; journal stays the financial truth. | Needed for transaction list without re-deriving from journal lines. |
| D-004 | 2026-11-27 | Extra system ledger account `SYS_FEE_EXPENSE` for transfer fees (BR-15). | Not in the reserved list of docs/12; spec change to report/confirm. |
| D-005 | 2026-11-27 | API validates only implemented commands (ACCOUNT_CREATE, TX_CREATE w/o splits/refunds, TX_REVERSE); others return NOT_IMPLEMENTED. | No fake success (AGENTS.md). |
| D-006 | 2026-11-27 | TX_CORRECT voids the old transaction and creates a NEW linked one (`related_tx_id`) instead of keeping the same id. | Spec wants the same id only to preserve source-event links; none exist before Gate 3. Revisit then. |
| D-007 | 2026-11-27 | Offline outbox stores whole commands with a fixed `command_id` in Keystore-backed secure storage; rejected commands stay visible until the owner discards them. | F04 "no silent data loss"; idempotency makes retries safe. |
| D-008 | 2026-11-27 | JWT verification supports legacy HS256 only when `SUPABASE_JWT_SECRET` is set; default is JWKS (asymmetric). | New Supabase projects use JWKS; older ones may not. |
| D-009 | 2026-11-27 | CSV import = client-side parse + one idempotent TX_CREATE per row with a deterministic command id (account + file fingerprint + row). | Gives re-import safety without new server tables; cross-source dedup stays in Gate 3. |
| D-010 | 2026-11-27 | Dashboard counts transfer fees, bad debt and interest as classified income/expense; only SYS_ADJUSTMENT_* is excluded. | docs/03 BR-15, BR-19, section 7. |


## D-011 — Hiển thị lỗi: hộp thoại cho lỗi hệ thống, inline cho validate
Chủ sở hữu yêu cầu: lỗi từ máy chủ/mạng/không mong đợi hiện bằng hộp thoại modal (`showErrorDialog`); chỉ lỗi kiểm tra dữ liệu nhập (thiếu số tiền, mật khẩu < 8 ký tự…) hiện inline cạnh form. Thông báo thành công/thông tin dùng SnackBar.

## D-012 — Đăng ký bằng email chủ sở hữu + mã qua thư, bỏ khóa triển khai
Chủ sở hữu yêu cầu luồng đăng ký/đăng nhập thông thường. `POST /v1/setup/start` chỉ nhận `OWNER_EMAIL`; quyền kiểm soát hộp thư (mã dùng một lần) chứng minh danh tính. `BOOTSTRAP_SECRET` không còn dùng. Lệch có chủ đích so với spec 02 (bootstrap bằng khóa triển khai); đổi lại dễ dùng hơn.

## D-013 — Trợ lý AI chỉ đề xuất
DeepSeek `deepseek-flash` qua Worker (khóa chỉ ở Worker). AI trả đề xuất đã kiểm tra id/số tiền/ngày; chủ sở hữu bấm Xác nhận thì lệnh `TX_CREATE` idempotent mới ghi. Chặn chi phí theo spec 05 mục 5 (đặt trước chi phí xấu nhất, trần 1 USD/tháng).

## D-014 — Nhắc việc thông minh và phân tích chi tiêu (migration 008)
- Cron Worker 15 phút (`scheduled()`) + dự phòng `POST /v1/internal/tick` (header `x-cron-secret` = secret `CRON_SECRET`, gọi từ GitHub Actions `moma-tick.yml`) vì tài khoản Cloudflare chưa đăng ký được cron. Mỗi push được "claim" một lần trong `pf_push_log` nên gọi trùng vô hại.
- Bữa ăn "đã ghi" = có khoản chi POSTED thuộc danh mục "Ăn uống" (theo tên hoặc icon `restaurant`) hoặc danh mục con, trong khung giờ địa phương (sáng 04:00–10:30, trưa 10:30–15:00, tối 15:00–23:00). Nhắc bữa ăn/kiểm tra tiền mặt chỉ gửi trong 3 giờ sau giờ hẹn; cảnh báo ngân sách chỉ 07:00–22:00.
- Số liệu phân tích do SQL/TS tính; AI (DeepSeek, qua trần chi phí) chỉ viết lời; tắt/hết hạn mức thì dùng văn bản theo luật. Mức chi đề xuất = trung vị các kỳ gần nhất (4 tuần / 3 tháng / 14 ngày, bỏ kỳ không ghi chép), kéo một nửa về mục tiêu ngân sách nếu cao hơn, làm tròn lên 10.000 đ. So sánh với kỳ trước cùng số ngày đã trôi qua.

## D-015 — Bỏ trần chi phí AI theo tháng
Chủ sở hữu quyết định không giới hạn chi phí AI. `MONTHLY_CAP_MICRO` đặt rất lớn (không chặn thực tế); mỗi lần gọi vẫn ghi lại chi phí trong `pf_ai_usage`. Thay thế mức trần 1 USD/tháng ở D-013.

## D-016 — Đánh phiên bản mỗi bản phát hành
Mỗi bản phát hành có phiên bản mới theo SemVer. Trước bản phát hành hoàn chỉnh dùng 0.MINOR.PATCH (MINOR khi có tính năng mới, PATCH khi chỉ sửa lỗi); bản hoàn chỉnh đầu tiên là 1.0.0. Số build (+N) luôn tăng 1, không đặt lại. Không phát hành khi phiên bản/tag đã tồn tại, cây git chưa sạch, hoặc analyze/test chưa đạt. Bản kế tiếp: 0.2.0+2.

## D-017 — Khóa ứng dụng
Khóa khi mở lại sau khi app bị tắt hẳn, hoặc khi quay lại sau thời gian ở nền vượt mức chọn (15 phút / 30 phút mặc định / 1 giờ / 2 giờ). Sai PIN 5 lần thì chờ cố định 10 giây. Back ở màn hình gốc đưa app xuống nền thay vì đóng.

## D-018 — Tự ghép chuyển tiền giữa tài khoản của chủ sở hữu (migration 010)
Tiền ra ở một tài khoản + tiền vào ở tài khoản khác của chủ sở hữu, đúng cùng số tiền, cách nhau ≤ 15 phút, ít nhất một chiều từ BANK/NOTIFICATION, không gắn công nợ/định kỳ → một giao dịch TRANSFER. Duy nhất và đủ mạnh (≤ 5 phút, hoặc ≤ 15 phút kèm gợi ý nội dung: từ khóa ví/chuyển tiền, tên chủ sở hữu, tên ngân hàng/4 số cuối tài khoản kia) → tự ghép (AUTO): đảo hai giao dịch gốc (giữ lịch sử), ghi một TRANSFER qua code sổ cái thường. Nhiều ứng viên hoặc khớp yếu → chỉ đề xuất (SUGGESTED), chủ sở hữu chọn Đúng/Không; Không thì không bao giờ đề xuất lại cặp đó. Cùng mã tham chiếu ngân hàng (FT…, token chữ+số ≥ 10 ký tự) ở hai chiều → chắc chắn, tự ghép dù cách tới 24 giờ. Chỉ một chiều (ví dụ MoMo không báo tiền ra) mà nội dung nêu tên chủ sở hữu + đúng một tài khoản khác của mình (tiền vào), hoặc nêu đúng một ví của mình (tiền ra), và hết 15 phút vẫn không có chiều kia → lượt đối soát định kỳ ghi TRANSFER với chiều còn thiếu được tạo ra; chiều đó đến muộn thì được gộp vào, không tính hai lần. "Tách ra" hoàn tác mọi kiểu ghép. Hook sau sự kiện ngân hàng APPLIED và TX_CREATE nguồn NOTIFICATION (không bao giờ làm hỏng lệnh gốc); cron quét lại 48 giờ.
