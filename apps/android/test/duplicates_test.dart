import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/transfers/duplicates.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _leg(
  String tx,
  String acc,
  String name,
  String kind,
  String at, {
  String? note,
}) => {
  'tx_id': tx,
  'kind': 'EXPENSE',
  'status': 'POSTED',
  'amount': '45000',
  'effective_at': at,
  'note': note,
  'merchant': null,
  'source': 'NOTIFICATION',
  'account_id': acc,
  'account_name': name,
  'institution': name,
  'account_kind': kind,
  'last4': null,
};

Map<String, dynamic> _same(String id, String state) => {
  'id': id,
  'state': state,
  'score': 55,
  'hints': ['wallet'],
  'keep': _leg(
    't-vcb',
    'a1',
    'VCB',
    'BANK',
    '2026-11-28T05:03:00Z',
    note: 'MBVCB.123.MOMO.1234567890',
  ),
  'dup': _leg(
    't-momo',
    'a2',
    'MoMo',
    'WALLET',
    '2026-11-28T05:04:00Z',
    note: 'Thanh toán cho Highlands',
  ),
  'can_undo': state != 'SUGGESTED',
};

class _DupApi extends FakeApi {
  _DupApi({
    List<Map<String, dynamic>> suggestions = const [],
    Map<String, dynamic>? merged,
  }) : super(
         data: {
           ...FakeApi.defaultData(),
           '/duplicates/suggestions': suggestions,
           '/transactions/t-vcb/duplicate': merged,
           '/transactions/t-momo/duplicate': merged,
         },
       );
  final posts = <String, Object>{};
  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts[path] = body;
    (data['/duplicates/suggestions'] as List).clear();
    return {'state': 'CONFIRMED'};
  }
}

Widget _host(FakeApi api, Widget child) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: buildMomaTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  test('title names both accounts, amount and time', () {
    final s = SamePayment.fromJson(_same('s1', 'SUGGESTED'));
    final title = samePaymentTitle(s);
    expect(title, startsWith('Có thể trùng: VCB -45.000'));
    expect(title, contains('MoMo -45.000'));
    expect(title, contains(':03)'));
    expect(s.sameAccount, isFalse);
    expect(s.isMerged, isFalse);
  });

  testWidgets('sheet: Gộp sends accept=true and the list empties', (
    tester,
  ) async {
    final api = _DupApi(suggestions: [_same('s1', 'SUGGESTED')]);
    await tester.pumpWidget(_host(api, const DuplicateSuggestionsSheet()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Có thể trùng: VCB'), findsOneWidget);
    expect(find.textContaining('Giữ · VCB'), findsOneWidget);
    expect(find.textContaining('Gộp vào · MoMo'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Gộp'));
    await tester.pumpAndSettle();
    expect(api.posts['/duplicates/s1/decide'], {'accept': true});
    expect(find.text('Không còn khoản nào cần xem.'), findsOneWidget);
  });

  testWidgets('sheet: Không trùng sends accept=false', (tester) async {
    final api = _DupApi(suggestions: [_same('s1', 'SUGGESTED')]);
    await tester.pumpWidget(_host(api, const DuplicateSuggestionsSheet()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Không trùng'));
    await tester.pumpAndSettle();
    expect(api.posts['/duplicates/s1/decide'], {'accept': false});
  });

  testWidgets(
    'detail of the kept transaction: merged badge with Tách ra (asks first)',
    (tester) async {
      final api = _DupApi(merged: _same('s1', 'AUTO'));
      await tester.pumpWidget(
        _host(api, const DuplicateSection(txId: 't-vcb')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Đã gộp khoản trùng từ MoMo'), findsOneWidget);
      await tester.tap(find.text('Tách ra'));
      await tester.pumpAndSettle();
      expect(find.text('Tách ra?'), findsOneWidget);
      await tester.tap(find.text('Không'));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
    },
  );

  testWidgets(
    'detail of the merged-away copy points to the kept one; nothing when there was no merge',
    (tester) async {
      final api = _DupApi(merged: _same('s1', 'AUTO'));
      await tester.pumpWidget(
        _host(api, const DuplicateSection(txId: 't-momo')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Đã gộp vào giao dịch ở VCB'), findsOneWidget);
      expect(find.text('Mở'), findsOneWidget);

      await tester.pumpWidget(
        _host(_DupApi(), const DuplicateSection(txId: 't-vcb')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Đã gộp'), findsNothing);
    },
  );
}
