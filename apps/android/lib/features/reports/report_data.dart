import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';

/// Reports are cut on the Vietnam calendar (UTC+7), the same way the server cuts `/reports/summary`.
const _vnOffset = Duration(hours: 7);
const _pageSize = 100;
const _maxPages = 30;
const _nilUuid = '00000000-0000-0000-0000-000000000000';

/// `YYYY-MM` helpers.
int monthYear(String month) => int.parse(month.substring(0, 4));
int monthNumber(String month) => int.parse(month.substring(5, 7));
String monthKey(int year, int month) {
  final d = DateTime(year, month);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
}

String shiftMonth(String month, int by) =>
    monthKey(monthYear(month), monthNumber(month) + by);

String currentMonthKey() {
  final n = DateTime.now().toUtc().add(_vnOffset);
  return monthKey(n.year, n.month);
}

int daysInMonth(String month) =>
    DateTime.utc(monthYear(month), monthNumber(month) + 1, 0).day;

/// UTC instant of 00:00 Vietnam time on the first day of [month].
DateTime vnMonthStartUtc(String month) =>
    DateTime.utc(monthYear(month), monthNumber(month)).subtract(_vnOffset);

/// Vietnam-local calendar date of a transaction (independent of the phone's time zone).
DateTime vnDate(DateTime instant) => instant.toUtc().add(_vnOffset);

/// Server summary of an arbitrary month (used for the "so với tháng trước" comparison).
final monthSummaryProvider = FutureProvider.autoDispose.family<Summary, String>(
  (ref, month) async {
    final data = await ref
        .watch(apiProvider)
        .get('/reports/summary', query: {'month': month});
    return Summary.fromJson(data as Map<String, dynamic>);
  },
);

/// Every transaction of [month]. There is no date-range endpoint, so this walks the newest-first cursor
/// starting at the end of the month and stops once it passes the month start.
final monthTransactionsProvider = FutureProvider.autoDispose
    .family<List<MomaTx>, String>((ref, month) async {
      return fetchMonthTransactions(ref.watch(apiProvider), month);
    });

Future<List<MomaTx>> fetchMonthTransactions(ApiClient api, String month) async {
  final start = vnMonthStartUtc(month);
  final end = vnMonthStartUtc(shiftMonth(month, 1));
  final out = <MomaTx>[];
  final seen = <String>{};
  var at = end.toIso8601String();
  var id = _nilUuid;
  for (var page = 0; page < _maxPages; page++) {
    final cursor = base64Url
        .encode(utf8.encode(jsonEncode({'at': at, 'id': id})))
        .replaceAll('=', '');
    final data = await api.get(
      '/transactions',
      query: {'limit': '$_pageSize', 'cursor': cursor},
    );
    final rows = (data as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(MomaTx.fromJson)
        .toList();
    for (final t in rows) {
      final u = t.effectiveAt.toUtc();
      if (!u.isBefore(start) && u.isBefore(end) && seen.add(t.id)) out.add(t);
    }
    if (rows.length < _pageSize) break;
    final last = rows.last;
    if (last.effectiveAt.toUtc().isBefore(start)) break;
    at = last.rawEffectiveAt;
    id = last.id;
  }
  return out;
}

/// Per-day totals of one month, aggregated client-side from its transactions.
class DailySeries {
  DailySeries({required this.expense, required this.income});
  final List<int> expense;
  final List<int> income;

  factory DailySeries.from(List<MomaTx> txs, String month) {
    final n = daysInMonth(month);
    final exp = List<int>.filled(n, 0);
    final inc = List<int>.filled(n, 0);
    for (final t in txs) {
      if (t.isVoid) continue;
      final day = vnDate(t.effectiveAt).day;
      if (day < 1 || day > n) continue;
      if (t.isExpense) exp[day - 1] += t.amount;
      if (t.isIncome) inc[day - 1] += t.amount;
      exp[day - 1] += t.fee; // fees are always spending
    }
    return DailySeries(expense: exp, income: inc);
  }
}

/// Income grouped by category (the server summary only breaks down spending).
List<CategorySpend> incomeByCategory(
  List<MomaTx> txs,
  List<Category> categories,
) {
  final byId = {for (final c in categories) c.id: c};
  final totals = <String, int>{};
  for (final t in txs) {
    if (t.isVoid || !t.isIncome || t.amount <= 0) continue;
    final key = t.categoryId ?? '';
    totals[key] = (totals[key] ?? 0) + t.amount;
  }
  final list = [
    for (final e in totals.entries)
      CategorySpend(
        name: byId[e.key]?.name ?? 'Chưa phân loại',
        icon: byId[e.key]?.icon,
        amount: e.value,
      ),
  ]..sort((a, b) => b.amount.compareTo(a.amount));
  return list;
}

/// Weekly buckets of a month: 1–7, 8–14, 15–21, 22–28, 29–end.
List<({String label, int amount, int from, int to})> weeklyBuckets(
  List<int> daily,
) {
  final out = <({String label, int amount, int from, int to})>[];
  for (var s = 0; s < daily.length; s += 7) {
    final e = (s + 7 > daily.length) ? daily.length : s + 7;
    var sum = 0;
    for (var i = s; i < e; i++) {
      sum += daily[i];
    }
    out.add((label: '${s + 1}–$e', amount: sum, from: s + 1, to: e));
  }
  return out;
}
