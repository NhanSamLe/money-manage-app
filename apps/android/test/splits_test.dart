import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/splits/recurring_split_sheet.dart';
import 'package:moma/features/splits/split_api.dart';
import 'package:moma/features/splits/split_card.dart';
import 'package:moma/features/splits/split_models.dart';

import 'support/fake_api.dart';

/// FakeApi + the split endpoints (POST is not in the shared fake).
class _SplitApi extends FakeApi {
  _SplitApi({List<Map<String, dynamic>> splits = const [], this.analysis})
    : super(
        data: {
          ...FakeApi.defaultData(),
          '/contacts': [
            {'id': 'k1', 'alias': 'Nam', 'note': null, 'version': 1},
            {'id': 'k2', 'alias': 'Lan', 'note': null, 'version': 1},
          ],
          '/splits': [...splits],
        },
      );

  final Map<String, dynamic>? analysis;
  final posts = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path: path, body: (body as Map).cast<String, dynamic>()));
    if (path == '/bills/analyze') return analysis;
    if (path == '/splits/apply') {
      final list = data['/splits'] as List;
      for (final s in list) {
        (s as Map)['state'] = 'APPLIED';
      }
      return {'application_id': 'a1'};
    }
    return {'ok': true};
  }
}

MomaTx _tx({String kind = 'UNKNOWN_DEBIT', int amount = 1240000}) =>
    MomaTx.fromJson({
      'id': 'tx1',
      'kind': kind,
      'status': 'POSTED',
      'effective_at': '2026-12-06T03:00:00Z',
      'amount': '$amount',
      'fee': '0',
      'account_id': 'a1',
      'category_id': null,
      'merchant': null,
      'note': 'VCB TT',
      'version': 3,
      'source': 'BANK',
    });

Map<String, dynamic> _proposal({
  List<Map<String, dynamic>> shares = const [],
}) => {
  'id': 'p1',
  'tx_id': 'tx1',
  'recurring_id': null,
  'recurring_name': null,
  'source': 'BILL',
  'state': 'PROPOSED',
  'confidence': 0.6,
  'total': '1240000',
  'category_id': 'c-food',
  'shares': shares,
  'owner_amount':
      '${1240000 - shares.fold<int>(0, (a, s) => a + int.parse('${s['amount']}'))}',
  'note': 'Lẩu',
  'hints': [],
  'can_undo': false,
};

Widget _host(FakeApi api, Widget child, {List<Override> extra = const []}) =>
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api), ...extra],
      child: MaterialApp(
        theme: buildMomaTheme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('computeShares (mirror of the server)', () {
    test('1.600.000 for 3 incl. owner, rounded up to 5.000', () {
      final r = computeShares(1600000, [
        (mode: 'EQUAL', value: null),
        (mode: 'EQUAL', value: null),
      ]);
      expect(r.shares, [535000, 535000]);
      expect(r.owner, 530000);
      expect(
        splitPreviewLine(['Nam', 'Lan'], r.shares, r.owner),
        'Nam 535.000 · Lan 535.000 · Bạn 530.000',
      );
    });
    test('owner not included never over-charges; fixed + percent', () {
      final r = computeShares(1000000, [
        (mode: 'EQUAL', value: null),
        (mode: 'EQUAL', value: null),
        (mode: 'EQUAL', value: null),
      ], ownerShare: false);
      expect(r.shares, [335000, 335000, 330000]);
      expect(r.owner, 0);
      final m = computeShares(1000000, [
        (mode: 'FIXED', value: 200000),
        (mode: 'PERCENT', value: 30),
        (mode: 'EQUAL', value: null),
      ]);
      expect(m.shares, [200000, 300000, 250000]);
      expect(m.owner, 250000);
    });
    test('next window start', () {
      expect(
        nextWindowStart(5, 10, DateTime(2026, 12, 7)),
        DateTime(2026, 12, 5),
      );
      expect(
        nextWindowStart(5, 10, DateTime(2026, 12, 11)),
        DateTime(2027, 1, 5),
      );
      expect(
        nextWindowStart(31, 31, DateTime(2027, 2, 1)),
        DateTime(2027, 2, 28),
      );
    });
  });

  testWidgets(
    'rule editor: live split preview and the RECURRING_SPLIT_UPSERT command',
    (tester) async {
      final api = _SplitApi();
      await tester.pumpWidget(_host(api, const RecurringSplitSheet()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Tiền nhà');
      await tester.enterText(find.byType(TextField).at(1), '1600000');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Nam'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Nam'));
      await tester.tap(find.widgetWithText(FilterChip, 'Lan'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('rule-preview'))).data,
        'Nam 535.000 · Lan 535.000 · Bạn 530.000',
      );
      // Rounding 10.000 -> 540.000 each, owner 520.000.
      await tester.ensureVisible(find.text('10.000'));
      await tester.tap(find.text('10.000'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('rule-preview'))).data,
        'Nam 540.000 · Lan 540.000 · Bạn 520.000',
      );
      // Account and category are required: missing -> error, no command.
      await tester.ensureVisible(find.text('Lưu quy tắc'));
      await tester.tap(find.text('Lưu quy tắc'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Điền tên, số tiền, tài khoản và danh mục'),
        findsOneWidget,
      );
      expect(api.commands, isEmpty);
    },
  );

  testWidgets('proposal card: one tap confirms the split', (tester) async {
    final api = _SplitApi(
      splits: [
        _proposal(
          shares: [
            {'contact_id': 'k1', 'name': 'Nam', 'amount': '415000'},
            {'contact_id': null, 'name': 'Hùng', 'amount': '415000'},
          ],
        ),
      ],
    );
    await tester.pumpWidget(_host(api, TxSplitCard(tx: _tx())));
    await tester.pumpAndSettle();
    expect(find.text('Chia 1.240.000 ₫?'), findsOneWidget);
    expect(
      find.text('Nam 415.000 · Hùng 415.000 · Bạn 410.000'),
      findsOneWidget,
    );
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(api.posts.single.path, '/splits/apply');
    expect(api.posts.single.body, {'tx_id': 'tx1', 'application_id': 'p1'});
    expect(find.text('Đã chia tiền'), findsOneWidget);
  });

  testWidgets(
    'empty proposal (group bill without names): choose people, dismiss',
    (tester) async {
      final api = _SplitApi(splits: [_proposal()]);
      await tester.pumpWidget(_host(api, TxSplitCard(tx: _tx())));
      await tester.pumpAndSettle();
      expect(
        find.text('Hóa đơn này có vẻ ăn chung. Chia cho ai?'),
        findsOneWidget,
      );
      expect(find.text('Chọn người…'), findsOneWidget);
      await tester.tap(find.text('Không chia'));
      await tester.pumpAndSettle();
      expect(api.posts.single.path, '/splits/p1/dismiss');
    },
  );

  group('bill photo analysis', () {
    Widget runner(_SplitApi api, MomaTx tx) => _host(
      api,
      Consumer(
        builder: (context, ref, _) => Column(
          children: [
            TextButton(
              onPressed: () => runBillAnalysis(context, ref, tx, Uint8List(4)),
              child: const Text('upload'),
            ),
            TxSplitCard(tx: tx),
          ],
        ),
      ),
      extra: [
        billTextReaderProvider.overrideWithValue(
          (_) async => 'LAU HOI AN 6 BIA TONG 1.240.000',
        ),
      ],
    );

    testWidgets('photo added -> category / merchant updated, with undo', (
      tester,
    ) async {
      final api = _SplitApi(
        analysis: {
          'reading': {'items': 'Lẩu, 6 bia', 'merchant': 'Lẩu Hội An'},
          'updated': {
            'category_id': 'c-food',
            'merchant': 'Lẩu Hội An',
            'note': 'Lẩu, 6 bia',
            'previous': {
              'kind': 'UNKNOWN_DEBIT',
              'category_id': null,
              'merchant': null,
              'note': 'VCB TT',
            },
          },
          'suggestion': null,
          'amount_mismatch': null,
          'split': 'NONE',
        },
      );
      await tester.pumpWidget(runner(api, _tx()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('upload'));
      await tester.pumpAndSettle();
      expect(api.posts.first.path, '/bills/analyze');
      expect(api.posts.first.body['text'], contains('LAU HOI AN'));
      expect(
        find.text('Đã cập nhật: Ăn uống · Lẩu Hội An · Lẩu, 6 bia'),
        findsOneWidget,
      );
      expect(find.text('Hoàn tác'), findsOneWidget);
    });

    testWidgets(
      'total differs -> warning card, amount unchanged until the owner taps',
      (tester) async {
        final api = _SplitApi(
          analysis: {
            'reading': {},
            'updated': null,
            'suggestion': null,
            'amount_mismatch': {
              'bill_total': '1340000',
              'tx_amount': '1240000',
            },
            'split': 'NONE',
          },
        );
        await tester.pumpWidget(runner(api, _tx()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('upload'));
        await tester.pumpAndSettle();
        expect(find.text('Hóa đơn ghi 1.340.000 ₫'), findsOneWidget);
        expect(find.text('Sửa thành 1.340.000 ₫'), findsOneWidget);
        expect(
          api.commands,
          isEmpty,
        ); // money is never changed by the reading itself
        await tester.tap(find.text('Sửa thành 1.340.000 ₫'));
        await tester.pumpAndSettle();
        expect(api.commands.single.type, 'TX_CORRECT');
        expect(
          (api.commands.single.payload['replacement'] as Map)['amount'],
          '1340000',
        );
      },
    );

    testWidgets('group bill -> split proposal card appears', (tester) async {
      final api = _SplitApi(
        analysis: {
          'reading': {'items': 'Lẩu'},
          'updated': null,
          'suggestion': null,
          'amount_mismatch': null,
          'split': 'PROPOSED',
        },
      );
      await tester.pumpWidget(runner(api, _tx()));
      await tester.pumpAndSettle();
      expect(find.text('Chia tiền với người khác'), findsOneWidget);
      // The server stored the proposal while analyzing.
      (api.data['/splits'] as List).add(_proposal());
      await tester.tap(find.text('upload'));
      await tester.pumpAndSettle();
      expect(find.text('Chia 1.240.000 ₫?'), findsOneWidget);
      expect(find.text('Chia tiền với người khác'), findsNothing);
    });

    testWidgets(
      'solo bill, unsure reading -> one-tap suggestion, no split question',
      (tester) async {
        final api = _SplitApi(
          analysis: {
            'reading': {},
            'updated': null,
            'suggestion': {
              'category_id': 'c-food',
              'merchant': 'Phở 24',
              'note': null,
              'confidence': 0.55,
            },
            'amount_mismatch': null,
            'split': 'NONE',
          },
        );
        await tester.pumpWidget(runner(api, _tx()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('upload'));
        await tester.pumpAndSettle();
        expect(find.text('Theo hóa đơn: Ăn uống · Phở 24'), findsOneWidget);
        expect(find.textContaining('Chia 1.240.000'), findsNothing);
        await tester.tap(find.text('Cập nhật'));
        await tester.pumpAndSettle();
        expect(api.commands.single.type, 'TX_ANNOTATE');
        expect(
          api.commands.single.payload,
          containsPair('category_id', 'c-food'),
        );
      },
    );
  });
}
