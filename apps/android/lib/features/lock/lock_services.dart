import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../auth/auth_service.dart';
import 'pin_hasher.dart';

/// Key-value store for the lock settings (Android Keystore in the app, in-memory in tests).
abstract class LockStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureLockStorage implements LockStorage {
  SecureLockStorage([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Fingerprint / face unlock, behind an interface so tests can fake it.
abstract class BiometricAuth {
  /// Hardware present and at least one fingerprint / face enrolled.
  Future<bool> isAvailable();

  /// Shows the system prompt. False when cancelled or failed.
  Future<bool> authenticate(String reason);
}

class LocalAuthBiometric implements BiometricAuth {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        authMessages: const [
          AndroidAuthMessages(
            signInTitle: 'Mở khóa MoMa',
            signInHint: 'Xác thực bằng vân tay hoặc khuôn mặt',
            cancelButton: 'Dùng mã PIN',
          ),
        ],
      );
    } on Object {
      return false;
    }
  }
}

/// FLAG_SECURE on the main window (blank thumbnail in recents). No-op where the channel is missing.
class SecureWindow {
  const SecureWindow();
  static const _channel = MethodChannel('moma/secure');
  Future<void> set(bool on) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'on': on});
    } on Object {
      // Other activities / tests: nothing to do.
    }
  }
}

final lockStorageProvider = Provider<LockStorage>((_) => SecureLockStorage());
final biometricProvider = Provider<BiometricAuth>((_) => LocalAuthBiometric());
final pinHasherProvider = Provider<PinHasher>((_) => const PinHasher());
final secureWindowProvider = Provider<SecureWindow>(
  (_) => const SecureWindow(),
);
final lockClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Whether someone is signed in (the lock only guards a signed-in app).
final lockSignedInProvider = Provider<bool Function()>(
  (_) => () {
    try {
      return Supabase.instance.client.auth.currentSession != null;
    } on Object {
      return false;
    }
  },
);

/// Sign-out used by "Quên mã PIN?".
final lockSignOutProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => AuthService(ref.read(apiProvider)).signOut(),
);
