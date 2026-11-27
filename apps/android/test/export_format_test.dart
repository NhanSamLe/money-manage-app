import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/planning_models.dart';
import 'package:moma/features/export/export_format.dart';

MomaTx _tx(
  String id,
  String kind,
  String at,
  String amount, {
  String status = 'POSTED',
  String fee = '0',
  String? account = 'a1',
  String? to,
  String? category,
  String? merchant,
  String? note,
}) => MomaTx.fromJson({
  'id': id,
  'kind': kind,
  'status': status,
  'effective_at': at,
  'amount': amount,
  'fee': fee,
  'account_id': account,
  'to_account_id': to,
  'category_id': category,
  'merchant': merchant,
  'note': note,
  'version': 1,
});

void main() {
  const accounts = {'a1': 'Vietcombank', 'a2': 'Tiền mặt'};
  const categories = {'c1': 'Ăn uống', 'c2': 'Lương'};

  group('transactionRows', () {
    test('signed amounts, Vietnam dates, labels, oldest first', () {
      final rows = transactionRows(
        [
          _tx(
            't2',
            'EXPENSE',
            '2026-11-02T03:30:00Z',
            '50000',
            category: 'c1',
            merchant: 'Phở Hà Nội',
            note: 'trưa',
            fee: '1000',
          ),
          _tx(
            't1',
            'INCOME',
            '2026-10-31T17:15:00Z',
            '20000000',
            category: 'c2',
          ),
          _tx('t3', 'TRANSFER', '2026-11-03T00:00:00Z', '300000', to: 'a2'),
          _tx(
            't4',
            'UNKNOWN_DEBIT',
            '2026-11-04T00:00:00Z',
            '7000',
            status: 'VOID',
          ),
        ],
        accountNames: accounts,
        categoryNames: categories,
      );
      expect(rows, hasLength(4));
      // 17:15Z on Oct 31 is already Nov 1 in Vietnam.
      expect(rows[0], [
        '2026-11-01 00:15',
        'Thu nhập',
        20000000,
        null,
        'Lương',
        'Vietcombank',
        '',
        '',
        'Đã ghi',
      ]);
      expect(rows[1], [
        '2026-11-02 10:30',
        'Chi tiêu',
        -50000,
        1000,
        'Ăn uống',
        'Vietcombank',
        'Phở Hà Nội',
        'trưa',
        'Đã ghi',
      ]);
      expect(rows[2][1], 'Chuyển khoản');
      expect(rows[2][2], 300000);
      expect(rows[2][4], '');
      expect(rows[2][5], 'Vietcombank -> Tiền mặt');
      expect(rows[3][2], -7000);
      expect(rows[3][4], 'Chưa phân loại');
      expect(rows[3][8], 'Đã hủy');
      expect(transactionHeader, hasLength(rows[0].length));
    });
  });

  group('exportBounds', () {
    final now = DateTime.utc(2026, 1, 15, 20); // 16 Jan 03:00 in Vietnam

    test('this month / last month cross the year boundary', () {
      final m = exportBounds(ExportRange.thisMonth, now);
      expect(m.from, DateTime.utc(2025, 12, 31, 17));
      expect(m.to, DateTime.utc(2026, 1, 31, 17));
      final p = exportBounds(ExportRange.lastMonth, now);
      expect(p.from, DateTime.utc(2025, 11, 30, 17));
      expect(p.to, DateTime.utc(2025, 12, 31, 17));
    });

    test('this year and all', () {
      final y = exportBounds(ExportRange.thisYear, now);
      expect(y.from, DateTime.utc(2025, 12, 31, 17));
      expect(y.to, DateTime.utc(2026, 12, 31, 17));
      final a = exportBounds(ExportRange.all, now);
      expect(a.from, isNull);
      expect(a.contains(DateTime.utc(2001)), isTrue);
    });

    test('custom range includes the whole last day', () {
      final b = exportBounds(
        ExportRange.custom,
        now,
        customStart: DateTime(2026, 1, 5),
        customEnd: DateTime(2026, 1, 10),
      );
      expect(b.contains(DateTime.utc(2026, 1, 4, 17)), isTrue);
      expect(b.contains(DateTime.utc(2026, 1, 4, 16, 59)), isFalse);
      expect(b.contains(DateTime.utc(2026, 1, 10, 16, 59)), isTrue);
      expect(b.contains(DateTime.utc(2026, 1, 10, 17)), isFalse);
    });
  });

  group('CSV', () {
    test('starts with a UTF-8 BOM and keeps Vietnamese text', () {
      final bytes = csvBytes(
        ['Ngày', 'Ghi chú'],
        [
          ['2026-11-01 08:00', 'Cà phê'],
        ],
      );
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(
        utf8.decode(bytes.sublist(3)),
        'Ngày,Ghi chú\r\n2026-11-01 08:00,Cà phê\r\n',
      );
    });

    test('quotes separators, quotes and new lines; numbers stay plain', () {
      final text = csvText(
        ['a', 'b', 'c', 'd'],
        [
          ['x, y', 'say "hi"', 'line1\nline2', -50000],
          [null, 12, '', 1.5],
        ],
      );
      expect(
        text,
        'a,b,c,d\r\n"x, y","say ""hi""","line1\nline2",-50000\r\n,12,,1.5\r\n',
      );
    });

    test('text that looks like a formula is neutralised', () {
      final text = csvText(
        ['n'],
        [
          ['=HYPERLINK("x")'],
          ['-giảm giá'],
          ['+1'],
          ['@SUM'],
        ],
      );
      expect(
        text,
        'n\r\n"\'=HYPERLINK(""x"")"\r\n\'-giảm giá\r\n\'+1\r\n\'@SUM\r\n',
      );
    });
  });

  group('XLSX', () {
    test('one sheet per table with typed cells', () {
      final account = Account.fromJson({
        'id': 'a1',
        'kind': 'BANK',
        'institution': 'VCB',
        'name': 'Vietcombank',
        'last4': '1234',
        'balance': '1500000',
        'version': 1,
      });
      final unknown = Account.fromJson({
        'id': 'a2',
        'kind': 'CASH',
        'institution': '',
        'name': 'Tiền mặt',
        'last4': null,
        'balance': null,
        'version': 1,
      });
      final goal = Goal.fromJson({
        'id': 'g',
        'name': 'Du lịch',
        'target': '10000000',
        'allocated': '2500000',
        'state': 'ACTIVE',
        'version': 1,
      });
      final bytes = xlsxBytes([
        const ExportTable('Giao dịch', transactionHeader, [
          [
            '2026-11-01 08:00',
            'Chi tiêu',
            -50000,
            null,
            'Ăn uống',
            'Vietcombank',
            '',
            'Cà phê',
            'Đã ghi',
          ],
        ]),
        accountsTable([account, unknown]),
        goalsTable([goal]),
      ]);
      final book = Excel.decodeBytes(bytes);
      expect(
        book.tables.keys,
        containsAll(['Giao dịch', 'Tài khoản', 'Mục tiêu']),
      );
      expect(book.tables.keys, isNot(contains('Sheet1')));
      final tx = book.tables['Giao dịch']!;
      expect(tx.maxRows, 2);
      expect(tx.rows[0][0]?.value, TextCellValue('Ngày'));
      expect(tx.rows[1][2]?.value, IntCellValue(-50000));
      expect(tx.rows[1][7]?.value, TextCellValue('Cà phê'));
      final acc = book.tables['Tài khoản']!;
      expect(acc.rows[1][4]?.value, IntCellValue(1500000));
      expect(acc.rows[2][4]?.value, TextCellValue('Chưa biết'));
      expect(acc.rows[1][1]?.value, TextCellValue('Ngân hàng'));
      final g = book.tables['Mục tiêu']!;
      expect(g.rows[1][3]?.value, IntCellValue(25));
    });

    test('debts and budgets tables', () {
      final debt = Debt.fromJson({
        'id': 'd',
        'direction': 'RECEIVABLE',
        'contact_alias': 'An',
        'principal': '500000',
        'remaining': '200000',
        'state': 'PARTIAL',
        'due_date': '2026-12-01',
        'overdue': false,
        'version': 1,
      });
      final t = debtsTable([debt]);
      expect(t.rows.single, [
        'An',
        'Phải thu',
        500000,
        200000,
        '2026-12-01',
        '',
        'Đã trả một phần',
      ]);
      final budget = Budget.fromJson({
        'id': 'b',
        'category_id': null,
        'category_name': '',
        'icon': null,
        'limit_amount': '8000000',
        'spent': '3000000',
        'carried': '0',
        'remaining': '5000000',
        'carryover': false,
        'version': 1,
      });
      expect(budgetsTable([budget], '2026-11').rows.single, [
        '2026-11',
        'Tổng ngân sách',
        8000000,
        0,
        3000000,
        5000000,
      ]);
    });
  });
}
