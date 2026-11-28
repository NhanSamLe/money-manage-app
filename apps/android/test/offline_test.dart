import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/outbox.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/storage/local_store.dart';
import 'package:moma/core/storage/offline_cache.dart';
import 'package:moma/core/ui/offline.dart';
import 'package:moma/core/vietqr.dart';
import 'package:moma/core/widgets.dart';
import 'package:moma/features/banks/qr_share.dart' show vietQrAccountNumber;
import 'package:moma/features/transactions/tx_attachments.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _owner = 'owner-1';

Map<String, dynamic> _ok(Object? data) => {'data': data};

/// ApiClient backed by [handler]; `null` from the handler = no network (SocketException).
ApiClient _client(
  OfflineCache cache,
  Future<http.Response?> Function(http.Request) handler,
) => ApiClient(
  LocalStore(),
  cache: cache,
  client: MockClient((req) async {
    final r = await handler(req);
    if (r == null) throw const SocketException('no network');
    return r;
  }),
);

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real SQLite through FFI; some Windows hosts block the native library (Application Control) -> skip there.
  String? ffiSkip;
  try {
    sqfliteFfiInit();
  } catch (e) {
    ffiSkip = 'SQLite FFI unavailable on this host: $e';
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NetStatus.reset();
  });

  group('SQLite cache store', () {
    test(
      'keeps rows per owner, replaces by key, clears and reports size',
      () async {
        final store = SqliteKvStore(databaseFactoryFfi, inMemoryDatabasePath);
        final at = DateTime(2026, 11, 28, 8, 15);
        await store.write('a', '/accounts', '[1]', at);
        await store.write(
          'a',
          '/accounts',
          '[2]',
          at.add(const Duration(minutes: 1)),
        );
        await store.write('b', '/accounts', '[9]', at);
        expect((await store.read('a', '/accounts'))!.json, '[2]');
        expect((await store.read('b', '/accounts'))!.json, '[9]');
        expect(await store.read('a', '/categories'), isNull);
        expect(await store.lastWrite('a'), at.add(const Duration(minutes: 1)));
        expect(await store.sizeBytes(), greaterThan(0));
        await store.clear();
        expect(await store.read('a', '/accounts'), isNull);
      },
      skip: ffiSkip,
    );

    test('a store that cannot open simply disables caching', () async {
      final store = SqliteKvStore(_BrokenFactory(), 'x.db');
      await store.write('a', 'k', '1', DateTime.now());
      expect(await store.read('a', 'k'), isNull);
      expect(await store.sizeBytes(), 0);
    });
  });

  group('OfflineCache policy', () {
    test(
      'rarely-changing endpoints are fresh for a while, until a write command',
      () async {
        final cache = OfflineCache(MemoryKvStore(), owner: () => _owner);
        await cache.write('/categories', [1]);
        expect(await cache.fresh('/categories', '/categories'), isNotNull);
        // Balances are never reused without asking the server.
        await cache.write('/accounts', [1]);
        expect(await cache.fresh('/accounts', '/accounts'), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cache.invalidate();
        expect(await cache.fresh('/categories', '/categories'), isNull);
      },
    );

    test(
      'nothing is cached without a signed-in owner, and auth paths never',
      () async {
        final cache = OfflineCache(MemoryKvStore(), owner: () => null);
        await cache.write('/accounts', [1]);
        expect(await cache.read('/accounts'), isNull);
        expect(OfflineCache.cacheable('/auth/config'), isFalse);
        expect(OfflineCache.cacheable('/setup/start'), isFalse);
        expect(OfflineCache.cacheable('/accounts'), isTrue);
        expect(OfflineCache.keyFor('/qr', {'b': '2', 'a': '1'}), '/qr?a=1&b=2');
      },
    );
  });

  group('ApiClient: network first, saved copy when offline', () {
    test('online answers are saved; offline returns the saved copy and flags offline', () async {
      final cache = OfflineCache(MemoryKvStore(), owner: () => _owner);
      var online = true;
      var calls = 0;
      final api = _client(cache, (req) async {
        calls++;
        if (!online) return null;
        return _json(
          _ok([
            {'id': 'a1', 'balance': '500000'},
          ]),
        );
      });
      expect(await api.get('/accounts'), [
        {'id': 'a1', 'balance': '500000'},
      ]);
      expect(NetStatus.offline, isFalse);

      online = false;
      expect(await api.get('/accounts'), [
        {'id': 'a1', 'balance': '500000'},
      ]);
      expect(calls, 2); // it did try the network first
      expect(NetStatus.offline, isTrue);
      expect(NetStatus.notifier.value.dataAt, isNotNull);

      // Nothing saved for this one: the OFFLINE error goes up (ErrorView shows the calm offline state).
      await expectLater(
        api.get('/goals'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'OFFLINE')),
      );

      online = true;
      await api.get('/accounts');
      expect(NetStatus.offline, isFalse);
    });

    test('server errors are never hidden behind the cache', () async {
      final cache = OfflineCache(MemoryKvStore(), owner: () => _owner);
      await cache.write('/debts', ['old']);
      final api = _client(
        cache,
        (_) async => _json({
          'error': {'code': 'NOT_FOUND', 'message': 'Không tìm thấy dữ liệu.'},
        }, 404),
      );
      await expectLater(
        api.get('/debts'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NOT_FOUND')),
      );
    });

    test('categories come from the phone without a request; a command makes the next read ask again', () async {
      final cache = OfflineCache(MemoryKvStore(), owner: () => _owner);
      var gets = 0;
      final api = _client(cache, (req) async {
        if (req.method == 'GET') {
          gets++;
          return _json(_ok(['Ăn uống']));
        }
        return _json(_ok({'status': 'COMMITTED'}));
      });
      await api.get('/categories');
      await api.get('/categories');
      expect(gets, 1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await api.command('TX_CREATE', {}, commandId: 'c1');
      await api.get('/categories');
      expect(gets, 2);
    });
  });

  group('outbox shown before it is sent', () {
    PendingCommand cmd(String id, Map<String, dynamic> p, {String? error}) =>
        PendingCommand(
          commandId: id,
          type: 'TX_CREATE',
          payload: p,
          createdAt: DateTime(2026, 11, 28, 9),
          error: error,
        );

    test('pending transactions and balances include offline entries', () {
      final box = OutboxState(
        items: [
          cmd('c1', {
            'kind': 'EXPENSE',
            'account_id': 'cash',
            'amount': '65000',
            'effective_at': '2026-11-28T02:00:00Z',
            'note': 'Cơm trưa',
          }),
          cmd('c2', {
            'kind': 'TRANSFER',
            'account_id': 'bank',
            'to_account_id': 'cash',
            'amount': '200000',
            'fee': '1000',
            'effective_at': '2026-11-28T03:00:00Z',
          }),
          cmd('c3', {
            'kind': 'INCOME',
            'account_id': 'bank',
            'amount': '5',
          }, error: 'Bị từ chối'),
        ],
      );
      final pending = pendingTransactions(box);
      expect(pending.map((t) => t.id), ['pending:c2', 'pending:c1']);
      expect(pending.every((t) => t.pending), isTrue);

      Account acc(String id, int? bal) => Account(
        id: id,
        kind: 'CASH',
        institution: 'x',
        name: id,
        last4: null,
        balance: bal,
        version: 1,
      );
      final out = withPendingBalances([
        acc('cash', 500000),
        acc('bank', 1000000),
        acc('unknown', null),
      ], box);
      expect(out[0].balance, 500000 - 65000 + 200000);
      expect(
        out[1].balance,
        1000000 - 200000 - 1000,
      ); // rejected c3 is not counted
      expect(out[2].balance, isNull);
    });
  });

  group('VietQR built on the phone', () {
    // Plain QR made by the server for TPBank (BIN 970423) account 46414102004.
    final plain = vietQrPayload(bin: '970423', accountNumber: '46414102004');

    test('matches the server format and CRC', () {
      expect(plain.startsWith('000201010211'), isTrue);
      expect(plain.substring(plain.length - 8, plain.length - 4), '6304');
      final body = plain.substring(0, plain.length - 4);
      expect(plain.substring(plain.length - 4), vietQrCrc16(body));
      // Known CRC-16/CCITT-FALSE check value.
      expect(vietQrCrc16('123456789'), '29B1');
    });

    test('adds amount and ASCII note to a saved QR, offline', () {
      final q = vietQrWithAmount(
        plain,
        amount: 150000,
        note: 'Tiền ăn trưa đ',
      )!;
      expect(q.contains('010212'), isTrue); // dynamic QR
      expect(q.contains('5406150000'), isTrue);
      expect(q.contains('Tien an trua d'), isTrue);
      expect(vietQrAccountNumber(q), '46414102004');
      expect(vietQrTarget(q), (bin: '970423', account: '46414102004'));
      expect(vietQrWithAmount('not a qr'), isNull);
    });
  });

  group('pictures offline', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('moma_att'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    AttachmentFiles files() => AttachmentFiles(
      cacheRoot: () async => Directory('${tmp.path}/cache'),
      queueRoot: () async => Directory('${tmp.path}/queue'),
    );

    test('a viewed picture opens later without network', () async {
      var online = true;
      final api = _BytesApi(() => online);
      final c = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          attachmentFilesProvider.overrideWithValue(files()),
        ],
      );
      addTearDown(c.dispose);
      expect(await c.read(attachmentBytesProvider('p1').future), [1, 2, 3]);
      online = false;
      final c2 = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          attachmentFilesProvider.overrideWithValue(files()),
        ],
      );
      addTearDown(c2.dispose);
      expect(await c2.read(attachmentBytesProvider('p1').future), [1, 2, 3]);
      expect(api.calls, 1);
    });

    test('pictures chosen offline are kept and uploaded when online', () async {
      var online = false;
      final api = _BytesApi(() => online);
      final c = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          attachmentFilesProvider.overrideWithValue(files()),
        ],
      );
      addTearDown(c.dispose);
      final q = c.read(uploadQueueProvider.notifier);
      await q.add(
        'tx1',
        Uint8List.fromList([0xff, 0xd8, 0xff, 1]),
        'image/jpeg',
      );
      expect(c.read(uploadQueueProvider).single.txId, 'tx1');
      expect(await q.flush(), 0); // still offline: kept
      expect(c.read(uploadQueueProvider), hasLength(1));

      // Survives an app restart (index + file on disk).
      final c2 = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          attachmentFilesProvider.overrideWithValue(files()),
        ],
      );
      addTearDown(c2.dispose);
      c2.read(uploadQueueProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c2.read(uploadQueueProvider), hasLength(1));

      online = true;
      expect(await c2.read(uploadQueueProvider.notifier).flush(), 1);
      expect(api.uploads.single, '/transactions/tx1/attachments');
      expect(c2.read(uploadQueueProvider), isEmpty);
    });
  });

  group('screens while offline', () {
    testWidgets('banner tells how old the data is; nothing shown when online', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildMomaTheme(),
            home: const Scaffold(body: OfflineBanner()),
          ),
        ),
      );
      expect(find.textContaining('Đang offline'), findsNothing);
      NetStatus.wentOffline(
        dataAt: DateTime.now().copyWith(hour: 8, minute: 15),
      );
      await tester.pump();
      expect(find.text('Đang offline · cập nhật lúc 08:15'), findsOneWidget);
      NetStatus.online();
      await tester.pump();
      expect(find.textContaining('Đang offline'), findsNothing);
    });

    testWidgets(
      'ErrorView: offline is calm and reloads by itself when back online',
      (tester) async {
        var retries = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildMomaTheme(),
            home: Scaffold(
              body: ErrorView(
                error: ApiException('OFFLINE', 'x', retryable: true),
                onRetry: () => retries++,
              ),
            ),
          ),
        );
        expect(find.text('Đang offline'), findsOneWidget);
        expect(
          find.textContaining('MoMa sẽ tự tải khi có mạng'),
          findsOneWidget,
        );
        NetStatus.wentOffline();
        await tester.pump();
        NetStatus.online();
        await tester.pump();
        expect(retries, 1);
      },
    );

    testWidgets('real errors still show as errors', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMomaTheme(),
          home: Scaffold(
            body: ErrorView(
              error: ApiException('NOT_FOUND', 'Không tìm thấy dữ liệu.'),
              onRetry: () {},
            ),
          ),
        ),
      );
      expect(find.text('Không tải được dữ liệu'), findsOneWidget);
      expect(find.text('Không tìm thấy dữ liệu.'), findsOneWidget);
    });

    testWidgets('picture placeholder says it will appear when online', (
      tester,
    ) async {
      final api = _BytesApi(() => false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(api),
            attachmentFilesProvider.overrideWithValue(
              AttachmentFiles(
                cacheRoot: () async => null,
                queueRoot: () async => null,
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildMomaTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: TxAttachmentsSection(txId: 'tx1'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ảnh sẽ hiện khi có mạng'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });
  });
}

/// Attachment API: one picture p1 on tx1; offline = OFFLINE errors.
class _BytesApi extends ApiClient {
  _BytesApi(this._online) : super(LocalStore());
  final bool Function() _online;
  int calls = 0;
  final uploads = <String>[];

  ApiException get _off => ApiException('OFFLINE', 'offline', retryable: true);

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/transactions/tx1/attachments') {
      return [
        {
          'id': 'p1',
          'tx_id': 'tx1',
          'content_type': 'image/jpeg',
          'size_bytes': 3,
          'created_at': '2026-11-28T01:00:00Z',
        },
      ];
    }
    throw ApiException('NOT_FOUND', path);
  }

  @override
  Future<List<int>> getBytes(String path) async {
    calls++;
    if (!_online()) throw _off;
    return [1, 2, 3];
  }

  @override
  Future<dynamic> postBytes(
    String path,
    List<int> bytes, {
    String contentType = 'image/jpeg',
  }) async {
    if (!_online()) throw _off;
    uploads.add(path);
    return {'id': 'new'};
  }
}

class _BrokenFactory implements DatabaseFactory {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('no sqlite here'));
}
