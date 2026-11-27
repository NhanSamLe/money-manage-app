import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/push.dart';
import 'package:moma/core/ui/moma_switch.dart';
import 'package:moma/core/ui/motion.dart';
import 'package:moma/features/insights/insights_page.dart';
import 'package:moma/features/reminders/reminder_settings_page.dart';
import 'package:moma/features/reminders/today_meals_card.dart';

import 'support/fake_api.dart';

/// FakeApi plus recorded POST/PUT calls answered from [postReplies].
class _Api extends FakeApi {
  _Api(Map<String, dynamic> extra)
    : super(data: {...FakeApi.defaultData(), ...extra});
  final posts = <({String path, Object body})>[];
  final puts = <({String path, Object body})>[];
  final Map<String, Object? Function(Object body)> postReplies = {};

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path: path, body: body));
    return postReplies[path]?.call(body);
  }

  @override
  Future<dynamic> put(String path, Object body) async {
    puts.add((path: path, body: body));
    return body;
  }
}

Map<String, dynamic> _insight(
  String id,
  String title, {
  String created = '2026-11-28T08:00:00Z',
}) => {
  'id': id,
  'period': 'MONTH',
  'period_start': '2026-11-01',
  'period_end': '2026-11-30',
  'created_at': created,
  'title': title,
  'summary': 'Chi tiêu tháng này tăng nhẹ so với tháng trước.',
  'highlights': ['Ăn uống chiếm phần lớn chi tiêu'],
  'suggestions': ['Đặt hạn mức ăn uống 2.000.000 ₫'],
  'numbers': {
    'income': '15000000',
    'expense': '4500000',
    'net': '10500000',
    'prev_expense': '4000000',
    'change_pct': 12.5,
    'by_category': [
      {
        'category_id': 'c-food',
        'name': 'Ăn uống',
        'amount': '2500000',
        'prev_amount': '2000000',
        'change_pct': 25,
      },
      {
        'category_id': 'c-move',
        'name': 'Di chuyển',
        'amount': '500000',
        'prev_amount': '800000',
        'change_pct': -37.5,
      },
    ],
    'forecast_expense': '5200000',
    'suggested_limit': '4800000',
    'daily_avg': '150000',
  },
};

Widget _host(Widget page, FakeApi api) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('home')),
        routes: [GoRoute(path: 'page', builder: (_, _) => page)],
      ),
      GoRoute(
        path: '/insights/:id',
        builder: (_, s) => InsightDetailPage(id: s.pathParameters['id']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [apiProvider.overrideWithValue(api)],
    child: MaterialApp.router(
      theme: ThemeData(useMaterial3: true),
      routerConfig: router,
    ),
  );
}

Future<void> _open(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  GoRouter.of(tester.element(find.text('home'))).push('/page');
  await tester.pumpAndSettle();
}

Map<String, dynamic> _settings() => {
  'meals': {
    'breakfast': {'enabled': true, 'time': '07:30'},
    'lunch': {'enabled': true, 'time': '12:00'},
    'dinner': {'enabled': false, 'time': '19:00'},
  },
  'cash_check': {'enabled': false, 'time': '21:00'},
  'daily_review': {'enabled': true, 'time': '21:30'},
  'weekly_review': {'enabled': true, 'weekday': 7, 'time': '20:00'},
  'monthly_review': {'enabled': false, 'time': '20:00'},
  'budget_alerts': {'enabled': true},
};

void main() {
  setUpAll(() => Motion.continuous = false);

  group('insights', () {
    testWidgets('renders latest analysis, numbers, categories and history', (
      tester,
    ) async {
      final api = _Api({
        '/insights': [
          _insight('i2', 'Tháng 10 ổn định', created: '2026-11-01T08:00:00Z'),
          _insight('i1', 'Chi tiêu tháng 11'),
        ],
        '/insights/i2': _insight('i2', 'Tháng 10 ổn định'),
      });
      await _open(tester, _host(const InsightsPage(), api));
      expect(find.text('Chi tiêu tháng 11'), findsOneWidget);
      expect(find.text('15.000.000 ₫'), findsOneWidget);
      expect(find.text('+12,5%'), findsOneWidget);
      expect(find.text('5.200.000 ₫'), findsOneWidget);
      expect(find.text('4.800.000 ₫'), findsOneWidget);
      expect(find.text('Ăn uống chiếm phần lớn chi tiêu'), findsOneWidget);
      expect(find.text('Đặt hạn mức ăn uống 2.000.000 ₫'), findsOneWidget);
      await _scrollTo(tester, find.text('Di chuyển'));
      expect(find.text('-37,5%'), findsOneWidget);
      // Older analyses open their detail page.
      await _scrollTo(tester, find.text('Tháng 10 ổn định'));
      await tester.tap(find.text('Tháng 10 ổn định'));
      await tester.pumpAndSettle();
      expect(find.text('Chi tiết phân tích'), findsOneWidget);
    });

    testWidgets('run now with a reused result shows the snack', (tester) async {
      final api = _Api({'/insights': <Object>[]});
      api.postReplies['/insights/run'] = (_) => {
        ..._insight('i1', 'Chi tiêu tháng 11'),
        'reused': true,
      };
      await _open(tester, _host(const InsightsPage(), api));
      expect(find.text('Chưa có phân tích'), findsOneWidget);
      await tester.tap(find.text('Phân tích ngay'));
      await tester.pumpAndSettle();
      expect(api.posts.single.path, '/insights/run');
      expect(api.posts.single.body, {'period': 'MONTH'});
      expect(
        find.text('Đã có phân tích gần đây, hiển thị kết quả mới nhất'),
        findsOneWidget,
      );
    });

    testWidgets('missing endpoint shows a friendly empty state', (
      tester,
    ) async {
      await _open(tester, _host(const InsightsPage(), _Api({})));
      expect(find.text('Tính năng sắp có'), findsOneWidget);
    });
  });

  group('reminders', () {
    testWidgets('settings save sends the full payload', (tester) async {
      final api = _Api({'/reminders/settings': _settings()});
      await _open(tester, _host(const ReminderSettingsPage(), api));
      // Switch order: breakfast, lunch, dinner, cash check, ...
      await tester.tap(find.byType(MomaSwitch).at(3));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Lưu cài đặt'));
      await tester.tap(find.text('Lưu cài đặt'));
      await tester.pumpAndSettle();
      final put = api.puts.single;
      expect(put.path, '/reminders/settings');
      final body = put.body as Map<String, dynamic>;
      expect(body['cash_check'], {'enabled': true, 'time': '21:00'});
      expect(body['meals']['breakfast'], {'enabled': true, 'time': '07:30'});
      expect(body['meals']['dinner'], {'enabled': false, 'time': '19:00'});
      expect(body['weekly_review'], {
        'enabled': true,
        'time': '20:00',
        'weekday': 7,
      });
      expect(body['budget_alerts'], {'enabled': true});
    });

    testWidgets('meal times out of order are refused', (tester) async {
      final s = _settings();
      (s['meals'] as Map)['lunch'] = {'enabled': true, 'time': '07:00'};
      final api = _Api({'/reminders/settings': s});
      await _open(tester, _host(const ReminderSettingsPage(), api));
      await _scrollTo(tester, find.text('Lưu cài đặt'));
      await tester.tap(find.text('Lưu cài đặt'));
      await tester.pumpAndSettle();
      expect(api.puts, isEmpty);
      expect(find.text('Giờ bữa trưa phải sau bữa sáng'), findsOneWidget);
    });

    testWidgets('today meals card marks a meal as skipped', (tester) async {
      final api = _Api({
        '/reminders/today': {
          'date': '2026-11-28',
          'skipped': <String>[],
          'done': {'breakfast': true, 'lunch': false, 'dinner': false},
        },
      });
      api.postReplies['/reminders/skip'] = (_) => {
        'date': '2026-11-28',
        'skipped': ['lunch'],
        'done': {'breakfast': true, 'lunch': false, 'dinner': false},
      };
      await _open(tester, _host(const Scaffold(body: TodayMealsCard()), api));
      expect(find.text('Đã ghi'), findsOneWidget);
      expect(find.text('Chưa ghi'), findsNWidgets(2));
      // Breakfast is logged, so only lunch and dinner have a switch.
      expect(find.byType(MomaSwitch), findsNWidgets(2));
      await tester.tap(find.byType(MomaSwitch).first);
      await tester.pumpAndSettle();
      expect(api.posts.single.path, '/reminders/skip');
      expect(api.posts.single.body, {'kind': 'lunch', 'skip': true});
      expect(find.text('Bỏ qua hôm nay'), findsOneWidget);
      expect(find.text('Chưa ghi'), findsOneWidget);
    });
  });

  group('push', () {
    test('routes from payload', () {
      expect(Push.routeFor({'type': 'insight', 'id': 'x1'}), '/insights/x1');
      expect(
        Push.routeFor({
          'type': 'reminder',
          'kind': 'lunch',
          'route': '/quick-entry',
        }),
        '/quick-entry',
      );
      expect(Push.routeFor({'type': 'bank_tx'}), isNull);
    });

    test('skip action posts a skip for today', () async {
      final api = _Api({});
      Push.apiFactory = () => api;
      final before = Push.remindersChanged.value;
      await Push.handleClick('skip_dinner', {
        'type': 'reminder',
        'kind': 'dinner',
      });
      expect(api.posts.single.path, '/reminders/skip');
      expect(api.posts.single.body, {'kind': 'dinner', 'skip': true});
      expect(Push.remindersChanged.value, before + 1);
    });
  });
}

/// Scrolls the page's list until [f] is built and visible (ListView builds lazily).
Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}
