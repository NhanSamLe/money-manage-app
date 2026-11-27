import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/ui/moma_switch.dart';
import 'package:moma/features/accounts/accounts_page.dart';
import 'package:moma/features/accounts/sync/sync_sources.dart';

import 'support/fake_api.dart';

class _Api extends FakeApi {
  _Api() : super(data: _data());
  final posts = <String>[];

  static Map<String, dynamic> _data() {
    final d = FakeApi.defaultData();
    (d['/accounts'] as List).add({
      'id': 'a3',
      'kind': 'WALLET',
      'institution': 'MoMo',
      'name': 'Ví điện tử',
      'last4': null,
      'balance': '250000',
      'version': 1,
      'archived': false,
      'baseline_known': true,
    });
    d['/banks/links'] = [
      {
        'account_id': 'a1',
        'provider': 'SEPAY',
        'external_id': 'ext-1',
        'last4': '8301',
        'holder_name': 'NGUYEN VAN A',
        'bank_name': 'Vietcombank',
        'bank_balance': '10000000',
        'bank_balance_at': '2026-11-27T05:00:00Z',
      },
    ];
    d['/banks/sepay/accounts'] = [
      {
        'external_id': 'ext-1',
        'bank': 'Vietcombank',
        'holder': 'NGUYEN VAN A',
        'number_masked': '••••8301',
        'balance': '10000000',
        'active': true,
        'label': '',
        'linked': true,
      },
    ];
    return d;
  }

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add(path);
    return {'applied': 0};
  }
}

class _Store implements NotifySyncStore {
  final map = <String, String>{};
  bool auto = false;
  @override
  Future<Map<String, String>> accountMap() async => Map.of(map);
  @override
  Future<void> mapPackage(String package, String accountId) async =>
      map[package] = accountId;
  @override
  Future<void> unmapAccount(String accountId) async =>
      map.removeWhere((_, v) => v == accountId);
  @override
  Future<bool> autoRecord() async => auto;
  @override
  Future<void> setAutoRecord(bool v) async => auto = v;
}

class _Access implements NotifyAccess {
  _Access({this.granted = true});
  bool granted;
  int opened = 0;
  @override
  Future<bool> isGranted() async => granted;
  @override
  Future<void> openSettings() async {
    opened++;
    granted = true;
  }

  @override
  Future<int> pendingCount() async => 2;
}

Future<void> _open(
  WidgetTester tester, {
  required _Api api,
  required _Store store,
  required _Access access,
}) async {
  // 360 dp wide phone: any overflow fails the test.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: AccountsPage()),
      ),
      GoRoute(
        path: '/banks',
        builder: (_, _) => const Scaffold(body: Text('banks page')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(api),
        notifySyncStoreProvider.overrideWithValue(store),
        notifyAccessProvider.overrideWithValue(access),
        pushPermissionProvider.overrideWith((_) async => true),
      ],
      child: MaterialApp.router(
        theme: ThemeData(useMaterial3: true),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Scrolls the account list until [f] is built, then fully on screen.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

MomaSwitch _switch(WidgetTester tester, String key) =>
    tester.widget<MomaSwitch>(find.byKey(ValueKey(key)));

void main() {
  testWidgets('linked bank account: bank sync on, Android switch disabled', (
    tester,
  ) async {
    await _open(tester, api: _Api(), store: _Store(), access: _Access());
    expect(find.text('Đã liên kết'), findsOneWidget);
    expect(find.text('STK: *** 8301'), findsOneWidget);
    expect(_switch(tester, 'bank-sync-a1').value, isTrue);
    final android = _switch(tester, 'android-sync-a1');
    expect(android.value, isFalse);
    expect(android.onChanged, isNull);
    expect(find.text('Đã đồng bộ ngân hàng, không cần'), findsOneWidget);
  });

  testWidgets('wallet shows "Chưa hỗ trợ", cash is manual', (tester) async {
    await _open(tester, api: _Api(), store: _Store(), access: _Access());
    await _reveal(tester, find.byKey(const ValueKey('bank-unsupported-a3')));
    await tester.pumpAndSettle();
    expect(find.text('Chưa hỗ trợ'), findsOneWidget);
    expect(find.text('Ghi tay hoặc nhờ Trợ lý'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('bank-unsupported-a3')));
    await tester.pumpAndSettle();
    expect(find.text('Chưa hỗ trợ đồng bộ'), findsOneWidget);
  });

  testWidgets(
    'turning Android sync on asks for permission, picks the app and saves the mapping',
    (tester) async {
      final store = _Store();
      final access = _Access(granted: false);
      await _open(tester, api: _Api(), store: store, access: access);
      final sw = find.byKey(const ValueKey('android-sync-a3'));
      await _reveal(tester, sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(find.text('Cần quyền đọc thông báo'), findsOneWidget);
      await tester.tap(find.text('Mở cài đặt'));
      await tester.pumpAndSettle();
      expect(access.opened, 1);
      expect(find.text('Ứng dụng gửi thông báo'), findsOneWidget);
      await tester.tap(find.text('MoMo').last);
      await tester.pumpAndSettle();
      expect(store.map, {'com.mservice.momotransfer': 'a3'});
      expect(store.auto, isTrue);
      expect(_switch(tester, 'android-sync-a3').value, isTrue);
      expect(find.text('Từ ứng dụng MoMo'), findsOneWidget);

      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(store.map, isEmpty);
      expect(_switch(tester, 'android-sync-a3').value, isFalse);
    },
  );

  testWidgets('integrations tab shows SePay, notification and push state', (
    tester,
  ) async {
    final api = _Api();
    await _open(tester, api: api, store: _Store(), access: _Access());
    await tester.tap(find.text('Tích hợp'));
    await tester.pumpAndSettle();
    expect(find.text('Đang hoạt động'), findsOneWidget);
    expect(find.text('Đã liên kết với MoMa: 1'), findsOneWidget);
    expect(find.text('Thông báo chờ xử lý: 2'), findsOneWidget);
    await tester.tap(find.text('Đồng bộ ngay'));
    await tester.pumpAndSettle();
    expect(api.posts, ['/banks/sepay/sync']);
  });
}
