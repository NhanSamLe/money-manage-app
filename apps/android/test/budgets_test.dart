import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/outbox.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/budgets/budget_plan.dart';
import 'package:moma/features/budgets/budget_widgets.dart';
import 'package:moma/features/widgets/routine_quick.dart';

import 'support/fake_api.dart';

const _food = '11111111-1111-4111-8111-000000000001';
const _move = '11111111-1111-4111-8111-000000000003';

Map<String, dynamic> _proposals() => {
  'month': '2026-12',
  'history_days': 60,
  'items': [
    {
      'category_id': _food,
      'name': 'Ăn uống',
      'icon': 'restaurant',
      'proposed': 3300000,
      'monthly_avg': 3100000,
      'current_limit': null,
      'reason': 'new',
      'note': 'Trung bình khoảng 3.100.000đ/tháng · dựa trên 60 ngày gần nhất',
    },
    {
      'category_id': _move,
      'name': 'Di chuyển',
      'icon': 'directions_car',
      'proposed': 800000,
      'monthly_avg': 750000,
      'current_limit': 800000,
      'reason': 'keep',
      'note': 'Mức hiện tại vẫn hợp lý',
    },
  ],
  'total': {
    'category_id': null,
    'name': 'Tổng chi tiêu',
    'proposed': 4650000,
    'monthly_avg': 4650000,
    'current_limit': null,
    'reason': 'new',
    'note': 'Gồm 550.000đ chi cố định hằng tháng',
  },
};

Map<String, dynamic> _pacing({bool empty = false}) => {
  'month': '2026-12',
  'day': 10,
  'days_in_month': 31,
  'days_left': 22,
  'items': empty
      ? []
      : [
          {
            'category_id': _food,
            'name': 'Ăn uống',
            'icon': 'restaurant',
            'limit': 3000000,
            'spent': 1300000,
            'today_spent': 30000,
            'remaining': 1700000,
            'daily_allowance': 80000,
            'safe_today': 50000,
            'expected_by_now': 967742,
            'ahead_pct': 34,
            'status': 'fast',
          },
        ],
  'overall': null,
};

class _BudgetApi extends FakeApi {
  _BudgetApi({bool emptyPacing = false, this.offline = false})
    : super(
        data: {
          ...FakeApi.defaultData(),
          '/budgets/proposals': _proposals(),
          '/budgets/pacing': _pacing(empty: emptyPacing),
          '/budgets': <Object>[],
        },
      );
  final bool offline;
  final posts = <(String, Object)>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path, body));
    if (offline) {
      throw ApiException('OFFLINE', 'offline', retryable: true);
    }
    if (path == '/budgets/proposals/apply') {
      return {
        'month': '2026-12',
        'applied': ((body as Map)['items'] as List).length,
      };
    }
    if (path == '/ai/routine/record') {
      return {'message': 'Đã ghi Bánh mì 20.000đ'};
    }
    return const {};
  }
}

class _MemoryOutbox extends OutboxStore {
  List<PendingCommand> saved = [];
  @override
  Future<List<PendingCommand>> load() async => saved;
  @override
  Future<void> save(List<PendingCommand> items) async => saved = items;
}

Widget _host(ApiClient api, Widget child) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: buildMomaTheme(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  test('pacing parses and sums safe-to-spend over categories without an overall budget', () {
    final p = Pacing.fromJson(_pacing());
    expect(p.daysLeft, 22);
    expect(p.safeToday, 50000);
    expect(p.items.single.status, 'fast');
    final s = ProposalSet.fromJson(_proposals());
    expect(s.all, hasLength(3));
    expect(s.hasChanges, isTrue);
    expect(s.items[1].isChange, isFalse);
    expect(shortMoney(3300000), '3,3tr');
    expect(shortMoney(120000), '120k');
  });

  testWidgets(
    'pacing card: safe-to-spend, the fast category with its daily amount, masked when hidden',
    (tester) async {
      await tester.pumpWidget(_host(_BudgetApi(), const BudgetPacingCard()));
      await tester.pumpAndSettle();
      expect(find.text('Hôm nay còn tiêu được'), findsOneWidget);
      expect(find.textContaining('50.000'), findsOneWidget);
      expect(find.text('Còn 22 ngày'), findsOneWidget);
      expect(find.textContaining('Nhanh hơn 34%'), findsOneWidget);
      expect(find.textContaining('80.000'), findsOneWidget);

      await tester.pumpWidget(
        _host(_BudgetApi(), const BudgetPacingCard(hidden: true, mask: '••••')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('50.000'), findsNothing);
    },
  );

  testWidgets(
    'no budgets yet: the card offers MoMa\'s proposal, the sheet applies the changes in one tap',
    (tester) async {
      final api = _BudgetApi(emptyPacing: true);
      await tester.pumpWidget(_host(api, const BudgetPacingCard()));
      await tester.pumpAndSettle();
      expect(find.text('Để MoMa đặt ngân sách giúp bạn'), findsOneWidget);
      await tester.tap(find.text('Xem'));
      await tester.pumpAndSettle();

      expect(find.text('Ngân sách đề xuất tháng 12/2026'), findsOneWidget);
      expect(find.text('Đề xuất mới'), findsNWidgets(2));
      expect(find.text('Giữ nguyên'), findsOneWidget);
      // "keep" is not pre-selected: 2 of 3 are applied.
      expect(find.text('Áp dụng 2 ngân sách'), findsOneWidget);
      await tester.ensureVisible(find.text('Áp dụng 2 ngân sách'));
      await tester.tap(find.text('Áp dụng 2 ngân sách'));
      await tester.pumpAndSettle();

      final (path, body) = api.posts.single;
      expect(path, '/budgets/proposals/apply');
      final items = (body as Map)['items'] as List;
      expect(items, [
        {'category_id': _food, 'limit': '3300000'},
        {'category_id': null, 'limit': '4650000'},
      ]);
      expect(find.text('Đã đặt 2 ngân sách.'), findsOneWidget);
    },
  );

  testWidgets(
    'proposal sheet: offline apply explains instead of failing silently',
    (tester) async {
      final api = _BudgetApi(emptyPacing: true, offline: true);
      await tester.pumpWidget(_host(api, const BudgetPacingCard()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xem'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Áp dụng 2 ngân sách'));
      await tester.tap(find.text('Áp dụng 2 ngân sách'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cần có mạng'), findsOneWidget);
    },
  );

  group('routine one-tap outside the app', () {
    test('command id matches the server derivation (routes-agent routineCommandId)', () {
      expect(
        routineCommandId('owner-1', '2026-12-02', 'breakfast', 'banh mi'),
        '70e47b9d-4c7d-4135-a7d4-212b41e9790e',
      );
    });

    test('stored routine is ignored after its slot window', () async {
      const opts =
          '[{"key":"banh mi","label":"Bánh mì","amount":20000,"account_id":"a2","category_id":"c-food"}]';
      final now = DateTime(2026, 12, 2, 8);
      final r = await storedQuickRoutine(
        slot: 'breakfast',
        question: 'Sáng nay bạn ăn gì?',
        options: opts,
        until: routineSlotEnd('breakfast', now).millisecondsSinceEpoch,
        now: now,
      );
      expect(r!.options.single.chip, 'Bánh mì 20k');
      expect(
        await storedQuickRoutine(
          slot: 'breakfast',
          question: '',
          options: opts,
          until: routineSlotEnd('breakfast', now).millisecondsSinceEpoch,
          now: DateTime(2026, 12, 2, 11),
        ),
        isNull,
      );
    });

    test('online: recorded through the routine endpoint; offline: queued once as TX_CREATE with the server id', () async {
      const o = QuickRoutineOption(
        key: 'banh mi',
        label: 'Bánh mì',
        amount: 20000,
        accountId: 'a2',
        categoryId: 'c-food',
      );
      final store = _MemoryOutbox();
      final c = ProviderContainer(
        overrides: [outboxStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final online = _BudgetApi();
      final msg = await recordQuickRoutine(
        online,
        c.read(outboxProvider.notifier),
        owner: 'owner-1',
        slot: 'breakfast',
        option: o,
      );
      expect(msg, 'Đã ghi Bánh mì 20.000đ');
      expect(online.posts.single.$1, '/ai/routine/record');
      expect(store.saved, isEmpty);

      final at = DateTime(2026, 12, 2, 7, 30);
      final offline = await recordQuickRoutine(
        _BudgetApi(offline: true),
        c.read(outboxProvider.notifier),
        owner: 'owner-1',
        slot: 'breakfast',
        option: o,
        now: at,
      );
      expect(offline, contains('Đang offline'));
      final q = store.saved.single;
      expect(q.type, 'TX_CREATE');
      expect(q.commandId, '70e47b9d-4c7d-4135-a7d4-212b41e9790e');
      expect(q.payload, containsPair('amount', '20000'));
      expect(q.payload, containsPair('category_id', 'c-food'));
      expect(q.payload, containsPair('source', 'AI'));
    });
  });
}
