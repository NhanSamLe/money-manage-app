import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

// Kế hoạch & Dự toán (API /v1/plans/*, migration 021, D-027): event estimates + plan vs actual, life-plan projections.
// The life-plan math is mirrored from the API (apps/api/src/modules/plans/project.ts) so the what-if sliders answer
// instantly and offline; saved numbers always come from the server.

int _int(Object? v) =>
    v == null ? 0 : (v is num ? v.round() : (num.tryParse('$v') ?? 0).round());
double? _dbl(Object? v) =>
    v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

const eventKindLabels = {
  'NHAU': 'Đi nhậu',
  'AN_UONG': 'Ăn uống',
  'CAFE': 'Cà phê',
  'TIEC': 'Tiệc',
  'SINH_NHAT': 'Sinh nhật',
  'DU_LICH': 'Du lịch',
  'KHAC': 'Khác',
};

const lifeKindLabels = {
  'HOUSE': 'Nhà',
  'CAR': 'Xe',
  'TRAVEL': 'Du lịch',
  'WEDDING': 'Cưới',
  'EDUCATION': 'Học tập',
  'OTHER': 'Khác',
};

class EstimateItem {
  const EstimateItem(this.key, this.label, this.amount);
  final String key;
  final String label;
  final int amount;
}

class Band {
  const Band(this.low, this.likely, this.high);
  factory Band.fromJson(Object? j) {
    final m = (j as Map?) ?? const {};
    return Band(_int(m['low']), _int(m['likely']), _int(m['high']));
  }
  final int low;
  final int likely;
  final int high;
}

class EventEstimate {
  const EventEstimate({
    required this.kind,
    required this.headcount,
    required this.ownerPays,
    required this.total,
    required this.owner,
    required this.items,
    required this.assumptions,
    required this.summary,
    required this.samples,
  });

  factory EventEstimate.fromJson(Map<String, dynamic> j) => EventEstimate(
    kind: '${j['kind'] ?? 'KHAC'}',
    headcount: _int(j['headcount']).clamp(1, 500),
    ownerPays: j['owner_pays'] == true,
    total: Band.fromJson(j['total']),
    owner: Band.fromJson(j['owner']),
    items: [
      for (final i in (j['breakdown'] as List? ?? const []))
        EstimateItem(
          '${(i as Map)['key']}',
          '${i['label']}',
          _int(i['amount']),
        ),
    ],
    assumptions: [
      for (final a in (j['assumptions'] as List? ?? const [])) '$a',
    ],
    summary: '${j['summary'] ?? ''}',
    samples: _int((j['basis'] as Map?)?['samples']),
  );

  final String kind;
  final int headcount;
  final bool ownerPays;
  final Band total;
  final Band owner;
  final List<EstimateItem> items;
  final List<String> assumptions;
  final String summary;
  final int samples;
}

class EventActual {
  const EventActual({
    required this.total,
    required this.owner,
    required this.food,
    required this.rides,
    required this.other,
    required this.count,
    this.summary,
    this.pct,
  });

  /// From a stored `actual` ({…, comparison}) or a live `{actual, comparison}`.
  factory EventActual.fromJson(
    Map<String, dynamic> a, [
    Map<String, dynamic>? comparison,
  ]) {
    final b = (a['buckets'] as Map?) ?? const {};
    final c = comparison ?? (a['comparison'] as Map?)?.cast<String, dynamic>();
    return EventActual(
      total: _int(a['total']),
      owner: _int(a['owner']),
      food: _int(b['food']),
      rides: _int(b['rides']),
      other: _int(b['other']),
      count: _int(a['count']),
      summary: c?['summary'] as String?,
      pct: c == null ? null : _int(c['pct']),
    );
  }

  final int total;
  final int owner;
  final int food;
  final int rides;
  final int other;
  final int count;
  final String? summary;
  final int? pct;
}

class EventPlan {
  const EventPlan({
    required this.id,
    required this.title,
    required this.kind,
    required this.startsAt,
    required this.endsAt,
    required this.headcount,
    required this.people,
    required this.place,
    required this.ownerPays,
    required this.state,
    required this.estimate,
    required this.actual,
  });

  factory EventPlan.fromJson(Map<String, dynamic> j) {
    final live = (j['live'] as Map?)?.cast<String, dynamic>();
    final stored = (j['actual'] as Map?)?.cast<String, dynamic>();
    return EventPlan(
      id: '${j['id']}',
      title: '${j['title']}',
      kind: '${j['kind'] ?? 'KHAC'}',
      startsAt:
          DateTime.tryParse('${j['starts_at']}')?.toLocal() ?? DateTime.now(),
      endsAt: DateTime.tryParse('${j['ends_at']}')?.toLocal() ?? DateTime.now(),
      headcount: _int(j['headcount']).clamp(1, 500),
      people: [for (final p in (j['people'] as List? ?? const [])) '$p'],
      place: j['place'] as String?,
      ownerPays: j['owner_pays'] == true,
      state: '${j['state'] ?? 'PLANNED'}',
      estimate: EventEstimate.fromJson(
        ((j['estimate'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      actual: stored != null
          ? EventActual.fromJson(stored)
          : live != null
          ? EventActual.fromJson(
              (live['actual'] as Map).cast<String, dynamic>(),
              (live['comparison'] as Map?)?.cast<String, dynamic>(),
            )
          : null,
    );
  }

  final String id;
  final String title;
  final String kind;
  final DateTime startsAt;
  final DateTime endsAt;
  final int headcount;
  final List<String> people;
  final String? place;
  final bool ownerPays;
  final String state;
  final EventEstimate estimate;
  final EventActual? actual;

  bool get done => state == 'DONE';
  bool get cancelled => state == 'CANCELLED';
  bool get upcoming => state == 'PLANNED' && endsAt.isAfter(DateTime.now());
}

// ---------------------------------------------------------------- life plans
class PlanBaseline {
  const PlanBaseline({
    required this.income,
    required this.expense,
    required this.saving,
    required this.monthsUsed,
    required this.available,
  });
  factory PlanBaseline.fromJson(Map<String, dynamic> j) => PlanBaseline(
    income: _int(j['monthly_income']),
    expense: _int(j['monthly_expense']),
    saving: _int(j['monthly_saving']),
    monthsUsed: _int(j['months_used']),
    available: _int(j['available']),
  );
  final int income;
  final int expense;
  final int saving;
  final int monthsUsed;
  final int available;
}

class LifeParams {
  const LifeParams({
    required this.name,
    required this.kind,
    required this.price,
    required this.downPct,
    this.loanRatePct,
    this.loanYears = 0,
    this.inflationPct,
    this.incomeGrowthPct,
    this.extraSaving = 0,
    this.savedNow,
  });

  final String name;
  final String kind;
  final int price;
  final double downPct;
  final double? loanRatePct;
  final int loanYears;
  final double? inflationPct;
  final double? incomeGrowthPct;
  final int extraSaving;
  final int? savedNow;

  LifeParams copyWith({
    double? downPct,
    double? inflationPct,
    double? incomeGrowthPct,
    int? extraSaving,
  }) => LifeParams(
    name: name,
    kind: kind,
    price: price,
    downPct: downPct ?? this.downPct,
    loanRatePct: loanRatePct,
    loanYears: loanYears,
    inflationPct: inflationPct ?? this.inflationPct,
    incomeGrowthPct: incomeGrowthPct ?? this.incomeGrowthPct,
    extraSaving: extraSaving ?? this.extraSaving,
    savedNow: savedNow,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'price': price,
    'down_pct': downPct,
    'loan_years': loanYears,
    'loan_rate_pct': ?loanRatePct,
    'inflation_pct': ?inflationPct,
    'income_growth_pct': ?incomeGrowthPct,
    'extra_saving': extraSaving,
  };
}

class LifePlan {
  const LifePlan({
    required this.id,
    required this.params,
    required this.goalId,
    required this.projection,
  });
  factory LifePlan.fromJson(Map<String, dynamic> j) => LifePlan(
    id: '${j['id']}',
    goalId: j['goal_id'] as String?,
    params: LifeParams(
      name: '${j['name']}',
      kind: '${j['kind'] ?? 'OTHER'}',
      price: _int(j['price']),
      downPct: _dbl(j['down_pct']) ?? 100,
      loanRatePct: _dbl(j['loan_rate_pct']) == 0
          ? null
          : _dbl(j['loan_rate_pct']),
      loanYears: _int(j['loan_years']),
      inflationPct: _dbl(j['inflation_pct']),
      incomeGrowthPct: _dbl(j['income_growth_pct']),
      extraSaving: _int(j['extra_saving']),
      savedNow: j['projection'] is Map
          ? _int((j['projection'] as Map)['saved_now'])
          : null,
    ),
    projection: j['projection'] is Map
        ? Projection.fromJson((j['projection'] as Map).cast<String, dynamic>())
        : null,
  );
  final String id;
  final String? goalId;
  final LifeParams params;
  final Projection? projection;
}

class YearPoint {
  const YearPoint(this.month, this.saved, this.needed);
  final String month;
  final int saved;
  final int needed;
}

class Projection {
  const Projection({
    required this.reachable,
    required this.months,
    required this.reachMonth,
    required this.neededThen,
    required this.savedNow,
    required this.monthlySaving,
    required this.loanAmount,
    required this.monthlyPayment,
    required this.timeline,
    required this.summary,
    this.assumptions = const [],
  });

  factory Projection.fromJson(Map<String, dynamic> j) => Projection(
    reachable: j['reachable'] == true,
    months: j['months'] == null ? null : _int(j['months']),
    reachMonth: j['reach_month'] as String?,
    neededThen: _int(j['needed_then']),
    savedNow: _int(j['saved_now']),
    monthlySaving: _int(j['monthly_saving']),
    loanAmount: _int(j['loan_amount']),
    monthlyPayment: _int(j['monthly_payment']),
    timeline: [
      for (final p in (j['timeline'] as List? ?? const []))
        YearPoint(
          '${(p as Map)['month']}',
          _int(p['saved']),
          _int(p['needed']),
        ),
    ],
    summary: '${j['summary'] ?? ''}',
    assumptions: [
      for (final a in (j['assumptions'] as List? ?? const [])) '$a',
    ],
  );

  final bool reachable;
  final int? months;
  final String? reachMonth;
  final int neededThen;
  final int savedNow;
  final int monthlySaving;
  final int loanAmount;
  final int monthlyPayment;
  final List<YearPoint> timeline;
  final String summary;
  final List<String> assumptions;
}

// ---------------------------------------------------------------- math (mirror of project.ts)
/// Market defaults (same as the API's DEFAULT_MARKET).
double defaultInflation(String kind) =>
    const {
      'HOUSE': 6.0,
      'CAR': 1.5,
      'TRAVEL': 4.0,
      'WEDDING': 5.0,
      'EDUCATION': 6.0,
    }[kind] ??
    3.5;
double defaultLoanRate(String kind) =>
    kind == 'HOUSE' ? 9 : (kind == 'CAR' ? 9.5 : 12);
const double kCpiPct = 3.5;
const double kDepositPct = 4.5;

double loanPayment(num principal, double yearlyRatePct, int years) {
  if (principal <= 0 || years <= 0) return 0;
  final n = years * 12;
  final r = yearlyRatePct / 100 / 12;
  if (r == 0) return principal / n;
  return principal * r / (1 - math.pow(1 + r, -n));
}

String addMonths(String ym, int n) {
  final y = int.parse(ym.substring(0, 4));
  final m = int.parse(ym.substring(5, 7));
  final t = y * 12 + (m - 1) + n;
  return '${t ~/ 12}-${((t % 12) + 1).toString().padLeft(2, '0')}';
}

/// "T9/2035".
String monthLabel(String? ym) => ym == null
    ? 'chưa xác định'
    : 'T${int.parse(ym.substring(5, 7))}/${ym.substring(0, 4)}';

String vnMonth([DateTime? now]) => (now ?? DateTime.now())
    .toUtc()
    .add(const Duration(hours: 7))
    .toIso8601String()
    .substring(0, 7);

/// Months until the down payment is saved (null = not within 50 years) + the yearly timeline.
({int? months, double neededThen, double priceThen, List<YearPoint> timeline})
simulateLife(
  LifeParams p,
  PlanBaseline b,
  String nowMonth, {
  double cpiPct = kCpiPct,
  double depositPct = kDepositPct,
}) {
  final g = (p.incomeGrowthPct ?? cpiPct) / 100;
  final cpi = cpiPct / 100;
  final dep = depositPct / 100 / 12;
  final infl = (p.inflationPct ?? defaultInflation(p.kind)) / 100;
  var saved = (p.savedNow ?? b.available).toDouble().clamp(0, double.infinity);
  final timeline = <YearPoint>[];
  for (var n = 0; n <= 600; n++) {
    final years = n / 12;
    final price = p.price * math.pow(1 + infl, years);
    final needed = price * p.downPct / 100;
    final point = YearPoint(
      addMonths(nowMonth, n),
      saved.round(),
      needed.round(),
    );
    if (n % 12 == 0) timeline.add(point);
    if (saved >= needed) {
      if (n % 12 != 0) timeline.add(point);
      return (
        months: n,
        neededThen: needed,
        priceThen: price.toDouble(),
        timeline: timeline,
      );
    }
    final income = b.income * math.pow(1 + g, years);
    final expense = b.expense * math.pow(1 + cpi, years);
    final monthly = income - expense + p.extraSaving;
    saved = saved * (1 + dep) + math.max(0, monthly);
    if (monthly <= 0 && n > 24 && infl >= dep * 12) break;
  }
  final price = p.price * math.pow(1 + infl, 50);
  return (
    months: null,
    neededThen: price * p.downPct / 100,
    priceThen: price.toDouble(),
    timeline: timeline,
  );
}

/// Instant local projection for the what-if sliders.
Projection projectLocal(LifeParams p, PlanBaseline b, [DateTime? now]) {
  final nowMonth = vnMonth(now);
  final s = simulateLife(p, b, nowMonth);
  final loan = math.max(0.0, s.priceThen - s.neededThen);
  final payment = p.downPct >= 100
      ? 0.0
      : loanPayment(
          loan,
          p.loanRatePct ?? defaultLoanRate(p.kind),
          p.loanYears,
        );
  final reach = s.months == null ? null : addMonths(nowMonth, s.months!);
  return Projection(
    reachable: s.months != null,
    months: s.months,
    reachMonth: reach,
    neededThen: s.neededThen.round(),
    savedNow: (p.savedNow ?? b.available),
    monthlySaving: b.saving + p.extraSaving,
    loanAmount: p.downPct >= 100 ? 0 : loan.round(),
    monthlyPayment: payment.round(),
    timeline: s.timeline,
    summary: s.months == null
        ? 'Chưa đạt được trong 50 năm với mức tích lũy này'
        : 'Dự kiến đạt ~${monthLabel(reach)}',
  );
}

/// "1,2tr" / "2,5 tỷ" / "850k".
String shortVnd(num n) {
  String t(double x) => ((x * 10).round() / 10)
      .toString()
      .replaceAll('.0', '')
      .replaceAll('.', ',');
  if (n >= 1e9) return '${t(n / 1e9)} tỷ';
  if (n >= 1e6) return '${t(n / 1e6)}tr';
  if (n >= 1e3) return '${(n / 1e3).round()}k';
  return '${n.round()}đ';
}

// ---------------------------------------------------------------- providers
final eventPlansProvider = FutureProvider.autoDispose<List<EventPlan>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/plans/events');
  return [
    for (final e in (data as List? ?? const []))
      EventPlan.fromJson((e as Map).cast<String, dynamic>()),
  ];
});

final eventPlanProvider = FutureProvider.autoDispose.family<EventPlan, String>((
  ref,
  id,
) async {
  final data = await ref.watch(apiProvider).get('/plans/events/$id');
  return EventPlan.fromJson((data as Map).cast<String, dynamic>());
});

final lifePlansProvider =
    FutureProvider.autoDispose<({PlanBaseline baseline, List<LifePlan> plans})>(
      (ref) async {
        final data = ((await ref.watch(apiProvider).get('/plans/life')) as Map)
            .cast<String, dynamic>();
        return (
          baseline: PlanBaseline.fromJson(
            ((data['baseline'] as Map?) ?? const {}).cast<String, dynamic>(),
          ),
          plans: [
            for (final p in (data['plans'] as List? ?? const []))
              LifePlan.fromJson((p as Map).cast<String, dynamic>()),
          ],
        );
      },
    );

void refreshPlans(WidgetRef ref) {
  ref.invalidate(eventPlansProvider);
  ref.invalidate(lifePlansProvider);
}
