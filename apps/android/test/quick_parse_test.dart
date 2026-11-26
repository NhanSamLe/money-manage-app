import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/quick_parse.dart';

void main() {
  group('amounts', () {
    test('thousand shorthand', () {
      expect(parseQuickText('ăn trưa 65k').amount, 65000);
      expect(parseQuickText('cà phê 30 nghìn').amount, 30000);
      expect(parseQuickText('mua áo 250 ngàn').amount, 250000);
    });
    test('million shorthand with fractions', () {
      expect(parseQuickText('lương 15tr').amount, 15000000);
      expect(parseQuickText('tiền nhà 3,5 triệu').amount, 3500000);
      expect(parseQuickText('thưởng 1.5tr').amount, 1500000);
      expect(parseQuickText('mua laptop 1tr2').amount, 1200000);
    });
    test('grouped plain numbers', () {
      expect(parseQuickText('grab 65.000').amount, 65000);
      expect(parseQuickText('điện 1,250,000').amount, 1250000);
      expect(parseQuickText('xăng 50000').amount, 50000);
    });
    test('never guesses ambiguous amounts', () {
      expect(parseQuickText('ăn trưa 65').amount, isNull);
      expect(parseQuickText('ăn trưa').amount, isNull);
      expect(parseParts('1,2345tr'), 1234500); // exact, not rounded
      expect(parseParts('1,23456789tr'), isNull); // would need rounding
    });
  });

  group('classification', () {
    test('expense categories', () {
      expect(parseQuickText('ăn trưa 65k').categoryName, 'Ăn uống');
      expect(parseQuickText('grab đi làm 45k').categoryName, 'Di chuyển');
      expect(parseQuickText('đóng tiền điện 800k').categoryName, 'Hóa đơn');
      expect(parseQuickText('netflix 260k').categoryName, 'Giải trí');
    });
    test('income detection', () {
      final p = parseQuickText('nhận lương 15tr');
      expect(p.income, isTrue);
      expect(p.categoryName, 'Lương');
      expect(p.amount, 15000000);
    });
    test('unknown text is left unclassified', () {
      expect(parseQuickText('khoản lạ 100k').categoryName, isNull);
      expect(parseQuickText('khoản lạ 100k').income, isFalse);
    });
    test('diacritics folding', () {
      expect(foldVietnamese('Đường Ăn Trưa'), 'duong an trua');
    });
  });

  test('note drops the amount', () {
    expect(parseQuickText('ăn trưa 65k quán cô Ba').note, 'ăn trưa quán cô Ba');
  });
}

int? parseParts(String s) {
  final m = RegExp(r'^(\d+(?:[.,]\d+)?)(tr)$').firstMatch(s);
  return m == null ? null : parseAmountToken(m.group(1)!, m.group(2), null);
}
