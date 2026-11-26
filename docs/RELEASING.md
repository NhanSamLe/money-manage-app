# Quy trình phát hành

## Đánh số phiên bản

[Semantic Versioning](https://semver.org/lang/vi/) `MAJOR.MINOR.PATCH`. Số gốc ở file `VERSION`; các nơi sau phải **trùng khớp** (CI chạy `node scripts/check-versions.mjs`):

| Nơi | Giá trị |
|---|---|
| `VERSION` | `0.1.0` |
| `apps/api/package.json` | `"version": "0.1.0"` |
| `apps/api/src/shared/version.ts` | `API_VERSION = "0.1.0"` |
| `apps/android/pubspec.yaml` | `version: 0.1.0+<buildNumber>` |

- `MAJOR`: thay đổi phá vỡ hợp đồng API hoặc cần migration không tương thích ngược.
- `MINOR`: thêm tính năng tương thích ngược.
- `PATCH`: sửa lỗi.
- Android `buildNumber` (sau dấu `+`) tăng **mỗi lần** build phát hành; không được giảm (Android từ chối hạ phiên bản).
- API công khai có tiền tố `/v1`; thay đổi phá vỡ phải ra `/v2`.

## Các bước phát hành

1. Mọi thay đổi đã vào `dev` và CI xanh.
2. Cập nhật `VERSION`, `package.json`, `version.ts`, `pubspec.yaml`; chạy `node scripts/check-versions.mjs`.
3. Chuyển mục `[Unreleased]` trong `CHANGELOG.md` thành phiên bản mới kèm ngày.
4. Kiểm tra migration trên một cơ sở dữ liệu dùng thử (không phải bản thật) và chạy `supabase/tests`.
5. Merge vào `main`, gắn thẻ: `git tag -a vX.Y.Z -m "MoMa vX.Y.Z"`.
6. Triển khai API: `cd apps/api && npx wrangler deploy`.
7. Áp dụng migration mới lên Supabase (sao lưu trước).
8. Build APK phát hành đã ký (mục dưới) và lưu cùng giá trị SHA-256.

Không phát hành, không đổi gói trả phí và không chạy migration trên dữ liệu thật khi chưa có xác nhận của chủ sở hữu.

## Ký APK phát hành

Khóa ký nằm **ngoài repository** (mất khóa = không cập nhật được app đã cài; lộ khóa = có thể giả mạo bản cập nhật). Sao lưu khóa ở nơi an toàn, ngoại tuyến.

```bash
# Tạo khóa một lần (giữ mật khẩu ở trình quản lý mật khẩu)
keytool -genkeypair -v -keystore moma-release.jks -alias moma \
  -keyalg RSA -keysize 4096 -validity 10000
```

Tạo `apps/android/android/key.properties` (đã nằm trong `.gitignore`):

```properties
storeFile=<đường dẫn tuyệt đối tới moma-release.jks>
storePassword=...
keyAlias=moma
keyPassword=...
```

Build: `cd apps/android && flutter build apk --release` hoặc `flutter build appbundle --release`. Nếu thiếu `key.properties`, build phát hành sẽ **thất bại có chủ đích** (không dùng khóa debug).

## Định danh ứng dụng

Application ID: `vn.moma.app` (cố định sau khi có bản cài thực tế; đổi ID tạo ra một ứng dụng khác). Tên hiển thị: **MoMa**.
