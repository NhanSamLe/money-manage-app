import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Self-adjusting budgets (D-026): what MoMa proposes from real spending, and the month's daily pacing.

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

class BudgetProposal {
  const BudgetProposal({
    required this.categoryId,
    required this.name,
    required this.icon,
    required this.proposed,
    required this.monthlyAvg,
    required this.currentLimit,
    required this.reason,
    required this.note,
  });

  factory BudgetProposal.fromJson(Map<String, dynamic> j) => BudgetProposal(
    categoryId: j['category_id'] as String?,
    name: '${j['name'] ?? ''}',
    icon: j['icon'] as String?,
    proposed: _int(j['proposed']),
    monthlyAvg: _int(j['monthly_avg']),
    currentLimit: j['current_limit'] == null ? null : _int(j['current_limit']),
    reason: '${j['reason'] ?? 'new'}',
    note: '${j['note'] ?? ''}',
  );

  final String? categoryId;
  final String name;
  final String? icon;
  final int proposed;
  final int monthlyAvg;
  final int? currentLimit;

  /// new | raise | lower | keep | realistic
  final String reason;
  final String note;

  /// Worth showing as a change (new budget or a different limit).
  bool get isChange => reason != 'keep';

  String get reasonLabel => switch (reason) {
    'raise' => 'Nên tăng',
    'lower' => 'Có thể giảm',
    'realistic' => 'Mức thực tế',
    'keep' => 'Giữ nguyên',
    _ => 'Đề xuất mới',
  };
}

class ProposalSet {
  const ProposalSet({
    required this.month,
    required this.historyDays,
    required this.items,
    required this.total,
  });

  factory ProposalSet.fromJson(Map<String, dynamic> j) => ProposalSet(
    month: '${j['month']}',
    historyDays: _int(j['history_days']),
    items: [
      for (final e in (j['items'] as List? ?? const []))
        BudgetProposal.fromJson((e as Map).cast<String, dynamic>()),
    ],
    total: j['total'] == null
        ? null
        : BudgetProposal.fromJson((j['total'] as Map).cast<String, dynamic>()),
  );

  final String month;
  final int historyDays;
  final List<BudgetProposal> items;
  final BudgetProposal? total;

  List<BudgetProposal> get all => [...items, ?total];
  bool get hasChanges => all.any((p) => p.isChange);
}

class PaceItem {
  const PaceItem({
    required this.categoryId,
    required this.name,
    required this.icon,
    required this.limit,
    required this.spent,
    required this.todaySpent,
    required this.dailyAllowance,
    required this.safeToday,
    required this.aheadPct,
    required this.status,
  });

  factory PaceItem.fromJson(Map<String, dynamic> j) => PaceItem(
    categoryId: j['category_id'] as String?,
    name: '${j['name'] ?? ''}',
    icon: j['icon'] as String?,
    limit: _int(j['limit']),
    spent: _int(j['spent']),
    todaySpent: _int(j['today_spent']),
    dailyAllowance: _int(j['daily_allowance']),
    safeToday: _int(j['safe_today']),
    aheadPct: _int(j['ahead_pct']),
    status: '${j['status'] ?? 'ok'}',
  );

  final String? categoryId;
  final String name;
  final String? icon;
  final int limit;
  final int spent;
  final int todaySpent;
  final int dailyAllowance;
  final int safeToday;
  final int aheadPct;

  /// ok | fast | over
  final String status;
}

class Pacing {
  const Pacing({
    required this.daysLeft,
    required this.items,
    required this.overall,
  });

  factory Pacing.fromJson(Map<String, dynamic> j) => Pacing(
    daysLeft: _int(j['days_left']),
    items: [
      for (final e in (j['items'] as List? ?? const []))
        PaceItem.fromJson((e as Map).cast<String, dynamic>()),
    ],
    overall: j['overall'] == null
        ? null
        : PaceItem.fromJson((j['overall'] as Map).cast<String, dynamic>()),
  );

  final int daysLeft;
  final List<PaceItem> items;
  final PaceItem? overall;

  bool get isEmpty => items.isEmpty && overall == null;

  /// "Hôm nay còn tiêu được": the overall budget when set, otherwise the sum over category budgets.
  int get safeToday =>
      overall?.safeToday ?? items.fold(0, (s, i) => s + i.safeToday);
}

String currentBudgetMonth([DateTime? now]) {
  final n = now ?? DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
}

/// Never fails the screen: an unavailable endpoint (older server, offline without cache) simply shows nothing.
final budgetProposalsProvider = FutureProvider.autoDispose<ProposalSet?>((
  ref,
) async {
  try {
    final r = await ref
        .watch(apiProvider)
        .get('/budgets/proposals', query: {'month': currentBudgetMonth()});
    return ProposalSet.fromJson((r as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
});

final budgetPacingProvider = FutureProvider.autoDispose<Pacing?>((ref) async {
  try {
    final r = await ref.watch(apiProvider).get('/budgets/pacing');
    return Pacing.fromJson((r as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
});

/// "5,2tr" / "120k" for tight spaces.
String shortMoney(int n) {
  if (n >= 1000000) {
    final v = (n / 100000).round() / 10;
    final s = v == v.roundToDouble() ? v.toInt().toString() : '$v';
    return '${s.replaceAll('.', ',')}tr';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$nđ';
}
