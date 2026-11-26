## Thay đổi
<!-- Làm gì và vì sao. -->

## Requirement / test liên quan
<!-- ID trong spec/tests/traceability.json, ví dụ FIN-01. -->

## Đã chạy (ghi đúng lệnh và kết quả thật)
- [ ] `node scripts/check-versions.mjs`
- [ ] `cd apps/api && npm run typecheck && npm test`
- [ ] `bash scripts/db-test.sh` (nếu đổi migration/RPC)
- [ ] `cd apps/android && flutter analyze && flutter test`

## Tác động dữ liệu và an toàn
- [ ] Có migration mới (không sửa migration cũ)
- [ ] Không thêm secret/khóa vào repo
- [ ] Đã cập nhật `CHANGELOG.md`, `IMPLEMENTATION_STATUS.md`
- [ ] Đổi hợp đồng API/lệnh: đã tăng phiên bản và cập nhật `spec/contracts`

## Rủi ro và cách hoàn tác
