import 'dart:convert';
import 'dart:typed_data';

import '../../core/models.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import 'export_format.dart';

enum ExportFormat { xlsx, csv }

class ExportResult {
  const ExportResult({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.transactionCount,
  });
  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final int transactionCount;
}

const _pageSize = 100; // server maximum
const _maxPages = 500; // 50 000 transactions, a hard stop against a cursor loop
const _nilUuid = '00000000-0000-0000-0000-000000000000';

List<Map<String, dynamic>> _list(dynamic data) =>
    (data as List<dynamic>).cast<Map<String, dynamic>>();

/// Every transaction inside [bounds]. There is no date-range endpoint, so this walks the newest-first cursor
/// from the end of the range and stops once it passes the start. [onProgress] gets the count so far.
Future<List<MomaTx>> fetchTransactionsIn(
  ApiClient api,
  ExportBounds bounds, {
  void Function(int fetched)? onProgress,
}) async {
  final out = <MomaTx>[];
  final seen = <String>{};
  var at = bounds.to.toIso8601String();
  var id = _nilUuid;
  for (var page = 0; page < _maxPages; page++) {
    final cursor = base64Url
        .encode(utf8.encode(jsonEncode({'at': at, 'id': id})))
        .replaceAll('=', '');
    final data = await api.get(
      '/transactions',
      query: {'limit': '$_pageSize', 'cursor': cursor},
    );
    final rows = _list(data).map(MomaTx.fromJson).toList();
    for (final t in rows) {
      if (bounds.contains(t.effectiveAt) && seen.add(t.id)) out.add(t);
    }
    onProgress?.call(out.length);
    if (rows.length < _pageSize) break;
    final last = rows.last;
    final from = bounds.from;
    if (from != null && last.effectiveAt.toUtc().isBefore(from)) break;
    at = last.rawEffectiveAt;
    id = last.id;
  }
  return out;
}

String _monthOf(DateTime instantUtc) {
  final d = instantUtc.toUtc().add(const Duration(hours: 7));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// Builds the whole export file. Planning sheets are only added to Excel; a failure to read one of them
/// leaves that sheet out rather than failing the export (transactions are what matters).
Future<ExportResult> buildExport(
  ApiClient api, {
  required ExportBounds bounds,
  required ExportFormat format,
  required String rangeTag,
  void Function(String step, int fetched)? onProgress,
}) async {
  onProgress?.call('Đang tải tài khoản và danh mục', 0);
  final accounts = _list(await api.get('/accounts')).map(Account.fromJson);
  final categories = _list(await api.get('/categories')).map(Category.fromJson);
  final accountList = accounts.toList();
  final txs = await fetchTransactionsIn(
    api,
    bounds,
    onProgress: (n) => onProgress?.call('Đang tải giao dịch', n),
  );
  final rows = transactionRows(
    txs,
    accountNames: {for (final a in accountList) a.id: a.name},
    categoryNames: {for (final c in categories) c.id: c.name},
  );
  final stamp = rangeTag;
  if (format == ExportFormat.csv) {
    return ExportResult(
      bytes: csvBytes(transactionHeader, rows),
      fileName: 'MoMa-giao-dich-$stamp.csv',
      mimeType: 'text/csv',
      transactionCount: txs.length,
    );
  }
  onProgress?.call('Đang tải công nợ, ngân sách, mục tiêu', txs.length);
  final now = DateTime.now().toUtc();
  final budgetMonth = _monthOf(
    bounds.to.isAfter(now)
        ? now
        : bounds.to.subtract(const Duration(milliseconds: 1)),
  );
  Future<T?> optional<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on ApiException {
      return null;
    }
  }

  final debts = await optional(
    () async => _list(await api.get('/debts')).map(Debt.fromJson).toList(),
  );
  final budgets = await optional(
    () async =>
        _list(await api.get('/budgets', query: {'month': budgetMonth}))
            .map(Budget.fromJson)
            .toList(),
  );
  final goals = await optional(
    () async =>
        GoalsData.fromJson(await api.get('/goals') as Map<String, dynamic>)
            .goals,
  );
  onProgress?.call('Đang tạo file Excel', txs.length);
  final bytes = xlsxBytes([
    ExportTable('Giao dịch', transactionHeader, rows),
    accountsTable(accountList),
    if (debts != null) debtsTable(debts),
    if (budgets != null) budgetsTable(budgets, budgetMonth),
    if (goals != null) goalsTable(goals),
  ]);
  return ExportResult(
    bytes: bytes,
    fileName: 'MoMa-$stamp.xlsx',
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    transactionCount: txs.length,
  );
}
