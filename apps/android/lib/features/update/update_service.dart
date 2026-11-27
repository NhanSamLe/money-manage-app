import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'update_check.dart';

const _latestUrl =
    'https://api.github.com/repos/NhanSamLe/money-manage-app/releases/latest';
const _lastCheckKey = 'update_last_check_ms';
const autoCheckInterval = Duration(hours: 12);

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of a check: [release] is set only when it is newer than the installed build.
class UpdateStatus {
  const UpdateStatus({required this.installed, this.release});
  final PackageInfo installed;
  final ReleaseInfo? release;
}

enum InstallOutcome { started, needsPermission, failed }

/// GitHub Releases based self-update: check, download the APK into the app cache, hand it to the installer.
class UpdateService {
  UpdateService({http.Client? client, FlutterSecureStorage? storage})
    : _http = client ?? http.Client(),
      _store = storage ?? const FlutterSecureStorage();

  final http.Client _http;
  final FlutterSecureStorage _store;
  static const _channel = MethodChannel('moma/updater');

  /// True when the automatic check (Home) is due: at most once per [autoCheckInterval].
  Future<bool> autoCheckDue() async {
    try {
      final raw = await _store.read(key: _lastCheckKey);
      final last = int.tryParse(raw ?? '');
      if (last == null) return true;
      final at = DateTime.fromMillisecondsSinceEpoch(last);
      return DateTime.now().difference(at) >= autoCheckInterval ||
          DateTime.now().isBefore(at); // clock moved back
    } catch (_) {
      return true;
    }
  }

  Future<void> _markChecked() async {
    try {
      await _store.write(
        key: _lastCheckKey,
        value: '${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (_) {}
  }

  /// Asks GitHub for the latest release. Unauthenticated (60 requests/hour per IP).
  Future<UpdateStatus> check() async {
    final info = await PackageInfo.fromPlatform();
    http.Response res;
    try {
      res = await _http
          .get(
            Uri.parse(_latestUrl),
            headers: const {
              'accept': 'application/vnd.github+json',
              'x-github-api-version': '2022-11-28',
              'user-agent': 'MoMa-Android',
            },
          )
          .timeout(const Duration(seconds: 15));
    } on Exception {
      throw UpdateException(
        'Không kết nối được máy chủ cập nhật. Hãy kiểm tra mạng và thử lại.',
      );
    }
    await _markChecked();
    if (res.statusCode == 404) return UpdateStatus(installed: info);
    final limited =
        res.statusCode == 429 ||
        (res.statusCode == 403 && res.headers['x-ratelimit-remaining'] == '0');
    if (limited) {
      throw UpdateException(
        'Máy chủ cập nhật đang giới hạn số lần kiểm tra. Bạn thử lại sau khoảng một giờ nhé.',
      );
    }
    if (res.statusCode != 200) {
      throw UpdateException(
        'Không kiểm tra được bản cập nhật (mã ${res.statusCode}).',
      );
    }
    final ReleaseInfo? release;
    try {
      release = ReleaseInfo.fromGitHub(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw UpdateException('Thông tin bản cập nhật không hợp lệ.');
    }
    if (release == null || !isNewerBuild(release, info.buildNumber)) {
      return UpdateStatus(installed: info);
    }
    return UpdateStatus(installed: info, release: release);
  }

  /// Streams the APK into `<cache>/updates/`, reporting progress 0..1 (null while the size is unknown).
  Future<File> download(
    ReleaseInfo r, {
    void Function(double? progress)? onProgress,
  }) async {
    final dirPath = await _channel.invokeMethod<String>('updateDir');
    if (dirPath == null) throw UpdateException('Không tìm thấy thư mục tạm.');
    final dir = Directory(dirPath);
    if (dir.existsSync()) {
      for (final f in dir.listSync()) {
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    } else {
      dir.createSync(recursive: true);
    }
    final file = File('${dir.path}/MoMa-${r.versionName}-${r.build}.apk');
    final req = http.Request('GET', Uri.parse(r.apkUrl))
      ..headers['user-agent'] = 'MoMa-Android';
    final http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(const Duration(seconds: 30));
    } on Exception {
      throw UpdateException('Không tải được bản cập nhật. Hãy kiểm tra mạng.');
    }
    if (res.statusCode != 200) {
      throw UpdateException(
        'Không tải được bản cập nhật (mã ${res.statusCode}).',
      );
    }
    final total = res.contentLength ?? (r.apkSize > 0 ? r.apkSize : null);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream.timeout(
        const Duration(seconds: 60),
      )) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total == null || total <= 0 ? null : received / total);
      }
      await sink.flush();
    } on Exception {
      await sink.close();
      try {
        file.deleteSync();
      } catch (_) {}
      throw UpdateException('Tải bản cập nhật bị gián đoạn. Bạn thử lại nhé.');
    }
    await sink.close();
    if (r.apkSize > 0 && received != r.apkSize) {
      try {
        file.deleteSync();
      } catch (_) {}
      throw UpdateException('File tải về không đầy đủ. Bạn thử lại nhé.');
    }
    return file;
  }

  /// Opens the system installer for [apk]. Android checks package name and signature itself.
  Future<InstallOutcome> install(File apk) async {
    try {
      final r = await _channel.invokeMethod<String>('install', {
        'path': apk.path,
      });
      return switch (r) {
        'started' => InstallOutcome.started,
        'needs_permission' => InstallOutcome.needsPermission,
        _ => InstallOutcome.failed,
      };
    } on PlatformException {
      return InstallOutcome.failed;
    } on MissingPluginException {
      return InstallOutcome.failed;
    }
  }

  /// "Cài ứng dụng không rõ nguồn gốc" settings page for MoMa.
  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<bool>('openInstallSettings');
    } catch (_) {}
  }
}
