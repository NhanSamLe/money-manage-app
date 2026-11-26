import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/api_client.dart';

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

  /// Step 1 of first-time setup: the deployment secret makes the server send the owner invite.
  Future<void> startSetup(String bootstrapSecret) async {
    try {
      await _api.post(
        '/setup/start',
        <String, dynamic>{},
        extraHeaders: {'x-bootstrap-secret': bootstrapSecret},
      );
    } on ApiException catch (e) {
      // The server answers UNAUTHENTICATED for a wrong deployment secret; say what the user actually got wrong.
      if (e.code == 'UNAUTHENTICATED') {
        throw ApiException('BAD_SECRET', 'Mã bí mật triển khai không đúng.');
      }
      if (e.code == 'SETUP_ALREADY_BOUND') {
        throw ApiException(
          'SETUP_ALREADY_BOUND',
          'Ứng dụng đã có chủ sở hữu. Hãy chọn "Tôi đã có tài khoản".',
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

  Future<void> signOut() => _auth.signOut();
}
