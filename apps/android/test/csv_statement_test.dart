import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/csv_statement.dart';

void main() {
  group('money cells', () {
    test('common Vietnamese formats', () {
      expect(parseMoneyCell('1.250.000'), 1250000);
      expect(parseMoneyCell('1,250,000'), 1250000);
      expect(parseMoneyCell('-65,000'), -65000);
      expect(parseMoneyCell('(65.000)'), -65000);
      expect(parseMoneyCell('65000.00'), 65000);
      expect(parseMoneyCell('1.250.000 VND'), 1250000);
    });
    test('rejects junk', () {
      expect(parseMoneyCell(''), isNull);
      expect(parseMoneyCell('abc'), isNull);
      expect(parseMoneyCell('12.5'), isNull);
    });
  });

  group('dates', () {
    test('day-first and year-first', () {
      expect(parseDateCell('27/11/2026'), DateTime(2026, 11, 27));
      expect(
        parseDateCell('2026-11-27 08:30:15'),
        DateTime(2026, 11, 27, 8, 30, 15),
      );
      expect(parseDateCell('05-01-2026'), DateTime(2026, 1, 5));
    });
    test('rejects impossible dates', () {
      expect(parseDateCell('32/13/2026'), isNull);
      expect(parseDateCell('hôm nay'), isNull);
    });
  });

  group('statement', () {
    const debitCredit =
        'Ngày,Diễn giải,Ghi nợ,Ghi có,Số dư\n'
        '27/11/2026,"Chuyển tiền, Nam",500.000,,9.500.000\n'
        '28/11/2026,Lương T11,,15.000.000,24.500.000\n'
        'ngày lỗi,Dòng hỏng,1,,\n';

    test('parses debit/credit columns and reports what it skipped', () {
      final r = parseStatementCsv(debitCredit);
      expect(r.rows.length, 2);
      expect(r.rows[0].amount, -500000);
      expect(r.rows[0].description, 'Chuyển tiền, Nam');
      expect(r.rows[1].amount, 15000000);
      expect(r.skipped.length, 1);
    });

    test('parses a single signed amount column and semicolon delimiter', () {
      final r = parseStatementCsv(
        'Date;Description;Amount\n2026-11-27;Coffee;-45.000\n',
      );
      expect(r.rows.single.amount, -45000);
    });

    test('unknown header is an explicit error, not an empty success', () {
      final r = parseStatementCsv('a,b,c\n1,2,3\n');
      expect(r.rows, isEmpty);
      expect(r.skipped, isNotEmpty);
    });

    test('command ids are deterministic per account, file and row', () {
      final a = parseStatementCsv(debitCredit);
      final b = parseStatementCsv(debitCredit);
      expect(
        importCommandId('acc1', a.fingerprint, a.rows[0]),
        importCommandId('acc1', b.fingerprint, b.rows[0]),
      );
      expect(
        importCommandId('acc1', a.fingerprint, a.rows[0]),
        isNot(importCommandId('acc2', a.fingerprint, a.rows[0])),
      );
      expect(
        importCommandId('acc1', a.fingerprint, a.rows[0]),
        isNot(importCommandId('acc1', a.fingerprint, a.rows[1])),
      );
    });
  });
}
