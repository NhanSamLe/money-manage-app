import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/money/money.dart';

void main() {
  group('formatVnd', () {
    test('groups thousands with dots', () {
      expect(formatVnd(1250000), '1.250.000 ₫');
      expect(formatVnd(65000), '65.000 ₫');
      expect(formatVnd(0), '0 ₫');
    });
    test('keeps the sign', () => expect(formatVnd(-65000), '-65.000 ₫'));
  });

  group('parseVndInput', () {
    test(
      'strips separators',
      () => expect(parseVndInput('1.250.000'), 1250000),
    );
    test('rejects empty and too long input', () {
      expect(parseVndInput(''), isNull);
      expect(parseVndInput('abc'), isNull);
      expect(parseVndInput('12345678901234567'), isNull);
    });
  });

  test('parseVnd reads wire strings exactly', () {
    expect(parseVnd('9000000000000000'), 9000000000000000);
    expect(parseVnd('-250000'), -250000);
  });
}
