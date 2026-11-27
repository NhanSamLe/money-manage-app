import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/providers.dart';

/// Periods accepted by GET /v1/insights?period=... and POST /v1/insights/run.
enum InsightPeriod {
  day('DAY', 'Ngày'),
  week('WEEK', 'Tuần'),
  month('MONTH', 'Tháng');

  const InsightPeriod(this.wire, this.label);
  final String wire;
  final String label;

  static InsightPeriod fromWire(String? v) =>
      values.firstWhere((p) => p.wire == v, orElse: () => InsightPeriod.month);
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.round();
  return int.tryParse('$v');
}

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

List<String> _strings(Object? v) => v is List
    ? [
        for (final s in v)
          if (s != null) '$s',
      ]
    : const [];

class CategoryChange {
  CategoryChange({
    required this.categoryId,
    required this.name,
    required this.amount,
    required this.prevAmount,
    required this.changePct,
  });
  final String? categoryId;
  final String name;
  final int amount;
  final int prevAmount;
  final double? changePct;

  factory CategoryChange.fromJson(Map<String, dynamic> j) => CategoryChange(
    categoryId: j['category_id'] as String?,
    name: '${j['name'] ?? 'Khác'}',
    amount: _int(j['amount']) ?? 0,
    prevAmount: _int(j['prev_amount']) ?? 0,
    changePct: _num(j['change_pct']),
  );
}

class InsightNumbers {
  InsightNumbers({
    this.income,
    this.expense,
    this.net,
    this.prevExpense,
    this.changePct,
    this.byCategory = const [],
    this.forecastExpense,
    this.suggestedLimit,
    this.dailyAvg,
  });
  final int? income;
  final int? expense;
  final int? net;
  final int? prevExpense;
  final double? changePct;
  final List<CategoryChange> byCategory;
  final int? forecastExpense;
  final int? suggestedLimit;
  final int? dailyAvg;

  factory InsightNumbers.fromJson(Map<String, dynamic> j) => InsightNumbers(
    income: _int(j['income']),
    expense: _int(j['expense']),
    net: _int(j['net']),
    prevExpense: _int(j['prev_expense']),
    changePct: _num(j['change_pct']),
    byCategory: [
      for (final c in (j['by_category'] as List? ?? const []))
        if (c is Map<String, dynamic>) CategoryChange.fromJson(c),
    ],
    forecastExpense: _int(j['forecast_expense']),
    suggestedLimit: _int(j['suggested_limit']),
    dailyAvg: _int(j['daily_avg']),
  );
}

class Insight {
  Insight({
    required this.id,
    required this.period,
    this.periodStart,
    this.periodEnd,
    this.createdAt,
    required this.title,
    required this.summary,
    this.highlights = const [],
    this.suggestions = const [],
    required this.numbers,
    this.reused = false,
  });
  final String id;
  final InsightPeriod period;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final DateTime? createdAt;
  final String title;
  final String summary;
  final List<String> highlights;
  final List<String> suggestions;
  final InsightNumbers numbers;

  /// True when POST /insights/run returned a recent existing analysis instead of a new one.
  final bool reused;

  factory Insight.fromJson(Map<String, dynamic> j) => Insight(
    id: '${j['id']}',
    period: InsightPeriod.fromWire(j['period'] as String?),
    periodStart: DateTime.tryParse('${j['period_start']}'),
    periodEnd: DateTime.tryParse('${j['period_end']}'),
    createdAt: DateTime.tryParse('${j['created_at']}')?.toLocal(),
    title: '${j['title'] ?? 'Phân tích chi tiêu'}',
    summary: '${j['summary'] ?? ''}',
    highlights: _strings(j['highlights']),
    suggestions: _strings(j['suggestions']),
    numbers: j['numbers'] is Map<String, dynamic>
        ? InsightNumbers.fromJson(j['numbers'] as Map<String, dynamic>)
        : InsightNumbers(),
    reused: j['reused'] == true,
  );
}

/// True when the endpoint is missing (backend not deployed yet): shown as a friendly empty state, not an error.
bool isNotDeployed(Object e) =>
    e is ApiException &&
    (e.code == 'NOT_FOUND' ||
        e.code == '404' ||
        (e.code == 'UNKNOWN' && e.message.contains('(404)')));

final insightsProvider = FutureProvider.autoDispose
    .family<List<Insight>, InsightPeriod>((ref, period) async {
      final data = await ref
          .watch(apiProvider)
          .get('/insights', query: {'period': period.wire, 'limit': '20'});
      final list = [
        for (final j in (data as List? ?? const []))
          if (j is Map<String, dynamic>) Insight.fromJson(j),
      ];
      list.sort(
        (a, b) =>
            (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
      );
      return list;
    });

final insightProvider = FutureProvider.autoDispose.family<Insight, String>((
  ref,
  id,
) async {
  final data = await ref.watch(apiProvider).get('/insights/$id');
  return Insight.fromJson(data as Map<String, dynamic>);
});

Future<Insight> runInsight(ApiClient api, InsightPeriod period) async {
  final data = await api.post('/insights/run', {'period': period.wire});
  return Insight.fromJson(data as Map<String, dynamic>);
}
