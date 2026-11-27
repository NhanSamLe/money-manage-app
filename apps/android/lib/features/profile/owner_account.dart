import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../auth/auth_service.dart';

/// Sign-in facts and credential actions the profile page needs, behind a seam so widget tests can fake them.
abstract class OwnerAccount {
  String? get email;

  /// When the sign-in account was created (ISO 8601), if known.
  String? get createdAt;

  /// Verifies [current] by signing in again, then sets [next]. Throws [ApiException] with a short message.
  Future<void> changePassword({required String current, required String next});

  Future<void> signOut();
}

class SupabaseOwnerAccount implements OwnerAccount {
  SupabaseOwnerAccount(this._api);
  final ApiClient _api;
  GoTrueClient get _auth => Supabase.instance.client.auth;

  @override
  String? get email => _auth.currentUser?.email;

  @override
  String? get createdAt => _auth.currentUser?.createdAt;

  @override
  Future<void> changePassword({
    required String current,
    required String next,
  }) async {
    final mail = email;
    if (mail == null || mail.isEmpty) {
      throw ApiException('NO_EMAIL', 'Không xác định được email đăng nhập.');
    }
    try {
      await _auth.signInWithPassword(email: mail, password: current);
    } on AuthException catch (e) {
      throw _map(e, wrongCurrent: true);
    } on SocketException {
      throw _offline;
    }
    // Signing in again starts a new session: bind it to this device like a normal sign-in does.
    await AuthService(_api).registerDevice();
    try {
      await _auth.updateUser(UserAttributes(password: next));
    } on AuthException catch (e) {
      throw _map(e);
    } on SocketException {
      throw _offline;
    }
  }

  @override
  Future<void> signOut() => AuthService(_api).signOut();

  static final _offline = ApiException(
    'OFFLINE',
    'Không kết nối được máy chủ. Vui lòng thử lại.',
  );

  static ApiException _map(AuthException e, {bool wrongCurrent = false}) {
    if (e is AuthRetryableFetchException) return _offline;
    final code = e.code ?? '';
    if (code == 'same_password') {
      return ApiException(code, 'Mật khẩu mới cần khác mật khẩu hiện tại.');
    }
    if (code == 'weak_password') {
      return ApiException(code, 'Mật khẩu mới chưa đủ mạnh.');
    }
    if (code == 'over_request_rate_limit' || e.statusCode == '429') {
      return ApiException(
        'RATE_LIMIT',
        'Bạn thử quá nhiều lần. Vui lòng đợi ít phút.',
      );
    }
    if (wrongCurrent) {
      return ApiException('BAD_CREDENTIALS', 'Mật khẩu hiện tại không đúng.');
    }
    return ApiException(
      'PASSWORD_CHANGE_FAILED',
      'Không đổi được mật khẩu. Vui lòng thử lại.',
    );
  }
}

final ownerAccountProvider = Provider<OwnerAccount>(
  (ref) => SupabaseOwnerAccount(ref.watch(apiProvider)),
);
