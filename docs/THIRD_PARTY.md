# Thành phần bên thứ ba

Giấy phép của MoMa là độc quyền (xem `LICENSE`); các thư viện bên thứ ba giữ nguyên giấy phép riêng.

## Tạo báo cáo giấy phép

```bash
# API (Node)
cd apps/api && npx --yes license-checker --production --summary

# Ứng dụng (Dart/Flutter): giấy phép hiển thị trong app tại Cài đặt → Giấy phép (LicenseRegistry),
# hoặc liệt kê phụ thuộc:
cd apps/android && flutter pub deps --style=compact
```

## Quy tắc chọn phụ thuộc

- Chỉ dùng gói được bảo trì, giấy phép tương thích (MIT, BSD, Apache-2.0, ISC). Không dùng GPL/AGPL nếu chưa có ADR.
- Ghim phiên bản bằng lockfile (`package-lock.json`, `pubspec.lock`); không tự nâng major.
- Ghi lý do khi thêm phụ thuộc mới vào pull request.
