import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/validators.dart';

void main() {
  group('email', () {
    test('accepts normal addresses', () {
      expect(V.email('ledaonhansam@gmail.com'), isNull);
      expect(V.email('  a.b+c@mail.vn '), isNull);
    });
    test('rejects missing parts with a clear message', () {
      expect(V.email(''), 'Vui lòng nhập email.');
      expect(V.email('abc'), isNotNull);
      expect(V.email('a@b'), isNotNull);
      expect(V.email('a b@c.com'), isNotNull);
    });
  });

  group('password', () {
    test('needs length, a letter and a digit', () {
      expect(V.newPassword(''), 'Vui lòng nhập mật khẩu.');
      expect(V.newPassword('abc123'), 'Tối thiểu 8 ký tự.');
      expect(V.newPassword('abcdefgh'), 'Cần có cả chữ và số.');
      expect(V.newPassword('12345678'), 'Cần có cả chữ và số.');
      expect(V.newPassword('matkhau123'), isNull);
    });
    test('confirmation must match', () {
      final v = V.sameAs(() => 'abc12345', 'khác nhau');
      expect(v(''), 'Vui lòng nhập lại mật khẩu.');
      expect(v('abc12346'), 'khác nhau');
      expect(v('abc12345'), isNull);
    });
  });

  group('names and codes', () {
    test('display name', () {
      expect(V.displayName(' '), isNotNull);
      expect(V.displayName('A'), isNotNull);
      expect(V.displayName('1234'), 'Tên cần có chữ cái.');
      expect(V.displayName('Lê Đào Nhân Sâm'), isNull);
    });
    test('otp is 6 to 8 digits', () {
      expect(V.otp('12345'), isNotNull);
      expect(V.otp('12ab56'), isNotNull);
      expect(V.otp('123456'), isNull);
      expect(V.otp('12345678'), isNull);
    });
  });

  group('amount', () {
    test('required, positive and bounded', () {
      final v = V.amount('Số tiền');
      expect(v(''), 'Vui lòng nhập số tiền.');
      expect(v('0'), 'Số tiền phải lớn hơn 0.');
      expect(v('65.000'), isNull);
      expect(v('9999999999999'), 'Số tiền quá lớn.');
    });
    test('optional may be empty', () {
      expect(V.amount('Lãi', allowEmpty: true)(''), isNull);
    });
  });
}
