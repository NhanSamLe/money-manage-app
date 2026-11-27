import 'money/money.dart';

/// Field validators (UX standard: every field validates itself as the user types or leaves it, and again on submit).
/// Each returns a Vietnamese message or null when valid.
typedef Validator = String? Function(String? value);

class V {
  const V._();

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static Validator required(String label) =>
      (v) => (v ?? '').trim().isEmpty ? 'Vui lòng nhập $label.' : null;

  static String? email(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Vui lòng nhập email.';
    if (t.length > 254 || !_email.hasMatch(t)) {
      return 'Email chưa đúng định dạng (ví dụ: ten@gmail.com).';
    }
    return null;
  }

  static Validator minLength(int n, String label) =>
      (v) =>
          (v ?? '').trim().length < n ? '$label cần tối thiểu $n ký tự.' : null;

  static Validator maxLength(int n, String label) =>
      (v) => (v ?? '').trim().length > n ? '$label tối đa $n ký tự.' : null;

  /// Display name: 2 to 80 characters and not only digits/symbols.
  static String? displayName(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Vui lòng nhập tên hiển thị.';
    if (t.length < 2) return 'Tên hiển thị cần tối thiểu 2 ký tự.';
    if (t.length > 80) return 'Tên hiển thị tối đa 80 ký tự.';
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(t)) {
      return 'Tên hiển thị cần có chữ cái.';
    }
    return null;
  }

  /// New password: at least 8 characters with a letter and a digit.
  static String? newPassword(String? v) {
    final t = v ?? '';
    if (t.isEmpty) return 'Vui lòng nhập mật khẩu.';
    if (t.length < 8) return 'Mật khẩu cần tối thiểu 8 ký tự.';
    if (t.length > 72) return 'Mật khẩu tối đa 72 ký tự.';
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(t) ||
        !RegExp(r'\d').hasMatch(t)) {
      return 'Mật khẩu cần có cả chữ và số.';
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
    if (t.isEmpty) return 'Vui lòng nhập mã xác nhận.';
    if (!RegExp(r'^\d{6,8}$').hasMatch(t)) {
      return 'Mã xác nhận gồm 6 đến 8 chữ số.';
    }
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
    if (n == null) {
      return '$label chưa hợp lệ. Chỉ nhập số, ví dụ 65.000 hoặc 65k.';
    }
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
