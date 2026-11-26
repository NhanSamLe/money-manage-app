# MoMa Android

Ứng dụng Flutter cho MoMa. Giao diện chỉ thu thập ý định và hiển thị trạng thái; quy tắc tài chính nằm ở máy chủ/cơ sở dữ liệu.

- Application ID: `vn.moma.app` (bản debug: `vn.moma.app.debug`). Tên hiển thị: **MoMa**.
- Phiên bản: `version:` trong `pubspec.yaml` (`MAJOR.MINOR.PATCH+BUILD`), đồng bộ với `/VERSION`.
- Yêu cầu: Flutter 3.50+, Dart 3.14+, JDK 21, Android SDK 36.
- Quản lý trạng thái: Riverpod; điều hướng: go_router; xác thực: Supabase Auth, phiên lưu trong Android Keystore.

## Cấu trúc

```
lib/app/        # theme (màu thương hiệu), router
lib/core/       # config công khai, network (ApiClient), storage (Keystore), money, models, providers
lib/features/   # auth, home, dashboard, transactions, accounts, settings
test/           # unit/widget test
```

## Lệnh

```bash
flutter pub get
dart format lib test
flutter analyze --fatal-infos
flutter test
flutter build apk --debug      # file: build/app/outputs/flutter-apk/app-debug.apk
```

Bản phát hành đã ký: xem [`docs/RELEASING.md`](../../docs/RELEASING.md). Build `--release` **thất bại có chủ đích** nếu thiếu `android/key.properties`.

## Quy ước

- Tiền là `int` VND; truyền qua JSON dạng chuỗi; chỉ định dạng ở lớp hiển thị (`formatVnd`).
- Số dư chưa biết hiển thị "Chưa biết", không bao giờ là 0.
- Mỗi biểu mẫu ghi dữ liệu giữ một `command_id` cố định, để gửi lại sau mất kết nối không ghi trùng.
- Không đặt secret/service-role key trong ứng dụng. Chỉ dùng publishable key.
- Manifest: `allowBackup=false`, `usesCleartextTraffic=false`; quyền duy nhất hiện tại là `INTERNET`. Không xin quyền SMS hay Accessibility.

## Chưa có

Thông báo ngân hàng (NotificationListener), kho lệnh offline, wizard đầy đủ W00–W13, công nợ, tiết kiệm, ngân sách, báo cáo nâng cao, AI. Xem `IMPLEMENTATION_STATUS.md`.
