import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';

/// Android Keystore-backed storage for device identity and API base URL.
class LocalStore {
  LocalStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  Future<String> apiBase() async =>
      await _s.read(key: 'api_base') ?? AppConfig.defaultApiBase;
  Future<void> setApiBase(String v) =>
      _s.write(key: 'api_base', value: v.replaceAll(RegExp(r'/+$'), ''));

  /// Appearance: 'system' (default), 'light' or 'dark'.
  Future<String> themeMode() async =>
      await _s.read(key: 'theme_mode') ?? 'system';
  Future<void> setThemeMode(String v) => _s.write(key: 'theme_mode', value: v);

  /// Whether the first-run introduction slides were already shown on this device.
  Future<bool> introSeen() async => await _s.read(key: 'intro_seen') == '1';
  Future<void> setIntroSeen() => _s.write(key: 'intro_seen', value: '1');

  Future<String> deviceId() async {
    final existing = await _s.read(key: 'device_id');
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await _s.write(key: 'device_id', value: id);
    return id;
  }
}
