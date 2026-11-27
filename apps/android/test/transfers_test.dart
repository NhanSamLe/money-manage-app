import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/transfers/transfer_pair_section.dart';
import 'package:moma/features/transfers/transfer_suggestions.dart';
import 'package:moma/features/transfers/transfers_data.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _leg(
  String tx,
  String account,
  String institution,
  String kind,
  String at, {
  String? note,
}) => {
  'tx_id': tx,
  'kind': 'UNKNOWN_CREDIT',
  'status': 'POSTED',
  'amount': '500000',
  'effective_at': at,
  'note': note,
  'merchant': null,
  'source': 'BANK',
  'account_id': 'acc-$account',
  'account_name': account,
  'institution': institution,
  'account_kind': kind,
  'last4': null,
};

Map<String, dynamic> _pair(String id, {String state = 'SUGGESTED'}) => {
  'id': id,
  'state': state,
  'score': 50,
  'hints': ['keyword'],
  'created_at': '2026-11-28T03:00:00Z',
  'out': _leg(
    'o-$id',
    'TPBank',
    'TPBank',
    'BANK',
    '2026-11-28T03:00:00Z',
    note: 'NAP TIEN VI MOMO',
  ),
  'in': _leg(
    'i-$id',
    'Ví MoMo',
    'MoMo',
    'WALLET',
    '2026-11-28T03:01:00Z',
    note: 'Nhận tiền từ TPBank',
  ),
};

/// FakeApi with the transfers endpoints: suggestions are removed once decided; posts are recorded.
class _TransfersApi extends FakeApi {
  _TransfersApi(this.suggestions, {this.byTx});
  final List<Map<String, dynamic>> suggestions;
  final Map<String, dynamic>? byTx;
  final posts = <(String, Object)>[];

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/transfers/suggestions') return [...suggestions];
    if (path.startsWith('/transfers/by-tx/')) return byTx;
    return super.get(path, query: query);
  }

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add((path, body));
    suggestions.removeWhere((s) => path.endsWith('/${s['id']}'));
    return {'state': 'CONFIRMED'};
  }
}

Future<void> _pump(WidgetTester tester, FakeApi api, Widget child) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: ListView(children: [child])),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('parses pairs, including a one-leg transfer', () {
    final p = TransferPair.fromJson(_pair('p1'));
    expect(p.out!.accountName, 'TPBank');
    expect(p.inLeg!.institution, 'MoMo');
    expect(p.amount, 500000);
    expect(p.oneLeg, isFalse);
    final one = TransferPair.fromJson({
      ..._pair('p2', state: 'AUTO'),
      'out': null,
      'synth_account': {
        'account_id': 'acc-momo',
        'account_name': 'Ví MoMo',
        'institution': 'MoMo',
        'account_kind': 'WALLET',
      },
      'can_undo': true,
    });
    expect(one.oneLeg, isTrue);
    expect(one.isPaired, isTrue);
    expect(one.synthAccountName, 'Ví MoMo');
  });

  testWidgets('home card is hidden without suggestions', (tester) async {
    await _pump(tester, _TransfersApi([]), const TransferSuggestionsCard());
    expect(find.textContaining('chuyển tiền giữa tài khoản'), findsNothing);
  });

  testWidgets('card opens the sheet; Đúng accepts and Không rejects', (
    tester,
  ) async {
    final api = _TransfersApi([_pair('p1'), _pair('p2')]);
    await _pump(tester, api, const TransferSuggestionsCard());
    expect(
      find.text('Có 2 khoản có thể là chuyển tiền giữa tài khoản của bạn'),
      findsOneWidget,
    );
    await tester.tap(find.byType(TransferSuggestionsCard));
    await tester.pumpAndSettle();
    expect(find.text('Chuyển tiền giữa tài khoản?'), findsOneWidget);
    expect(find.text('TPBank'), findsNWidgets(2));
    expect(find.text('Ví MoMo'), findsNWidgets(2));
    expect(find.text('500.000 ₫'), findsNWidgets(2));

    await tester.tap(find.text('Đúng').first);
    await tester.pumpAndSettle();
    expect(api.posts.first.$1, '/transfers/suggestions/p1');
    expect(api.posts.first.$2, {'accept': true});
    expect(find.text('Đúng'), findsOneWidget);

    await tester.tap(find.text('Không'));
    await tester.pumpAndSettle();
    expect(api.posts.last.$1, '/transfers/suggestions/p2');
    expect(api.posts.last.$2, {'accept': false});
    expect(find.text('Không còn khoản nào cần xem.'), findsOneWidget);
  });

  testWidgets(
    'transfer detail: Tự ghép từ 2 giao dịch, Tách ra after confirm',
    (tester) async {
      final api = _TransfersApi(
        [],
        byTx: {
          ..._pair('p9', state: 'AUTO'),
          'can_undo': true,
        },
      );
      await _pump(tester, api, const TransferPairSection(txId: 'tr1'));
      expect(find.text('Tự ghép từ 2 giao dịch'), findsOneWidget);
      await tester.tap(find.text('Tách ra'));
      await tester.pumpAndSettle();
      expect(find.text('Tách ra?'), findsOneWidget);
      await tester.tap(find.text('Không'));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      await tester.tap(find.text('Tách ra'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tách ra').last);
      await tester.pumpAndSettle();
      expect(api.posts.single.$1, '/transfers/p9/undo');
    },
  );

  testWidgets('one-leg transfer names the account that never notifies', (
    tester,
  ) async {
    final api = _TransfersApi(
      [],
      byTx: {
        ..._pair('p8', state: 'AUTO'),
        'out': null,
        'synth_account': {
          'account_id': 'acc-momo',
          'account_name': 'Ví MoMo',
          'institution': 'MoMo',
          'account_kind': 'WALLET',
        },
        'can_undo': true,
      },
    );
    await _pump(tester, api, const TransferPairSection(txId: 'tr2'));
    expect(find.text('Tự ghép từ 1 giao dịch'), findsOneWidget);
    expect(find.textContaining('đến từ Ví MoMo'), findsOneWidget);
  });

  testWidgets('manual transfers show nothing', (tester) async {
    await _pump(
      tester,
      _TransfersApi([]),
      const TransferPairSection(txId: 'x'),
    );
    expect(find.text('Tách ra'), findsNothing);
  });
}
