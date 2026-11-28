import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/planning_models.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/planning/debts_view.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _debt({List<Map<String, dynamic>> payments = const []}) =>
    {
      'id': 'd1',
      'direction': 'RECEIVABLE',
      'contact_id': 'k1',
      'contact_alias': 'Nam',
      'principal': '500000',
      'remaining': '300000',
      'state': 'PARTIAL',
      'due_date': '2026-12-20',
      'originated_at': '2026-11-10T00:00:00Z',
      'note': 'Mượn mua xe',
      'version': 4,
      'overdue': false,
      'origin_tx_id': 't0',
      'account_id': 'a2',
      'payments': payments,
    };

const _paid = {
  'id': 'p1',
  'kind': 'REPAYMENT',
  'principal': '200000',
  'interest': '0',
  'tx_id': 't1',
  'account_id': 'a2',
  'effective_at': '2026-11-25T03:00:00Z',
  'reversed': false,
};
const _undone = {
  'id': 'p0',
  'kind': 'REPAYMENT',
  'principal': '50000',
  'interest': '0',
  'tx_id': 't2',
  'account_id': 'a2',
  'effective_at': '2026-11-20T03:00:00Z',
  'reversed': true,
};

Future<FakeApi> _open(WidgetTester tester, Map<String, dynamic> debt) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = FakeApi(
    data: {
      ...FakeApi.defaultData(),
      '/debts': [debt],
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => openDebt(context, 'd1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('parses payments, debt_id and the amount lock', () {
    final d = Debt.fromJson(_debt(payments: [_paid, _undone]));
    expect(d.payments, hasLength(2));
    expect(d.activePayments.single.id, 'p1');
    expect(d.amountEditable, isFalse);
    expect(d.contactId, 'k1');
    expect(d.originTxId, 't0');
    expect(Debt.fromJson(_debt(payments: [_undone])).amountEditable, isTrue);
    // Older servers: no payments field.
    final old = Debt.fromJson({..._debt()}..remove('payments'));
    expect(old.payments, isEmpty);
    final tx = MomaTx.fromJson({
      'id': 't1',
      'kind': 'LOAN_COLLECTED',
      'status': 'POSTED',
      'effective_at': '2026-11-25T03:00:00Z',
      'amount': '200000',
      'version': 1,
      'debt_linked': true,
      'debt_id': 'd1',
    });
    expect(tx.debtId, 'd1');
  });

  testWidgets('undo one repayment after confirming', (tester) async {
    final api = await _open(tester, _debt(payments: [_paid, _undone]));
    expect(find.text('Lịch sử thu nợ'), findsOneWidget);
    expect(find.text('Thu 200.000 ₫'), findsOneWidget);
    expect(find.textContaining('Đã hoàn tác'), findsOneWidget);
    // Only the active payment offers "Hoàn tác".
    expect(find.widgetWithText(TextButton, 'Hoàn tác'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Hoàn tác'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hoàn tác').last);
    await tester.pumpAndSettle();
    expect(api.commands.single.type, 'DEBT_PAYMENT_REVERSE');
    expect(api.commands.single.payload, {
      'debt_id': 'd1',
      'payment_id': 'p1',
      'expected_version': 4,
    });
  });

  testWidgets(
    'delete asks first; cancel sends nothing, confirm sends DEBT_CANCEL',
    (tester) async {
      final api = await _open(tester, _debt(payments: [_paid]));
      await tester.tap(find.byKey(const ValueKey('debt-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Xóa khoản nợ này?'), findsOneWidget);
      expect(find.textContaining('1 lần thu/trả'), findsOneWidget);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(api.commands, isEmpty);

      await tester.tap(find.byKey(const ValueKey('debt-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa').last);
      await tester.pumpAndSettle();
      expect(api.commands.single.type, 'DEBT_CANCEL');
      expect(api.commands.single.payload['debt_id'], 'd1');
      expect(api.commands.single.payload['expected_version'], 4);
    },
  );

  testWidgets('edit sends only what changed; amount locked once repaid', (
    tester,
  ) async {
    final api = await _open(tester, _debt(payments: [_paid]));
    await tester.tap(find.text('Sửa'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hoàn tác các lần đó'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Mượn mua xe'),
      'Mượn mua xe máy',
    );
    await tester.tap(find.text('Lưu thay đổi'));
    await tester.pumpAndSettle();
    expect(api.commands.single.type, 'DEBT_UPDATE');
    expect(api.commands.single.payload, {
      'debt_id': 'd1',
      'expected_version': 4,
      'note': 'Mượn mua xe máy',
    });
  });

  testWidgets('amount is editable while nothing was repaid', (tester) async {
    final api = await _open(tester, _debt());
    await tester.tap(find.text('Sửa'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '500.000'), '450000');
    await tester.tap(find.text('Lưu thay đổi'));
    await tester.pumpAndSettle();
    expect(api.commands.single.payload['principal'], '450000');
  });
}
