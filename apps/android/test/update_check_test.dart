import 'package:flutter_test/flutter_test.dart';
import 'package:moma/features/update/update_check.dart';

Map<String, dynamic> _release({
  String tag = 'v0.2.0+5',
  String body = '',
  bool prerelease = false,
  List<Map<String, dynamic>>? assets,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': prerelease,
  'body': body,
  'html_url': 'https://github.com/NhanSamLe/money-manage-app/releases/tag/$tag',
  'assets':
      assets ??
      [
        {
          'name': 'MoMa-0.2.0+5.apk',
          'size': 1234,
          'browser_download_url': 'https://github.com/x/MoMa-0.2.0.5.apk',
        },
      ],
};

void main() {
  test('parseReleaseTag', () {
    expect(parseReleaseTag('v0.2.0+5'), (versionName: '0.2.0', build: 5));
    expect(parseReleaseTag('1.10.3+120'), (versionName: '1.10.3', build: 120));
    expect(parseReleaseTag('v0.2.0'), isNull);
    expect(parseReleaseTag('latest'), isNull);
  });

  test('fromGitHub picks the APK asset and compares builds', () {
    final r = ReleaseInfo.fromGitHub(
      _release(
        assets: [
          {
            'name': 'checksums.txt',
            'size': 10,
            'browser_download_url': 'https://github.com/x/checksums.txt',
          },
          {
            'name': 'other.apk',
            'size': 1,
            'browser_download_url': 'https://github.com/x/other.apk',
          },
          {
            'name': 'MoMa-0.2.0+5.apk',
            'size': 1234,
            'browser_download_url': 'https://github.com/x/MoMa.apk',
          },
        ],
      ),
    )!;
    expect(r.versionName, '0.2.0');
    expect(r.build, 5);
    expect(r.apkUrl, 'https://github.com/x/MoMa.apk');
    expect(r.apkSize, 1234);
    expect(isNewerBuild(r, '4'), isTrue);
    expect(isNewerBuild(r, '5'), isFalse);
    expect(isNewerBuild(r, '6'), isFalse);
    expect(isNewerBuild(r, ''), isFalse);
  });

  test('unusable releases are ignored', () {
    expect(ReleaseInfo.fromGitHub(_release(prerelease: true)), isNull);
    expect(ReleaseInfo.fromGitHub(_release(tag: 'v0.2.0')), isNull);
    expect(ReleaseInfo.fromGitHub(_release(assets: [])), isNull);
  });

  test('stripMarkdown keeps readable text', () {
    const md =
        '## Có gì mới\r\n\r\n'
        '* **Xuất dữ liệu** ra Excel\r\n'
        '- Sửa lỗi `ngân sách` ([#12](https://github.com/x/pull/12))\r\n\r\n\r\n'
        '> Ghi chú: *cần* cập nhật\r\n'
        '---\r\n'
        '![logo](https://x/logo.png)';
    expect(
      stripMarkdown(md),
      'Có gì mới\n\n'
      '- Xuất dữ liệu ra Excel\n'
      '- Sửa lỗi ngân sách (#12)\n\n'
      'Ghi chú: cần cập nhật\n\n'
      'logo',
    );
  });
}
