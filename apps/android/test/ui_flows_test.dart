import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moma/core/outbox.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/ui/motion.dart';
import 'package:moma/features/dashboard/dashboard_page.dart';
import 'package:moma/features/dashboard/reports_page.dart';
import 'package:moma/features/planning/planning_page.dart';
import 'package:moma/features/transactions/quick_entry_page.dart';
import 'package:moma/features/transactions/transactions_page.dart';

import 'support/fake_api.dart';

/// Hosts a page inside a router so `context.pop()` works the way it does in the app.
Widget host(Widget page, FakeApi api, {List<Override> extra = const []}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('home')),
        routes: [GoRoute(path: 'page', builder: (_, _) => page)],
      ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [apiProvider.overrideWithValue(api), ...extra],
    child: MaterialApp.router(
      theme: ThemeData(useMaterial3: true),
      routerConfig: router,
    ),
  );
}

Future<void> openPage(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  final context = tester.element(find.text('home'));
  GoRouter.of(context).push('/page');
  await tester.pumpAndSettle();
}

class MemoryOutbox extends OutboxStore {
  MemoryOutbox();
  List<PendingCommand> saved = [];
  @override
  Future<List<PendingCommand>> load() async => saved;
  @override
  Future<void> save(List<PendingCommand> items) async => saved = items;
}

void main() {
  setUpAll(() => Motion.continuous = false);
  group('dashboard', () {
    testWidgets('shows net worth, totals and the unknown-baseline warning', (
      tester,
    ) async {
      await openPage(
        tester,
        host(const Scaffold(body: DashboardPage()), FakeApi()),
      );
      expect(find.text('10.250.000 ₫'), findsOneWidget);
      expect(find.text('+15.000.000 ₫'), findsWidgets);
      expect(find.textContaining('chưa biết số dư đầu kỳ'), findsOneWidget);
    });

    testWidgets('reports show the category breakdown', (tester) async {
      await openPage(
        tester,
        host(const Scaffold(body: ReportsPage()), FakeApi()),
      );
      expect(find.text('Ăn uống'), findsOneWidget);
      expect(find.text('-250.000 ₫'), findsWidgets);
    });

    testWidgets('month navigation reloads for another month', (tester) async {
      await openPage(
        tester,
        host(const Scaffold(body: ReportsPage()), FakeApi()),
      );
      final before = find.byType(Text).evaluate().length;
      await tester.tap(find.byTooltip('Tháng trước'));
      await tester.pumpAndSettle();
      expect(before, greaterThan(0));
      expect(find.textContaining('Tháng '), findsOneWidget);
    });
  });

  group('transactions', () {
    testWidgets('lists, searches without diacritics and filters by kind', (
      tester,
    ) async {
      await openPage(
        tester,
        host(const Scaffold(body: TransactionsPage()), FakeApi()),
      );
      expect(find.text('Cơm trưa'), findsOneWidget);
      expect(find.text('Lương'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'com trua');
      await tester.pumpAndSettle();
      expect(find.text('Cơm trưa'), findsOneWidget);
      expect(find.text('Lương'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      // Filters open as a bottom sheet: pick "Thu nhập" from the "Loại" chip.
      await tester.tap(find.text('Loại'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thu nhập').last);
      await tester.pumpAndSettle();
      expect(find.text('Cơm trưa'), findsNothing);
      expect(find.text('Lương'), findsWidgets);
    });

    testWidgets(
      'detail offers edit/cancel, and debt-linked rows cannot be cancelled',
      (tester) async {
        final api = FakeApi();
        await openPage(
          tester,
          host(const Scaffold(body: TransactionsPage()), api),
        );
        await tester.tap(find.text('Cơm trưa'));
        await tester.pumpAndSettle();
        expect(find.text('Sửa'), findsOneWidget);
        await tester.tap(find.text('Hủy giao dịch'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xác nhận hủy'));
        await tester.pumpAndSettle();
        expect(api.commands.single.type, 'TX_REVERSE');
        expect(api.commands.single.payload['expected_version'], 2);

        await tester.tap(find.text('Thu nợ'));
        await tester.pumpAndSettle();
        expect(find.textContaining('thuộc một khoản công nợ'), findsOneWidget);
        final cancel = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Hủy giao dịch'),
        );
        expect(cancel.onPressed, isNull);
      },
    );
  });

  group('quick entry', () {
    testWidgets('free text fills the form and saves one idempotent command', (
      tester,
    ) async {
      final api = FakeApi();
      await openPage(tester, host(const QuickEntryPage(), api));
      await tester.enterText(
        find.byType(TextField).first,
        'ăn trưa 65k quán cô Ba',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('65.000'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vietcombank · Ngân hàng').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu giao dịch'));
      await tester.pumpAndSettle();

      final c = api.commands.single;
      expect(c.type, 'TX_CREATE');
      expect(c.payload['amount'], '65000');
      expect(c.payload['kind'], 'EXPENSE');
      expect(c.payload['category_id'], 'c-food');
      expect(c.payload['account_id'], 'a1');
      expect(c.payload['note'], 'ăn trưa quán cô Ba');
      expect(c.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    testWidgets('refuses to save without amount or category', (tester) async {
      final api = FakeApi();
      await openPage(tester, host(const QuickEntryPage(), api));
      await tester.tap(find.text('Lưu giao dịch'));
      await tester.pumpAndSettle();
      expect(find.text('Nhập số tiền hợp lệ.'), findsOneWidget);
      expect(api.commands, isEmpty);
    });

    testWidgets(
      'offline: the exact command is queued, never lost or duplicated',
      (tester) async {
        final api = FakeApi()
          ..failNext = ApiException(
            'OFFLINE',
            'Không kết nối',
            retryable: true,
          );
        final store = MemoryOutbox();
        await openPage(
          tester,
          host(
            const QuickEntryPage(),
            api,
            extra: [outboxStoreProvider.overrideWithValue(store)],
          ),
        );
        await tester.enterText(find.byType(TextField).first, 'cà phê 30k');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Vietcombank · Ngân hàng').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lưu giao dịch'));
        await tester.pumpAndSettle();
        expect(store.saved.single.type, 'TX_CREATE');
        expect(store.saved.single.payload['amount'], '30000');
      },
    );
  });

  group('planning', () {
    testWidgets('debts tab shows overdue receivable and offers repayment', (
      tester,
    ) async {
      await openPage(
        tester,
        host(const Scaffold(body: PlanningPage()), FakeApi()),
      );
      expect(find.text('Nam'), findsOneWidget);
      expect(find.textContaining('QUÁ HẠN'), findsOneWidget);
      expect(find.text('300.000 ₫'), findsWidgets);
    });

    testWidgets('goals, budgets and recurring tabs render their data', (
      tester,
    ) async {
      await openPage(
        tester,
        host(const Scaffold(body: PlanningPage()), FakeApi()),
      );
      await tester.tap(find.text('Tiết kiệm'));
      await tester.pumpAndSettle();
      expect(find.text('Du lịch Đà Lạt'), findsOneWidget);
      await tester.tap(find.text('Ngân sách'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vượt 200.000 ₫'), findsOneWidget);
      await tester.tap(find.text('Định kỳ'));
      await tester.pumpAndSettle();
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Xác nhận'), findsOneWidget);
    });
  });

  group('outbox controller', () {
    ProviderContainer containerFor(FakeApi api, MemoryOutbox store) {
      final c = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          outboxStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('flush sends in order and keeps items while offline', () async {
      final api = FakeApi();
      final store = MemoryOutbox();
      final c = containerFor(api, store);
      final box = c.read(outboxProvider.notifier);
      await box.add('TX_CREATE', {'amount': '1000'}, 'id-1');
      await box.add('TX_CREATE', {'amount': '2000'}, 'id-2');

      api.failNext = ApiException('OFFLINE', 'x', retryable: true);
      expect(await box.flush(), 0);
      expect(
        c.read(outboxProvider).waiting,
        2,
        reason: 'still queued, nothing lost',
      );

      expect(await box.flush(), 2);
      expect(c.read(outboxProvider).items, isEmpty);
      expect(api.commands.map((e) => e.id), [
        'id-1',
        'id-2',
      ], reason: 'same ids, original order');
    });

    test(
      'a rejected command is kept with its error until the owner discards it',
      () async {
        final api = FakeApi();
        final c = containerFor(api, MemoryOutbox());
        final box = c.read(outboxProvider.notifier);
        await box.add('TX_CREATE', {'amount': '1000'}, 'id-1');
        api.failNext = ApiException(
          'ACCOUNT_ARCHIVED',
          'Tài khoản đã lưu trữ.',
        );
        await box.flush();
        final state = c.read(outboxProvider);
        expect(state.failed, 1);
        expect(state.items.single.error, 'Tài khoản đã lưu trữ.');
        await box.discard('id-1');
        expect(c.read(outboxProvider).items, isEmpty);
      },
    );
  });
}
