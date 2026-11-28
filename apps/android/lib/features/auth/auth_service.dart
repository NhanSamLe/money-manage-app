import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/offline_cache.dart';
import '../transactions/tx_attachments.dart' show AttachmentFiles;

/// Auth glue between Supabase Auth (credentials live there) and the MoMa API (owner + device binding).
class AuthService {
  AuthService(this._api);
  final ApiClient _api;
  final _auth = Supabase.instance.client.auth;

  Future<void> signIn(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email.trim(), password: password);
    } on AuthException {
      throw ApiException('BAD_CREDENTIALS', 'Email hoặc mật khẩu không đúng.');
    }
    try {
      await registerDevice();
    } on ApiException {
      await _auth.signOut();
      rethrow;
    }
  }

  /// Step 1 of sign-up: the server mails a one-time code, but only for the configured owner email.
  Future<void> startSignup(String email) async {
    try {
      await _api.post('/setup/start', <String, dynamic>{'email': email.trim()});
    } on ApiException catch (e) {
      if (e.code == 'SETUP_ALREADY_BOUND') {
        throw ApiException(
          'SETUP_ALREADY_BOUND',
          'Ứng dụng đã có tài khoản. Hãy chọn "Đăng nhập".',
        );
      }
      rethrow;
    }
  }

  /// Step 2: verify the emailed code, set the password, bind the owner and register this device.
  Future<void> completeSetup({
    required String email,
    required String code,
    required String password,
    required String displayName,
  }) async {
    try {
      await _auth.verifyOTP(
        email: email.trim(),
        token: code.trim(),
        type: OtpType.invite,
      );
      await _auth.updateUser(UserAttributes(password: password));
    } on AuthException {
      throw ApiException('BAD_CODE', 'Mã xác nhận không đúng hoặc đã hết hạn.');
    }
    await _api.post('/setup/claim', {'display_name': displayName.trim()});
    await registerDevice();
  }

  Future<void> registerDevice() async {
    final id = await _api.deviceIdForRegistration();
    await _api.post('/devices/register', {'device_id': id, 'label': 'Android'});
  }

  /// Signs out and forgets every copy kept for offline use (cached reads, viewed pictures, queued pictures).
  Future<void> signOut() async {
    await _auth.signOut();
    await clearOfflineData();
  }
}

/// Wipes the offline cache and picture files (sign-out, or "Xóa bộ nhớ đệm" with [queue] false).
Future<void> clearOfflineData({bool queue = true}) async {
  await OfflineCache.instance.clear();
  await AttachmentFiles.instance.clear(queue: queue);
}
