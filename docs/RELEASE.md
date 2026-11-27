# Phát hành APK qua GitHub Releases

Bản cài Android được phát hành dưới dạng **GitHub Release** của repo `NhanSamLe/money-manage-app`. Ứng dụng tự kiểm tra bản mới (khi mở Trang chủ, tối đa 12 giờ một lần, và từ Cài đặt > "Kiểm tra cập nhật"), tải APK và mở trình cài đặt của Android. Quy trình ký APK và các bước chung: xem `RELEASING.md`.

## Quy tắc đánh số phiên bản

- Mỗi lần phát hành **luôn** có phiên bản mới. Định dạng `X.Y.Z+N` trong `apps/android/pubspec.yaml`.
- Giai đoạn trước phát hành chính thức: `0.MINOR.PATCH`. Bản công khai hoàn chỉnh đầu tiên là `1.0.0`.
- Có tính năng mới: tăng `MINOR` (`0.2.0` -> `0.3.0`). Chỉ sửa lỗi: tăng `PATCH` (`0.2.0` -> `0.2.1`).
- Số build `+N` luôn tăng đúng 1 mỗi lần phát hành và **không bao giờ đặt lại** (app dựa vào số này để biết có bản mới; Android không cho hạ `versionCode`).
- Tag: `v<X.Y.Z>+<N>` (ví dụ `v0.2.0+2`), tệp đính kèm: `MoMa-<X.Y.Z>+<N>.apk`.

## Chạy script

Cần: `flutter`, `gh` (đã `gh auth login`), `git`, `android/key.properties` (khóa ký phát hành).

```powershell
# Windows
scripts\release.ps1 minor                                 # 0.1.0+1 -> 0.2.0+2
scripts\release.ps1 patch -Notes "Sửa lỗi ngân sách"
scripts\release.ps1 0.3.0 -NotesFile notes.md
scripts\release.ps1 minor -DryRun                         # chỉ kiểm tra + build, không phát hành
```

```bash
# Git Bash / Linux (dùng GNU sed)
scripts/release.sh minor
scripts/release.sh patch --notes "Sửa lỗi ngân sách"
scripts/release.sh 0.3.0 --notes-file notes.md
scripts/release.sh minor --dry-run
```

Script làm theo thứ tự và **dừng, không phát hành** nếu một bước thất bại:

1. Cây git phải sạch (không có thay đổi chưa commit).
2. Tính phiên bản mới; từ chối nếu tag `v<X.Y.Z>+<N>`, bất kỳ tag nào của cùng `X.Y.Z`, hoặc GitHub Release đó đã tồn tại.
3. Chạy `flutter analyze` và `flutter test` trong `apps/android`.
4. Cập nhật phiên bản ở `VERSION`, `apps/api/package.json`, `apps/api/src/shared/version.ts`, `apps/android/pubspec.yaml` và chạy `scripts/check-versions.mjs`.
5. `flutter build apk --release --target-platform android-arm64`, chép ra `dist/MoMa-<X.Y.Z>+<N>.apk` (in SHA-256).
6. Commit `release: MoMa X.Y.Z+N`, push nhánh hiện tại, rồi `gh release create v<X.Y.Z>+<N> <apk> --notes-file ...` trỏ vào commit đó.

Lỗi ở bước 4-5 sẽ khôi phục các file phiên bản. `-DryRun`/`--dry-run` dừng sau bước 5 và khôi phục file.

Ghi chú phát hành: lấy từ `-Notes`/`--notes` hoặc `-NotesFile`/`--notes-file`; nếu không có, script tự tạo danh sách commit kể từ tag gần nhất. Ghi chú hiển thị trong app (đã bỏ ký hiệu markdown), nên viết ngắn, bằng tiếng Việt.

## Lưu ý

- APK phải được ký bằng **cùng khóa** với bản đang cài; nếu khác, Android từ chối cài đè.
- API GitHub không xác thực giới hạn 60 lần/giờ cho mỗi IP; app bỏ qua lỗi này khi tự kiểm tra và báo người dùng khi kiểm tra thủ công.
- Không đánh dấu release là pre-release/draft nếu muốn app nhận được: app chỉ đọc `releases/latest`.
