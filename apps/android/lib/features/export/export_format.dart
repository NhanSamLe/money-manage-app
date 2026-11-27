import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;

import '../../core/models.dart';
import '../../core/planning_models.dart';

/// Pure row building for "Xuất dữ liệu" (no Flutter, no network) so it can be unit-tested.
/// Dates are written on the Vietnam calendar (UTC+7), the same way reports cut months.
const _vnOffset = Duration(hours: 7);

/// One table of the export: a sheet in Excel, the whole file in CSV.
class ExportTable {
  const ExportTable(this.name, this.header, this.rows);
  final String name;
  final List<String> header;

  /// Cells are `String`, `int`, `double` or `null`.
  final List<List<Object?>> rows;
}

/// Half-open interval [from, to) of UTC instants. `from == null` means "from the beginning".
class ExportBounds {
  const ExportBounds(this.from, this.to);
  final DateTime? from;
  final DateTime to;

  bool contains(DateTime instant) {
    final u = instant.toUtc();
    return (from == null || !u.isBefore(from!)) && u.isBefore(to);
  }
}

enum ExportRange { thisMonth, lastMonth, thisYear, all, custom }

extension ExportRangeLabel on ExportRange {
  String get label => switch (this) {
    ExportRange.thisMonth => 'Tháng này',
    ExportRange.lastMonth => 'Tháng trước',
    ExportRange.thisYear => 'Năm nay',
    ExportRange.all => 'Tất cả',
    ExportRange.custom => 'Tùy chọn khoảng ngày',
  };
}

/// UTC instant of 00:00 Vietnam time on the given calendar day (month/day may overflow, DateTime normalises).
DateTime vnDayStartUtc(int y, int m, int d) =>
    DateTime.utc(y, m, d).subtract(_vnOffset);

/// Bounds of [range] relative to [nowUtc]. For [ExportRange.custom], [customStart]/[customEnd] are calendar
/// days (inclusive) as returned by the date range picker; only their year/month/day are used.
ExportBounds exportBounds(
  ExportRange range,
  DateTime nowUtc, {
  DateTime? customStart,
  DateTime? customEnd,
}) {
  final vn = nowUtc.toUtc().add(_vnOffset);
  switch (range) {
    case ExportRange.thisMonth:
      return ExportBounds(
        vnDayStartUtc(vn.year, vn.month, 1),
        vnDayStartUtc(vn.year, vn.month + 1, 1),
      );
    case ExportRange.lastMonth:
      return ExportBounds(
        vnDayStartUtc(vn.year, vn.month - 1, 1),
        vnDayStartUtc(vn.year, vn.month, 1),
      );
    case ExportRange.thisYear:
      return ExportBounds(
        vnDayStartUtc(vn.year, 1, 1),
        vnDayStartUtc(vn.year + 1, 1, 1),
      );
    case ExportRange.all:
      // Small margin so a transaction dated "now" on a clock slightly ahead is still included.
      return ExportBounds(null, nowUtc.toUtc().add(const Duration(days: 1)));
    case ExportRange.custom:
      final s = customStart ?? vn;
      final e = customEnd ?? s;
      return ExportBounds(
        vnDayStartUtc(s.year, s.month, s.day),
        vnDayStartUtc(e.year, e.month, e.day + 1),
      );
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

/// `yyyy-MM-dd HH:mm` on the Vietnam calendar.
String vnDateTimeText(DateTime instant) {
  final d = instant.toUtc().add(_vnOffset);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// `yyyy-MM-dd` on the Vietnam calendar.
String vnDateText(DateTime instant) {
  final d = instant.toUtc().add(_vnOffset);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

String txKindLabel(String kind) => switch (kind) {
  'INCOME' => 'Thu nhập',
  'EXPENSE' => 'Chi tiêu',
  'TRANSFER' => 'Chuyển khoản',
  'UNKNOWN_CREDIT' => 'Tiền vào chưa phân loại',
  'UNKNOWN_DEBIT' => 'Tiền ra chưa phân loại',
  _ => kind,
};

String txStatusLabel(String status) => switch (status) {
  'POSTED' => 'Đã ghi',
  'DRAFT' => 'Nháp',
  'VOID' => 'Đã hủy',
  'MERGED' => 'Đã gộp',
  _ => status,
};

/// Signed amount: money in is positive, money out negative. A transfer only moves money between the
/// owner's accounts, so it is written as a positive amount with "A -> B" in the account column.
int signedAmount(MomaTx t) {
  if (t.isIncome) return t.amount;
  if (t.isExpense) return -t.amount;
  return t.amount;
}

const transactionHeader = [
  'Ngày',
  'Loại',
  'Số tiền (VND)',
  'Phí (VND)',
  'Danh mục',
  'Tài khoản',
  'Nơi giao dịch',
  'Ghi chú',
  'Trạng thái',
];

/// Transactions sorted oldest first.
List<List<Object?>> transactionRows(
  List<MomaTx> txs, {
  required Map<String, String> accountNames,
  required Map<String, String> categoryNames,
}) {
  final sorted = [...txs]
    ..sort((a, b) {
      final c = a.effectiveAt.compareTo(b.effectiveAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  String acc(String? id) => id == null ? '' : (accountNames[id] ?? '');
  return [
    for (final t in sorted)
      [
        vnDateTimeText(t.effectiveAt),
        txKindLabel(t.kind),
        signedAmount(t),
        t.fee == 0 ? null : t.fee,
        t.categoryId == null
            ? (t.kind == 'TRANSFER' ? '' : 'Chưa phân loại')
            : (categoryNames[t.categoryId] ?? ''),
        t.kind == 'TRANSFER' && t.toAccountId != null
            ? '${acc(t.accountId)} -> ${acc(t.toAccountId)}'
            : acc(t.accountId),
        t.merchant ?? '',
        t.note ?? '',
        txStatusLabel(t.status),
      ],
  ];
}

String accountKindLabel(String kind) => switch (kind) {
  'BANK' => 'Ngân hàng',
  'WALLET' => 'Ví điện tử',
  'CASH' => 'Tiền mặt',
  'SAVINGS' => 'Tiết kiệm',
  'CREDIT_CARD' => 'Thẻ tín dụng',
  _ => kind,
};

ExportTable accountsTable(List<Account> accounts) => ExportTable(
  'Tài khoản',
  const ['Tên', 'Loại', 'Tổ chức', '4 số cuối', 'Số dư (VND)'],
  [
    for (final a in accounts)
      [
        a.name,
        accountKindLabel(a.kind),
        a.institution,
        a.last4 ?? '',
        a.balance ?? 'Chưa biết',
      ],
  ],
);

String _debtState(String s) => switch (s) {
  'OPEN' => 'Đang mở',
  'PARTIAL' => 'Đã trả một phần',
  'SETTLED' => 'Đã tất toán',
  'WRITTEN_OFF' => 'Đã xóa nợ',
  _ => s,
};

ExportTable debtsTable(List<Debt> debts) => ExportTable(
  'Công nợ',
  const [
    'Người',
    'Loại',
    'Số tiền gốc (VND)',
    'Còn lại (VND)',
    'Hạn trả',
    'Quá hạn',
    'Trạng thái',
  ],
  [
    for (final d in debts)
      [
        d.contactAlias,
        d.isReceivable ? 'Phải thu' : 'Phải trả',
        d.principal,
        d.remaining,
        d.dueDate ?? '',
        d.overdue ? 'Có' : '',
        _debtState(d.state),
      ],
  ],
);

ExportTable budgetsTable(List<Budget> budgets, String month) => ExportTable(
  'Ngân sách',
  const [
    'Tháng',
    'Danh mục',
    'Hạn mức (VND)',
    'Chuyển từ tháng trước (VND)',
    'Đã chi (VND)',
    'Còn lại (VND)',
  ],
  [
    for (final b in budgets)
      [
        month,
        b.categoryId == null ? 'Tổng ngân sách' : b.categoryName,
        b.limit,
        b.carried,
        b.spent,
        b.remaining,
      ],
  ],
);

String _goalState(String s) => switch (s) {
  'ACTIVE' => 'Đang thực hiện',
  'COMPLETED' => 'Hoàn thành',
  'ARCHIVED' => 'Đã lưu trữ',
  _ => s,
};

ExportTable goalsTable(List<Goal> goals) => ExportTable(
  'Mục tiêu',
  const ['Tên', 'Mục tiêu (VND)', 'Đã dành (VND)', 'Tiến độ (%)', 'Trạng thái'],
  [
    for (final g in goals)
      [
        g.name,
        g.target,
        g.allocated,
        (g.progress * 100).round(),
        _goalState(g.state),
      ],
  ],
);

// ------------------------------------------------------------------ CSV

/// A text cell that a spreadsheet would run as a formula (CSV injection) is prefixed with an apostrophe.
String _csvText(String s) =>
    s.isNotEmpty && '=+-@\t\r'.contains(s[0]) ? "'$s" : s;

String _csvCell(Object? v) {
  if (v == null) return '';
  final s = v is String ? _csvText(v) : v.toString();
  if (s.contains(RegExp('[",\r\n]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

/// CSV text (comma separated, CRLF line ends), header first.
String csvText(List<String> header, List<List<Object?>> rows) {
  final b = StringBuffer();
  for (final r in [header, ...rows]) {
    b
      ..write(r.map(_csvCell).join(','))
      ..write('\r\n');
  }
  return b.toString();
}

/// UTF-8 with a byte-order mark so Excel opens Vietnamese text correctly.
Uint8List csvBytes(List<String> header, List<List<Object?>> rows) =>
    Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(csvText(header, rows)),
    ]);

// ------------------------------------------------------------------ XLSX

xl.CellValue? _xlCell(Object? v) => switch (v) {
  null => null,
  final int i => xl.IntCellValue(i),
  final double d => xl.DoubleCellValue(d),
  _ => xl.TextCellValue(v.toString()),
};

/// One workbook, one sheet per table (in order), bold header row.
Uint8List xlsxBytes(List<ExportTable> tables) {
  final book = xl.Excel.createExcel();
  final initial = book.getDefaultSheet() ?? 'Sheet1';
  for (final t in tables) {
    final sheet = book[t.name];
    sheet.appendRow([for (final h in t.header) xl.TextCellValue(h)]);
    for (var c = 0; c < t.header.length; c++) {
      sheet
          .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
          .cellStyle = xl.CellStyle(
        bold: true,
      );
    }
    for (final r in t.rows) {
      sheet.appendRow([for (final v in r) _xlCell(v)]);
    }
  }
  if (tables.isNotEmpty && !tables.any((t) => t.name == initial)) {
    book.setDefaultSheet(tables.first.name);
    book.delete(initial);
  }
  final bytes = book.encode();
  if (bytes == null) throw StateError('Không tạo được file Excel.');
  return Uint8List.fromList(bytes);
}
