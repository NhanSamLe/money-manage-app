import 'package:uuid/uuid.dart';

/// One normalised bank-statement line. Amount is signed integer VND: credit (+) / debit (-).
class StatementRow {
  StatementRow({
    required this.rowNo,
    required this.date,
    required this.description,
    required this.amount,
  });
  final int rowNo;
  final DateTime date;
  final String description;
  final int amount;
  bool get isCredit => amount > 0;
}

class StatementResult {
  StatementResult({
    required this.rows,
    required this.skipped,
    required this.fingerprint,
  });
  final List<StatementRow> rows;

  /// Human-readable reasons for rows that were not understood (never silently dropped).
  final List<String> skipped;

  /// Stable id of the whole file; with the row number it yields deterministic command ids.
  final String fingerprint;
}

const _importNamespace = 'a3b2c1d0-5f4e-4a7b-9c8d-0e1f2a3b4c5d';

/// Deterministic command id: re-importing the same file for the same account replays instead of duplicating.
String importCommandId(String accountId, String fingerprint, StatementRow r) {
  return const Uuid().v5(
    _importNamespace,
    'moma-import|$accountId|$fingerprint|${r.rowNo}|${r.date.toIso8601String()}|${r.amount}|${r.description}',
  );
}

List<List<String>> parseCsv(String text) {
  final first = text.split('\n').first;
  final delimiter = [
    ',',
    ';',
    '\t',
  ].reduce((a, b) => first.split(a).length >= first.split(b).length ? a : b);
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  void endCell() {
    row.add(cell.toString().trim());
    cell.clear();
  }

  void endRow() {
    endCell();
    if (row.any((c) => c.isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == delimiter) {
      endCell();
    } else if (ch == '\n') {
      endRow();
    } else if (ch != '\r') {
      cell.write(ch);
    }
  }
  endRow();
  return rows;
}

/// Integer VND from "1.250.000", "1,250,000", "-65,000", "(65.000)", "65000.00". Null if not a clean amount.
int? parseMoneyCell(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s₫đ]|VND|vnd'), '');
  if (s.isEmpty) return null;
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = true;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  s = s.replaceFirst(RegExp(r'[.,]0{1,2}$'), '');
  if (RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(s)) {
    s = s.replaceAll(RegExp(r'[.,]'), '');
  }
  if (!RegExp(r'^\d{1,16}$').hasMatch(s)) return null;
  final v = int.parse(s);
  return negative ? -v : v;
}

DateTime? parseDateCell(String raw) {
  final m = RegExp(
    r'^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{1,4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  final c = int.parse(m.group(3)!);
  final yearFirst = m.group(1)!.length == 4;
  final y = yearFirst ? a : c;
  final d = yearFirst ? c : a;
  if (b < 1 || b > 12 || d < 1 || d > 31 || y < 1990 || y > 2100) return null;
  return DateTime(
    y,
    b,
    d,
    int.tryParse(m.group(4) ?? '') ?? 0,
    int.tryParse(m.group(5) ?? '') ?? 0,
    int.tryParse(m.group(6) ?? '') ?? 0,
  );
}

int _findColumn(List<String> header, List<String> names) {
  for (var i = 0; i < header.length; i++) {
    final h = header[i].toLowerCase();
    if (names.any(h.contains)) return i;
  }
  return -1;
}

/// Parses a statement exported as CSV. Needs a header row; columns are matched by Vietnamese/English names.
StatementResult parseStatementCsv(String text) {
  final fingerprint = const Uuid().v5(_importNamespace, text);
  final table = parseCsv(text);
  if (table.length < 2) {
    return StatementResult(
      rows: [],
      skipped: ['Tệp không có dữ liệu.'],
      fingerprint: fingerprint,
    );
  }
  final header = table.first;
  final dateCol = _findColumn(header, ['ngày', 'ngay', 'date']);
  final descCol = _findColumn(header, [
    'diễn giải',
    'dien giai',
    'nội dung',
    'noi dung',
    'mô tả',
    'description',
    'details',
  ]);
  final debitCol = _findColumn(header, [
    'ghi nợ',
    'ghi no',
    'debit',
    'rút',
    'tiền ra',
  ]);
  final creditCol = _findColumn(header, [
    'ghi có',
    'ghi co',
    'credit',
    'gửi',
    'tiền vào',
  ]);
  final amountCol = _findColumn(header, ['số tiền', 'so tien', 'amount']);
  if (dateCol < 0 || (amountCol < 0 && debitCol < 0 && creditCol < 0)) {
    return StatementResult(
      rows: [],
      skipped: ['Không nhận ra cột ngày hoặc số tiền trong dòng tiêu đề.'],
      fingerprint: fingerprint,
    );
  }
  final rows = <StatementRow>[];
  final skipped = <String>[];
  for (var i = 1; i < table.length; i++) {
    final r = table[i];
    String cell(int c) => c >= 0 && c < r.length ? r[c] : '';
    final date = parseDateCell(cell(dateCol));
    int? amount;
    if (amountCol >= 0) {
      amount = parseMoneyCell(cell(amountCol));
    } else {
      final debit = parseMoneyCell(cell(debitCol));
      final credit = parseMoneyCell(cell(creditCol));
      if (debit != null && debit != 0 && (credit == null || credit == 0)) {
        amount = -debit.abs();
      } else if (credit != null &&
          credit != 0 &&
          (debit == null || debit == 0)) {
        amount = credit.abs();
      }
    }
    if (date == null || amount == null || amount == 0) {
      skipped.add('Dòng ${i + 1}: không đọc được ngày hoặc số tiền.');
      continue;
    }
    rows.add(
      StatementRow(
        rowNo: i + 1,
        date: date,
        description: cell(descCol),
        amount: amount,
      ),
    );
  }
  return StatementResult(
    rows: rows,
    skipped: skipped,
    fingerprint: fingerprint,
  );
}
