import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/plans/plan_pages.dart';
import 'package:moma/features/plans/plans_models.dart';
import 'package:moma/features/plans/plans_view.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _estimate({int owner = 450000, int total = 1300000}) => {
  'kind': 'NHAU',
  'headcount': 4,
  'owner_pays': false,
  'total': {'low': 980000, 'likely': total, 'high': 1820000},
  'owner': {'low': 340000, 'likely': owner, 'high': 630000},
  'breakdown': [
    {'key': 'food', 'label': 'Đồ ăn', 'amount': 550000},
    {'key': 'drinks', 'label': 'Bia, nước', 'amount': 450000},
    {'key': 'rides', 'label': 'Grab đi-về ~2×70k', 'amount': 160000},
    {'key': 'misc', 'label': 'Phát sinh', 'amount': 140000},
  ],
  'assumptions': ['Chia đều 4 người (bạn tự trả Grab của mình).'],
  'summary': 'Dự kiến ~1.300.000đ (bạn trả ~450.000đ sau khi chia)',
  'basis': {'samples': 3},
};

Map<String, dynamic> _plan(
  String id, {
  String state = 'PLANNED',
  Map<String, dynamic>? actual,
  DateTime? at,
}) {
  final s = at ?? DateTime.now().add(const Duration(days: 2));
  return {
    'id': id,
    'title': 'Nhậu với nhóm Nam',
    'kind': 'NHAU',
    'starts_at': s.toUtc().toIso8601String(),
    'ends_at': s.add(const Duration(hours: 4)).toUtc().toIso8601String(),
    'headcount': 4,
    'people': ['Nam', 'Lan', 'Huy'],
    'place': 'Quận 1',
    'owner_pays': false,
    'state': state,
    'estimate': _estimate(),
    'budget': '450000',
    'actual': actual,
  };
}

final _actual = {
  'total': 1361000,
  'owner': 461000,
  'buckets': {'food': 300000, 'rides': 161000, 'other': 0},
  'count': 3,
  'comparison': {'summary': 'Thực tế 461.000đ, đúng dự toán (+2%).', 'pct': 2},
};

class _PlansApi extends FakeApi {
  _PlansApi(Map<String, dynamic> extra)
    : super(data: {...FakeApi.defaultData(), ...extra});
  final posts = <(String, Object)>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path, body));
    if (path == '/plans/events/estimate') return _estimate();
    return {'ok': true};
  }
}

Widget _host(Widget child, FakeApi api) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: buildMomaTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  group('math (same numbers as the API)', () {
    const b = PlanBaseline(
      income: 20000000,
      expense: 12000000,
      saving: 8000000,
      monthsUsed: 6,
      available: 80000000,
    );

    test('loan payment', () {
      expect(loanPayment(1000000000, 9, 20), closeTo(8997260, 10));
      expect(loanPayment(120000000, 0, 1), 10000000);
    });

    test('house 1 tỷ, 30 % down, flat market: 28 months', () {
      const p = LifeParams(
        name: 'Căn hộ',
        kind: 'HOUSE',
        price: 1000000000,
        downPct: 30,
        loanYears: 20,
        inflationPct: 0,
        incomeGrowthPct: 0,
      );
      final s = simulateLife(p, b, '2026-11', cpiPct: 0, depositPct: 0);
      expect(s.months, 28);
      expect(addMonths('2026-11', 28), '2029-03');
      expect(monthLabel('2029-03'), 'T3/2029');
      final more = simulateLife(
        p.copyWith(extraSaving: 2000000),
        b,
        '2026-11',
        cpiPct: 0,
        depositPct: 0,
      );
      expect(more.months, 22);
    });

    test('spending more than earning never reaches', () {
      const broke = PlanBaseline(
        income: 10000000,
        expense: 12000000,
        saving: -2000000,
        monthsUsed: 1,
        available: 0,
      );
      const p = LifeParams(
        name: 'Xe',
        kind: 'CAR',
        price: 500000000,
        downPct: 100,
        inflationPct: 0,
      );
      expect(projectLocal(p, broke).reachable, isFalse);
    });

    test('short amounts', () {
      expect(shortVnd(2500000000), '2,5 tỷ');
      expect(shortVnd(1200000), '1,2tr');
      expect(shortVnd(850000), '850k');
    });
  });

  test('models parse stored and live actuals', () {
    final done = EventPlan.fromJson(_plan('a', state: 'DONE', actual: _actual));
    expect(done.actual!.owner, 461000);
    expect(done.actual!.summary, contains('đúng dự toán'));
    expect(done.estimate.owner.likely, 450000);
    final live = EventPlan.fromJson({
      ..._plan('b'),
      'live': {
        'actual': {
          'total': 70000,
          'owner': 70000,
          'buckets': {'food': 0, 'rides': 70000, 'other': 0},
          'count': 1,
        },
        'comparison': {'summary': 'Thực tế 70.000đ', 'pct': -84},
      },
    });
    expect(live.actual!.rides, 70000);
    expect(live.upcoming, isTrue);
  });

  testWidgets('tab: upcoming and past plans with plan vs actual, big plans', (
    tester,
  ) async {
    final api = _PlansApi({
      '/plans/events': [
        _plan('11111111-1111-4111-8111-111111111111'),
        _plan(
          '22222222-2222-4222-8222-222222222222',
          state: 'DONE',
          actual: _actual,
          at: DateTime.now().subtract(const Duration(days: 3)),
        ),
      ],
      '/plans/life': {
        'baseline': {
          'monthly_income': 20000000,
          'monthly_expense': 12000000,
          'monthly_saving': 8000000,
          'months_used': 6,
          'available': 80000000,
        },
        'plans': [
          {
            'id': '33333333-3333-4333-8333-333333333333',
            'name': 'Mua căn hộ',
            'kind': 'HOUSE',
            'price': '2500000000',
            'down_pct': 30,
            'loan_years': 20,
            'extra_saving': '0',
            'projection': {
              'reachable': true,
              'months': 100,
              'reach_month': '2035-03',
              'timeline': [],
              'summary': 'x',
            },
          },
        ],
      },
    });
    await tester.pumpWidget(_host(const PlansView(), api));
    await tester.pumpAndSettle();
    expect(find.text('Sắp tới'), findsOneWidget);
    expect(find.text('Dự toán & thực tế'), findsOneWidget);
    expect(find.text('~450k'), findsNWidgets(2));
    expect(find.text('Thực tế 461k'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Mua căn hộ'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('~T3/2035'), findsOneWidget);
    expect(find.textContaining('tích lũy ~8tr/tháng'), findsOneWidget);
  });

  testWidgets('event page: plan vs actual card and the estimate breakdown', (
    tester,
  ) async {
    const id = '22222222-2222-4222-8222-222222222222';
    final api = _PlansApi({
      '/plans/events/$id': _plan(
        id,
        state: 'DONE',
        actual: _actual,
        at: DateTime.now().subtract(const Duration(days: 1)),
      ),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: buildMomaTheme(),
          home: const EventPlanPage(id: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Thực tế vs Dự toán'), findsOneWidget);
    expect(find.text('Thực tế 461.000đ, đúng dự toán (+2%).'), findsOneWidget);
    expect(find.text('Đồ ăn'), findsOneWidget);
    expect(find.text('Grab đi-về ~2×70k'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Cập nhật thực tế'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Cập nhật thực tế'));
    await tester.pumpAndSettle();
    expect(api.posts.single.$1, '/plans/events/$id/close');
  });

  testWidgets(
    'life plan page: the extra-saving slider brings the date forward (computed on the phone)',
    (tester) async {
      const id = '33333333-3333-4333-8333-333333333333';
      final api = _PlansApi({
        '/plans/life': {
          'baseline': {
            'monthly_income': 20000000,
            'monthly_expense': 12000000,
            'monthly_saving': 8000000,
            'months_used': 6,
            'available': 80000000,
          },
          'plans': [
            {
              'id': id,
              'name': 'Mua căn hộ',
              'kind': 'HOUSE',
              'price': '1000000000',
              'down_pct': 30,
              'loan_years': 20,
              'inflation_pct': 0,
              'income_growth_pct': 0,
              'extra_saving': '0',
            },
          ],
        },
      });
      tester.view.physicalSize = const Size(1080, 2600);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWithValue(api)],
          child: MaterialApp(
            theme: buildMomaTheme(),
            home: const LifePlanPage(id: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester
          .widget<Text>(find.textContaining(RegExp(r'^~T\d+/\d{4}$')))
          .data!;
      await tester.drag(find.byType(Slider).first, const Offset(300, 0));
      await tester.pumpAndSettle();
      final after = tester
          .widget<Text>(find.textContaining(RegExp(r'^~T\d+/\d{4}$')))
          .data!;
      int months(String s) {
        final m = RegExp(r'T(\d+)/(\d{4})').firstMatch(s)!;
        return int.parse(m.group(2)!) * 12 + int.parse(m.group(1)!);
      }

      expect(months(after), lessThan(months(before)));
      expect(find.byType(ProjectionChart), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lưu kịch bản này'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Lưu kịch bản này'));
      await tester.pumpAndSettle();
      final saved = api.posts.single;
      expect(saved.$1, '/plans/life');
      expect((saved.$2 as Map)['id'], id);
      expect((saved.$2 as Map)['extra_saving'], greaterThan(0));
    },
  );

  testWidgets(
    'estimate sheet: typing shows the estimate, saving posts the plan with a stable id',
    (tester) async {
      final api = _PlansApi({});
      await tester.pumpWidget(
        _host(const SingleChildScrollView(child: EventPlanSheet()), api),
      );
      await tester.enterText(find.byType(TextField).first, 'Nhậu với nhóm Nam');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(api.posts.first.$1, '/plans/events/estimate');
      expect((api.posts.first.$2 as Map)['title'], 'Nhậu với nhóm Nam');
      expect(find.text('Phần của bạn (dự kiến)'), findsOneWidget);
      expect(find.textContaining('450.000'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lưu kế hoạch'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Lưu kế hoạch'));
      await tester.pump();
      final save = api.posts.last;
      expect(save.$1, '/plans/events');
      expect((save.$2 as Map)['id'], isA<String>());
    },
  );
}
