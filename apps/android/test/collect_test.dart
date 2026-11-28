import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/collect/collect.dart';

import 'support/fake_api.dart';

class _Api extends FakeApi {
  _Api(Map<String, dynamic> extra)
    : super(data: {...FakeApi.defaultData(), ...extra});
  final posts = <(String, Object)>[];
  final puts = <(String, Object)>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path, body));
    return {'ok': true};
  }

  @override
  Future<dynamic> put(String path, Object body) async {
    puts.add((path, body));
    return {'ok': true};
  }
}

Map<String, dynamic> _reminder({
  String direction = 'RECEIVABLE',
  Map<String, dynamic>? bank,
  int count = 0,
}) => {
  'debt_id': 'd1',
  'direction': direction,
  'contact_id': 'c1',
  'contact_alias': 'Nam',
  'remaining': '535000',
  'principal': '535000',
  'note': 'tiền nhà',
  'memo': 'MOMA 8F3A2B',
  'memo_code': '8F3A2B',
  'message': 'Hi Nam, mình gửi bạn tiền nhà 535.000đ nhé.',
  'tone': 'first',
  'remind_count': count,
  'overdue_days': 0,
  'due_date': direction == 'PAYABLE' ? '2026-12-01' : null,
  'contact_bank': bank,
};

Widget _host(ApiClient api, Widget child) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: buildMomaTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'reminder: prefilled editable message, memo hint, no QR without a linked bank; snooze posts',
    (tester) async {
      final api = _Api({
        '/debts/d1/reminder': _reminder(),
        '/banks/sepay/accounts': <Object>[],
      });
      await tester.pumpWidget(_host(api, const ReminderPanel(debtId: 'd1')));
      await tester.pumpAndSettle();
      expect(find.text('Nhắc Nam trả 535.000 ₫'), findsOneWidget);
      expect(find.text('Lần nhắc đầu'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('reminder-message')),
      );
      expect(
        field.controller!.text,
        'Hi Nam, mình gửi bạn tiền nhà 535.000đ nhé.',
      );
      expect(find.textContaining('MOMA 8F3A2B'), findsOneWidget);
      expect(find.textContaining('Chưa có mã QR'), findsOneWidget);
      await tester.tap(find.text('Để sau 3 ngày'));
      await tester.pumpAndSettle();
      expect(api.posts.single.$1, '/debts/d1/snooze');
      expect(api.posts.single.$2, {'days': 3});
    },
  );

  testWidgets(
    'reminder: sharing records the reminder; a dismissed share does not',
    (tester) async {
      var answer = 'com.zing.zalo';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async => answer,
      );
      final api = _Api({
        '/debts/d1/reminder': _reminder(count: 1),
        '/banks/sepay/accounts': <Object>[],
      });
      await tester.pumpWidget(_host(api, const ReminderPanel(debtId: 'd1')));
      await tester.pumpAndSettle();
      expect(find.text('Nhắc lại lần 2'), findsOneWidget);
      answer = '';
      await tester.tap(find.byKey(const ValueKey('reminder-send')));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      answer = 'com.zing.zalo';
      await tester.tap(find.byKey(const ValueKey('reminder-send')));
      await tester.pumpAndSettle();
      expect(api.posts.map((p) => p.$1), ['/debts/d1/reminded']);
      expect(find.textContaining('tự gạch nợ'), findsWidgets);
    },
  );

  testWidgets('pay now: without the creditor bank a one-time form saves it', (
    tester,
  ) async {
    final api = _Api({'/debts/d1/reminder': _reminder(direction: 'PAYABLE')});
    await tester.pumpWidget(_host(api, const ReminderPanel(debtId: 'd1')));
    await tester.pumpAndSettle();
    expect(find.text('Trả Nam 535.000 ₫'), findsOneWidget);
    await tester.tap(find.text('Lưu tài khoản'));
    await tester.pumpAndSettle();
    expect(find.text('Chọn ngân hàng và nhập số tài khoản.'), findsOneWidget);
    expect(api.puts, isEmpty);
  });

  testWidgets(
    'pay now: saved creditor bank shows copyable account and a QR to scan',
    (tester) async {
      final api = _Api({
        '/debts/d1/reminder': _reminder(
          direction: 'PAYABLE',
          bank: {
            'bank': 'Techcombank',
            'bin': '970407',
            'account_number': '190312345678',
            'holder': 'NGUYEN VAN NAM',
          },
        ),
      });
      await tester.pumpWidget(_host(api, const ReminderPanel(debtId: 'd1')));
      await tester.pumpAndSettle();
      expect(find.text('190312345678'), findsOneWidget);
      expect(
        find.textContaining('Techcombank · NGUYEN VAN NAM'),
        findsOneWidget,
      );
      expect(find.textContaining('Quét QR'), findsOneWidget);
      expect(find.byTooltip('Sao chép Số tài khoản'), findsOneWidget);
    },
  );

  testWidgets(
    'goal proposals: one tap "Trích ngay" accepts; plan lines show pace',
    (tester) async {
      final api = _Api({
        '/goals/proposals': [
          {
            'id': 'p1',
            'goal_name': 'Laptop',
            'amount': '2100000',
            'reason': 'INCOME',
            'account_name': 'VCB',
            'allocated': '0',
            'target': '25000000',
          },
        ],
        '/goals/plan': [
          {
            'id': 'g1',
            'name': 'Laptop',
            'required_monthly': '2083334',
            'eta': '2027-11-01',
            'on_track': false,
            'pct': 0,
          },
        ],
      });
      await tester.pumpWidget(_host(api, const GoalAutoSection()));
      await tester.pumpAndSettle();
      expect(find.text('Trích 2.100.000 ₫ vào "Laptop"?'), findsOneWidget);
      expect(find.textContaining('Cần 2.083.334 ₫/tháng'), findsOneWidget);
      expect(find.textContaining('Đang chậm'), findsOneWidget);
      await tester.tap(find.text('Trích ngay'));
      await tester.pumpAndSettle();
      expect(api.posts.single.$1, '/goals/proposals/p1/accept');
    },
  );

  testWidgets('assistant REMIND card opens the reminder', (tester) async {
    final api = _Api({
      '/debts/d1/reminder': _reminder(),
      '/banks/sepay/accounts': <Object>[],
    });
    await tester.pumpWidget(
      _host(
        api,
        const RemindActionCard(
          json: {
            'type': 'REMIND',
            'debt_id': 'd1',
            'title': 'Nhắc Nam trả 535.000 ₫?',
            'lines': ['Tin nhắn và mã QR đúng số tiền đã soạn sẵn'],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nhắc Nam trả 535.000 ₫?'), findsOneWidget);
    await tester.tap(find.text('Soạn tin & gửi'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminder-message')), findsOneWidget);
  });
}
