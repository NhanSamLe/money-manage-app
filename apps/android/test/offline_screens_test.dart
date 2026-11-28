import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/outbox.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/storage/offline_cache.dart';
import 'package:moma/core/vietqr.dart';
import 'package:moma/features/banks/bank_connect_page.dart';
import 'package:moma/features/banks/receive_page.dart';
import 'package:moma/features/transactions/transactions_page.dart';

import 'support/fake_api.dart';

/// FakeApi that can "lose the network": reads then fail with OFFLINE like the real client does when nothing is
/// saved, except the paths listed in [saved] which answer from the "saved copy" (as ApiClient.get would).
class _OfflineApi extends FakeApi {
  _OfflineApi({super.data});
  bool online = true;
  Set<String> saved = {};
  final commandsTried = <String>[];

  ApiException get _off => ApiException('OFFLINE', 'offline', retryable: true);

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (!online) {
      final key = OfflineCache.keyFor(path, query);
      if (!saved.contains(key)) {
        NetStatus.wentOffline();
        throw _off;
      }
      NetStatus.wentOffline(dataAt: DateTime.now());
    }
    if (path == '/banks/sepay/qr') {
      return {
        'payload': vietQrPayload(bin: '970436', accountNumber: '1026746096'),
        'bank': 'Vietcombank',
        'holder': 'LE DAO NHAN SAM',
        'number_masked': '••••6096',
      };
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    commandsTried.add(type);
    if (!online) throw _off;
    return super.command(type, payload, commandId: commandId);
  }
}

Map<String, dynamic> _sepayData() => {
  ...FakeApi.defaultData(),
  '/banks/links': <Object>[],
  '/banks/sepay/accounts': [
    {
      'external_id': 'ext-vcb',
      'bank': 'Vietcombank',
      'holder': 'LE DAO NHAN SAM',
      'number': '1026746096',
      'number_masked': '••••6096',
      'balance': '13684007',
      'active': true,
      'label': '',
      'linked': true,
    },
  ],
};

Widget _app(ApiClient api, Widget home) => ProviderScope(
  retry: (_, _) => null,
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(theme: buildMomaTheme(), home: home),
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NetStatus.reset();
  });

  testWidgets(
    'a transaction saved offline shows first as "Chờ đồng bộ" and moves the balance',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _OfflineApi();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [apiProvider.overrideWithValue(api)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                theme: buildMomaTheme(),
                home: const Scaffold(body: TransactionsPage()),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = (await container.read(accountsProvider.future))
          .firstWhere((a) => a.id == 'a2')
          .balance!;

      await container.read(outboxProvider.notifier).add('TX_CREATE', {
        'kind': 'EXPENSE',
        'account_id': 'a2',
        'amount': '45000',
        'category_id': 'c-food',
        'merchant': 'Bún chả offline',
        'effective_at': DateTime.now().toUtc().toIso8601String(),
      }, 'cmd-offline-1');
      await tester.pumpAndSettle();

      expect(find.text('Bún chả offline'), findsOneWidget);
      expect(find.textContaining('Chờ đồng bộ'), findsOneWidget);
      final after = (await container.read(accountsProvider.future))
          .firstWhere((a) => a.id == 'a2')
          .balance!;
      expect(after, before - 45000);

      // Tapping it explains instead of opening a detail that does not exist yet.
      await tester.tap(find.text('Bún chả offline'));
      await tester.pump();
      expect(find.textContaining('sẽ tự gửi khi có mạng'), findsOneWidget);
    },
  );

  testWidgets(
    'offline bank page: saved list and balance, calm hint, link/sync disabled',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _OfflineApi(data: _sepayData())
        ..online = false
        ..saved = {'/banks/sepay/accounts'};
      await tester.pumpWidget(_app(api, const BankConnectPage()));
      await tester.pumpAndSettle();

      expect(find.text('Vietcombank'), findsOneWidget);
      expect(find.byKey(const ValueKey('bank-offline-hint')), findsOneWidget);
      expect(
        find.textContaining('Đang offline · số dư cập nhật lúc'),
        findsOneWidget,
      );
      expect(find.text('Không tải được dữ liệu'), findsNothing);
      final sync = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Đồng bộ giao dịch ngay'),
      );
      expect(sync.onPressed, isNull);
    },
  );

  testWidgets(
    'offline receive QR with an amount is built on the phone from the saved plain QR',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _OfflineApi(data: _sepayData())
        ..online = false
        ..saved = {
          '/banks/sepay/accounts',
          OfflineCache.keyFor('/banks/sepay/qr', {'external_id': 'ext-vcb'}),
        };
      await tester.pumpWidget(_app(api, const ReceivePage()));
      await tester.pumpAndSettle();

      final amountField = find.byType(TextField).first;
      await tester.enterText(amountField, '150000');
      await tester.pumpAndSettle();
      final make = find.textContaining('Tạo mã');
      expect(make, findsWidgets);
      await tester.tap(make.first);
      await tester.pumpAndSettle();

      // No error dialog; the QR card for the account is shown.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('LE DAO NHAN SAM'), findsWidgets);
    },
  );
}
