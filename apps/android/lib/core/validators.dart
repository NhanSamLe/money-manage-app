import 'money/money.dart';

/// Field validators. Messages are deliberately short, one sentence, with no examples.
/// Each returns a Vietnamese message or null when valid.
typedef Validator = String? Function(String? value);

class V {
  const V._();

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static Validator required(String label) =>
      (v) => (v ?? '').trim().isEmpty
      ? 'Vui lòng nhập ${label.toLowerCase()}.'
      : null;

  static String? email(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Vui lòng nhập email.';
    if (t.length > 254 || !_email.hasMatch(t)) return 'Email không hợp lệ.';
    return null;
  }

  static Validator minLength(int n, String label) =>
      (v) => (v ?? '').trim().length < n ? '$label tối thiểu $n ký tự.' : null;

  static Validator maxLength(int n, String label) =>
      (v) => (v ?? '').trim().length > n ? '$label tối đa $n ký tự.' : null;

  /// Display name: 2 to 80 characters and at least one letter.
  static String? displayName(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Vui lòng nhập tên.';
    if (t.length < 2) return 'Tên cần từ 2 ký tự.';
    if (t.length > 80) return 'Tên tối đa 80 ký tự.';
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(t)) {
      return 'Tên cần có chữ cái.';
    }
    return null;
  }

  /// New password: at least 8 characters with a letter and a digit.
  static String? newPassword(String? v) {
    final t = v ?? '';
    if (t.isEmpty) return 'Vui lòng nhập mật khẩu.';
    if (t.length < 8) return 'Tối thiểu 8 ký tự.';
    if (t.length > 72) return 'Tối đa 72 ký tự.';
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(t) ||
        !RegExp(r'\d').hasMatch(t)) {
      return 'Cần có cả chữ và số.';
    }
    return null;
  }

  static String? currentPassword(String? v) =>
      (v ?? '').isEmpty ? 'Vui lòng nhập mật khẩu.' : null;

  static Validator sameAs(String Function() other, String message) =>
      (v) => (v ?? '').isEmpty
      ? 'Vui lòng nhập lại mật khẩu.'
      : (v == other() ? null : message);

  /// One-time email code: 6 to 8 digits.
  static String? otp(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Vui lòng nhập mã.';
    if (!RegExp(r'^\d{6,8}$').hasMatch(t)) return 'Mã gồm 6 đến 8 số.';
    return null;
  }

  /// Positive VND amount (integer, no decimals). [allowEmpty] for optional fields.
  static Validator amount(
    String label, {
    bool allowEmpty = false,
    int max = 999999999999,
  }) => (v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) {
      return allowEmpty ? null : 'Vui lòng nhập ${label.toLowerCase()}.';
    }
    final n = parseVndInput(t);
    if (n == null) return '$label không hợp lệ.';
    if (n <= 0) return '$label phải lớn hơn 0.';
    if (n > max) return '$label quá lớn.';
    return null;
  };

  static Validator all(List<Validator> list) => (v) {
    for (final f in list) {
      final e = f(v);
      if (e != null) return e;
    }
    return null;
  };
}
