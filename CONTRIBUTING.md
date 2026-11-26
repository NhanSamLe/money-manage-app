# Hướng dẫn đóng góp và quy trình làm việc

Đọc `AGENTS.md`, `spec/README.md` và `spec/docs/11-engineering-standards.md` trước khi sửa code. Các tài liệu đó có tính bắt buộc.

## Nhánh và commit

- Nhánh: `main` (ổn định, gắn thẻ phát hành), `dev` (tích hợp), `feature/<mô-tả>`, `fix/<mô-tả>`.
- Commit theo [Conventional Commits](https://www.conventionalcommits.org/): `feat(api): ...`, `fix(db): ...`, `docs: ...`, `chore: ...`, `test: ...`.
- Mỗi commit nhỏ, một mục đích. Không commit secret, `.env`, keystore.

## Quy tắc code

- **Tiền**: số nguyên VND; `bigint` trong SQL/TypeScript, `int` trong Dart; truyền qua JSON dạng chuỗi số. Không dùng số thực cho tiền.
- **Sổ cái**: chỉ ghi qua RPC trong `supabase/migrations`. Bút toán đã ghi là bất biến, sửa bằng đảo bút toán rồi ghi lại.
- **Kiến trúc**: presentation → application → domain; hạ tầng cài đặt các port (xem `spec/docs/11-engineering-standards.md` mục 2). Không có logic nghiệp vụ trong route/widget.
- **Migration**: chỉ thêm file mới (`YYYYMMDDHHMMSS_tên.sql`), không sửa file đã áp dụng lên môi trường thật.
- **Hợp đồng**: thay đổi `spec/contracts/*` phải tăng phiên bản và cập nhật `CHANGELOG.md`.

## Trước khi mở pull request

```bash
node scripts/check-versions.mjs          # phiên bản đồng bộ
cd apps/api && npm run typecheck && npm test
cd apps/android && flutter analyze && flutter test
```

Pull request cần: mô tả thay đổi, requirement/test liên quan, kết quả lệnh đã **thực sự chạy**, tác động dữ liệu/migration, và cập nhật `IMPLEMENTATION_STATUS.md`. Không ghi "đã test" khi chưa chạy.

## Phát hành

Xem `docs/RELEASING.md`.
