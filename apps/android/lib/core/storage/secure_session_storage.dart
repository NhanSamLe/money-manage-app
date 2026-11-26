import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stores the Supabase session in the Android Keystore instead of plain SharedPreferences.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage() : _s = const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'sb_session';

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => (await _s.read(key: _key)) != null;

  @override
  Future<String?> accessToken() => _s.read(key: _key);

  @override
  Future<void> removePersistedSession() => _s.delete(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _s.write(key: _key, value: persistSessionString);
}
