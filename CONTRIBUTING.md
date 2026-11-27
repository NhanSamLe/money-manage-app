# Đóng góp

MoMa là sản phẩm cá nhân của một chủ sở hữu, mã nguồn công khai để tham khảo (xem [`LICENSE`](LICENSE)). Báo lỗi và góp ý
qua [Issues](https://github.com/NhanSamLe/money-manage-app/issues) luôn được hoan nghênh. Pull request chỉ được nhận khi đã
thống nhất trước trong issue; khi gửi, bạn đồng ý chuyển quyền sử dụng phần đóng góp cho chủ sở hữu theo giấy phép hiện hành.
Lỗ hổng bảo mật: báo riêng theo [`SECURITY.md`](SECURITY.md), không mở issue.

## Trước khi sửa code

Đọc [`AGENTS.md`](AGENTS.md), [`spec/README.md`](spec/README.md), [`spec/docs/11-engineering-standards.md`](spec/docs/11-engineering-standards.md)
và [`docs/architecture.md`](docs/architecture.md). Các tài liệu đó có tính bắt buộc.

## Quy tắc chính

- **Tiền**: số nguyên VND (`bigint` SQL/TypeScript, `int` Dart, chuỗi số trên JSON). Không dùng số thực.
- **Sổ cái**: chỉ ghi qua RPC trong `supabase/migrations`; bút toán bất biến, sửa bằng đảo bút toán.
- **Migration**: chỉ thêm file mới `YYYYMMDDHHMMSS_tên.sql`, không sửa file đã áp dụng.
- **Kiến trúc**: không đặt nghiệp vụ trong route hay widget; hợp đồng `spec/contracts/*` đổi thì tăng phiên bản.
- **Commit**: [Conventional Commits](https://www.conventionalcommits.org/) (`feat(api): …`, `fix(app): …`, `docs: …`), nhỏ, một mục đích.
- **Giao diện**: theo [`docs/UX-STANDARD.md`](docs/UX-STANDARD.md); văn bản hiển thị bằng tiếng Việt.

## Kiểm tra trước khi mở pull request

```bash
node scripts/check-versions.mjs
cd apps/api && npm run typecheck && npm test && npm run test:e2e
cd apps/android && dart format lib test && flutter analyze --fatal-infos && flutter test
PGHOST=localhost PGPORT=54329 PGUSER=postgres PGPASSWORD=local bash scripts/db-test.sh
```

Mô tả pull request gồm: thay đổi gì, vì sao, lệnh đã **thực sự chạy** và kết quả, tác động dữ liệu/migration. Không ghi
"đã test" khi chưa chạy. Thay đổi giao diện thì kèm ảnh chụp (có thể tạo bằng `test/screenshots`, xem README).

Phát hành chỉ do chủ sở hữu thực hiện: [`docs/RELEASE.md`](docs/RELEASE.md).
