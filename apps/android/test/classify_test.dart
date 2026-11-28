import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/classify/classify_page.dart';
import 'package:moma/features/transactions/quick_entry_page.dart';
import 'package:moma/features/transactions/tx_detail_page.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _unclear(String id) => {
  'id': id,
  'kind': 'UNKNOWN_DEBIT',
  'amount': '200000',
  'effective_at': '2026-11-28T05:30:00Z',
  'note': 'IBFT 0123 CT tu 1026746096',
  'merchant': null,
  'version': 2,
  'account_name': 'Vietcombank',
  'institution': 'VCB',
  'suggestions': [
    {
      'category_id': 'c-move',
      'name': 'Di chuyển',
      'confidence': 0.6,
      'reason': 'Trợ lý đoán',
    },
    {
      'category_id': 'c-food',
      'name': 'Ăn uống',
      'confidence': 0,
      'reason': 'Bạn hay dùng',
    },
  ],
};

class _Api extends FakeApi {
  _Api({List<Map<String, dynamic>> unclear = const [], this.suggest})
    : super(
        data: {
          ...FakeApi.defaultData(),
          '/ai/classify/pending': {'total': unclear.length, 'items': unclear},
        },
      );
  final Map<String, dynamic>? suggest;
  final posts = <String>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add(path);
    if (path == '/ai/classify/suggest') return suggest;
    return super.post(
      path,
      body,
      idempotencyKey: idempotencyKey,
      extraHeaders: extraHeaders,
    );
  }
}

Widget _app(_Api api, Widget home) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp.router(
    theme: buildMomaTheme(),
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: '/classify',
          builder: (_, _) => const QuickClassifyPage(),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('HOME')),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'quick pick: one tap saves the category in place and moves to the next card',
    (tester) async {
      final api = _Api(unclear: [_unclear('u1'), _unclear('u2')]);
      await tester.pumpWidget(_app(api, const QuickClassifyPage()));
      await tester.pumpAndSettle();
      expect(find.text('-200.000 ₫'), findsOneWidget);
      expect(find.text('Khoản chi này là gì?'), findsOneWidget);
      expect(find.text('Còn 2'), findsOneWidget);

      await tester.tap(find.text('Di chuyển'));
      await tester.pumpAndSettle();
      expect(api.commands.single.type, 'TX_ANNOTATE');
      expect(api.commands.single.payload, {
        'tx_id': 'u1',
        'expected_version': 2,
        'category_id': 'c-move',
      });
      expect(find.text('Còn 2'), findsNothing); // u2 is shown now, alone

      // Optional note travels with the pick.
      await tester.tap(find.text('Thêm ghi chú'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Đổ xăng');
      await tester.tap(find.text('Ăn uống'));
      await tester.pumpAndSettle();
      expect(api.commands.last.payload['note'], 'Đổ xăng');
      expect(find.text('Đã phân loại 2 khoản'), findsOneWidget);
    },
  );

  testWidgets(
    'quick pick: "Khác…" opens the full category list of the right type',
    (tester) async {
      final api = _Api(unclear: [_unclear('u1')]);
      await tester.pumpWidget(_app(api, const QuickClassifyPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Khác…'));
      await tester.pumpAndSettle();
      expect(
        find.text('Lương'),
        findsNothing,
      ); // income categories are not offered for money out
      await tester.tap(find.text('Ăn uống').last);
      await tester.pumpAndSettle();
      expect(api.commands.single.payload['category_id'], 'c-food');
    },
  );

  testWidgets(
    'banner shows only when something waits, and opens the quick pick',
    (tester) async {
      await tester.pumpWidget(
        _app(_Api(), const Scaffold(body: UnclearBanner())),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('cần chọn loại'), findsNothing);

      await tester.pumpWidget(
        _app(
          _Api(unclear: [_unclear('u1'), _unclear('u2'), _unclear('u3')]),
          const Scaffold(body: UnclearBanner()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3 khoản cần chọn loại'), findsOneWidget);
      await tester.tap(find.text('3 khoản cần chọn loại'));
      await tester.pumpAndSettle();
      expect(find.text('Chọn loại nhanh'), findsOneWidget);
    },
  );

  testWidgets(
    'tx detail: unclassified money gets one-tap chips; AI-classified shows "AI đã phân loại · Sửa"',
    (tester) async {
      final api = _Api();
      final unknown = MomaTx.fromJson({
        'id': 'x1',
        'kind': 'UNKNOWN_DEBIT',
        'status': 'POSTED',
        'effective_at': '2026-11-28T05:30:00Z',
        'amount': '50000',
        'fee': '0',
        'account_id': 'a1',
        'to_account_id': null,
        'category_id': null,
        'merchant': null,
        'note': 'IBFT 0123',
        'version': 2,
        'related_tx_id': null,
        'debt_linked': false,
        'ai': {
          'status': 'SUGGESTED',
          'category_id': 'c-move',
          'confidence': 0.6,
          'method': 'AI',
        },
      });
      await tester.pumpWidget(
        _app(api, TxDetailPage(txId: 'x1', initial: unknown)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Khoản chi này là gì?'), findsOneWidget);
      expect(find.text('Di chuyển (gợi ý)'), findsOneWidget);
      await tester.tap(find.text('Di chuyển (gợi ý)'));
      await tester.pumpAndSettle();
      expect(api.commands.single.type, 'TX_ANNOTATE');
      expect(api.commands.single.payload['category_id'], 'c-move');

      final applied = MomaTx.fromJson({
        'id': 'x2',
        'kind': 'EXPENSE',
        'status': 'POSTED',
        'effective_at': '2026-11-28T05:30:00Z',
        'amount': '45000',
        'fee': '0',
        'account_id': 'a1',
        'to_account_id': null,
        'category_id': 'c-move',
        'merchant': 'Grab',
        'note': null,
        'version': 3,
        'related_tx_id': null,
        'debt_linked': false,
        'ai': {
          'status': 'APPLIED',
          'category_id': 'c-move',
          'confidence': 0.86,
          'method': 'DICTIONARY',
        },
      });
      expect(applied.aiApplied, isTrue);
      expect(applied.needsCategory, isFalse);
      await tester.pumpWidget(
        _app(_Api(), TxDetailPage(txId: 'x2', initial: applied)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('AI đã phân loại (theo tên cửa hàng) · Sửa'),
        findsOneWidget,
      );
      expect(find.text('Khoản chi này là gì?'), findsNothing);
    },
  );

  testWidgets(
    'quick entry: typing a note pre-selects the suggested category; a manual pick wins',
    (tester) async {
      final api = _Api(
        suggest: {
          'category_id': 'c-move',
          'confidence': 0.86,
          'method': 'DICTIONARY',
          'reason': 'Grab thường là Di chuyển',
        },
      );
      await tester.pumpWidget(_app(api, const QuickEntryPage()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nhập ghi chú'),
        'grab đi làm',
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(api.posts, contains('/ai/classify/suggest'));
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Di chuyển'),
      );
      expect(chip.selected, isTrue);
      expect(
        find.textContaining('Đã chọn sẵn: Grab thường là Di chuyển'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Ăn uống'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Nhập ghi chú'),
        'grab đi làm về',
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Ăn uống'))
            .selected,
        isTrue,
      );
    },
  );
}
