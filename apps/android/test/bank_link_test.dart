import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/accounts/sync/sync_sources.dart';
import 'package:moma/features/banks/bank_connect_page.dart';

import 'support/fake_api.dart';

class _Api extends FakeApi {
  _Api() : super(data: _data());
  final bodies = <Map>[];

  static Map<String, dynamic> _data() {
    final d = FakeApi.defaultData();
    d['/accounts'] = [
      {
        'id': 'vcb-notify',
        'kind': 'BANK',
        'institution': 'Vietcombank',
        'name': 'Vietcombank',
        'last4': '6096',
        'balance': '13684007',
        'version': 2,
        'archived': false,
        'baseline_known': true,
      },
      {
        'id': 'cash',
        'kind': 'CASH',
        'institution': 'Ví',
        'name': 'Tiền mặt',
        'last4': null,
        'balance': '500000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
    ];
    d['/banks/links'] = <Object>[];
    d['/banks/sepay/accounts'] = [
      {
        'external_id': 'ext-vcb',
        'bank': 'Vietcombank',
        'holder': 'LE DAO NHAN SAM',
        'number': '1026746096',
        'number_masked': '••••6096',
        'balance': '13684007',
        'active': true,
        'label': '',
        'linked': false,
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
    bodies.add(body as Map);
    return {'account_id': body['account_id'] ?? 'new', 'attached': true};
  }
}

class _Store implements NotifySyncStore {
  final map = <String, String>{'com.VCB': 'vcb-notify'};
  @override
  Future<Map<String, String>> accountMap() async => Map.of(map);
  @override
  Future<void> mapPackage(String package, String accountId) async =>
      map[package] = accountId;
  @override
  Future<void> unmapAccount(String accountId) async =>
      map.removeWhere((_, v) => v == accountId);
  @override
  Future<void> unmapPackage(String package) async => map.remove(package);
  @override
  Future<bool> autoRecord() async => true;
  @override
  Future<void> setAutoRecord(bool v) async {}
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'linking a SePay account offers the existing Vietcombank account (bank + last4) and attaches to it',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      final api = _Api();
      final store = _Store();
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            apiProvider.overrideWithValue(api),
            notifySyncStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: BankConnectPage()),
        ),
      );
      await tester.pumpAndSettle();

      // Masked by default; the eye reveals, the copy icon copies the full number.
      expect(find.text('•••• 6096'), findsOneWidget);
      expect(find.text('1026746096'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reveal-number')));
      await tester.pump();
      expect(find.text('1026746096'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('copy-number')));
      await tester.pump();
      expect(copied, '1026746096');
      expect(find.text('Đã sao chép số tài khoản'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));

      await tester.tap(find.text('Kết nối với MoMa'));
      await tester.pumpAndSettle();
      expect(find.text('Gắn vào tài khoản đã có'), findsOneWidget);
      expect(find.text('Vietcombank · •••• 6096'), findsOneWidget);
      expect(find.text('Tạo tài khoản mới'), findsOneWidget);
      expect(find.textContaining('Tiền mặt'), findsNothing); // not a candidate
      await tester.tap(find.text('Vietcombank · •••• 6096'));
      await tester.pumpAndSettle();
      expect(api.bodies.single, {
        'external_id': 'ext-vcb',
        'account_id': 'vcb-notify',
      });
      // SePay is now the only source: the notification mapping is gone.
      expect(store.map, isEmpty);
    },
  );
}
