import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/features/notify_capture/notify_capture_service.dart';
import 'package:moma/features/notify_capture/parser.dart';

import 'support/fake_api.dart';

// Re-posted notifications must not record the same payment twice; two real payments of the same amount must both
// be recorded (D-024, client side).
CapturedNotification _n(
  String key,
  String pkg,
  String title,
  String text,
  DateTime at,
) => CapturedNotification(
  key: key,
  package: pkg,
  title: title,
  text: text,
  postTime: at,
);

const _vcb = 'com.VCB';
const _momo = 'com.mservice.momotransfer';
final _t0 = DateTime(2026, 11, 28, 8, 1);

/// Records server-side idempotency: same id + same payload = REPLAYED, same id + other payload = mismatch.
class _IdemApi extends FakeApi {
  final seen = <String, String>{};
  int recorded = 0;
  @override
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    final body = payload.toString();
    final before = seen[commandId];
    if (before != null) {
      if (before != body) {
        throw ApiException(
          'DUPLICATE_KEY_MISMATCH',
          'Khóa đã dùng cho nội dung khác.',
        );
      }
      return {'status': 'REPLAYED', 'tx_id': 'tx'};
    }
    seen[commandId] = body;
    recorded++;
    return {'status': 'COMMITTED', 'tx_id': 'tx$recorded'};
  }
}

Future<bool> _rec(_IdemApi api, CapturedNotification n, RecentCaptures recent) {
  final p = n.parsed;
  return recordNotification(
    api,
    n,
    accountId: 'a1',
    direction: p.direction!,
    amount: p.amount!,
    recent: recent,
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('command id per real payment', () {
    test('a re-post with the same balance (new notification key, new time) gets the same id', () {
      final a = _n(
        'k1',
        _vcb,
        'Thông báo VCB',
        'Số dư TK VCB 0011001234567 -25,000 VND lúc 28-11-2026 08:01:10. Số dư 1,975,000 VND. Ref MBVCB.123 thanh toan',
        _t0,
      );
      final b = _n(
        'k2',
        _vcb,
        'Thông báo VCB',
        'Số dư TK VCB 0011001234567 -25,000 VND lúc 28-11-2026 08:01:40. Số dư 1,975,000 VND. Ref MBVCB.123 thanh toan',
        _t0.add(const Duration(seconds: 30)),
      );
      expect(
        notifyCommandId(a, accountId: 'a1'),
        notifyCommandId(b, accountId: 'a1'),
      );
    });

    test(
      'two genuine 25.000đ coffees: different balances -> different ids',
      () {
        final a = _n(
          'k1',
          _momo,
          'Thanh toán thành công',
          'Bạn đã thanh toán 25.000đ cho Phúc Long. Số dư ví: 200.000đ',
          _t0,
        );
        final b = _n(
          'k2',
          _momo,
          'Thanh toán thành công',
          'Bạn đã thanh toán 25.000đ cho Phúc Long. Số dư ví: 175.000đ',
          _t0.add(const Duration(minutes: 2)),
        );
        expect(
          notifyCommandId(a, accountId: 'a1'),
          isNot(notifyCommandId(b, accountId: 'a1')),
        );
      },
    );

    test('without code / reference / balance only the notification key is left (fingerprint needed)', () {
      final a = _n(
        'k1',
        _momo,
        'Thanh toán thành công',
        'Bạn đã thanh toán 45.000đ cho Highlands Coffee',
        _t0,
      );
      expect(needsFingerprint(a), isTrue);
      final withBalance = _n(
        'k1',
        _momo,
        'Thanh toán thành công',
        'Bạn đã thanh toán 65.000đ cho Highlands Coffee. Số dư ví: 1.200.000đ',
        _t0,
      );
      expect(needsFingerprint(withBalance), isFalse);
    });

    test(
      'the fingerprint ignores times and dates but keeps amounts and codes',
      () {
        final a = _n(
          'k1',
          _momo,
          'Thanh toán thành công',
          'Lúc 08:01 28/11 bạn đã thanh toán 45.000đ cho Highlands',
          _t0,
        );
        final b = _n(
          'k2',
          _momo,
          'Thanh toán thành công',
          'Lúc 08:02 28/11 bạn đã thanh toán 45.000đ cho Highlands',
          _t0,
        );
        final c = _n(
          'k3',
          _momo,
          'Thanh toán thành công',
          'Lúc 08:02 28/11 bạn đã thanh toán 45.000đ cho Phúc Long',
          _t0,
        );
        String fp(CapturedNotification n) => captureFingerprint(
          n,
          amount: 45000,
          direction: NotifyDirection.outflow,
        );
        expect(fp(a), fp(b));
        expect(fp(a), isNot(fp(c)));
      },
    );
  });

  group('recordNotification', () {
    test(
      'a re-post without any unique code within 10 minutes is recorded once',
      () async {
        final api = _IdemApi();
        final recent = RecentCaptures();
        final a = _n(
          'k1',
          _momo,
          'Thanh toán thành công',
          'Bạn đã thanh toán 45.000đ cho Highlands Coffee lúc 12:03',
          _t0,
        );
        final b = _n(
          'k2',
          _momo,
          'Thanh toán thành công',
          'Bạn đã thanh toán 45.000đ cho Highlands Coffee lúc 12:04',
          _t0.add(const Duration(minutes: 1)),
        );
        expect(await _rec(api, a, recent), isTrue);
        expect(
          await _rec(api, b, recent),
          isFalse,
        ); // same id, other payload: mismatch = already recorded
        expect(api.recorded, 1);
      },
    );

    test('the same text again after the window is a new payment', () async {
      final api = _IdemApi();
      final recent = RecentCaptures();
      final a = _n(
        'k1',
        _momo,
        'Thanh toán thành công',
        'Bạn đã thanh toán 45.000đ cho Highlands Coffee',
        _t0,
      );
      final b = _n(
        'k2',
        _momo,
        'Thanh toán thành công',
        'Bạn đã thanh toán 45.000đ cho Highlands Coffee',
        _t0.add(const Duration(minutes: 11)),
      );
      expect(await _rec(api, a, recent), isTrue);
      expect(await _rec(api, b, recent), isTrue);
      expect(api.recorded, 2);
    });

    test('a bank re-post with the same balance is recorded once; two real payments are both recorded', () async {
      final api = _IdemApi();
      final recent = RecentCaptures();
      final first = _n(
        'k1',
        _vcb,
        'Thông báo VCB',
        'Số dư TK VCB 0011001234567 -25,000 VND lúc 28-11-2026 08:01:10. Số dư 1,975,000 VND. Ref MBVCB.1 thanh toan',
        _t0,
      );
      final repost = _n(
        'k2',
        _vcb,
        'Thông báo VCB',
        'Số dư TK VCB 0011001234567 -25,000 VND lúc 28-11-2026 08:01:10. Số dư 1,975,000 VND. Ref MBVCB.1 thanh toan',
        _t0.add(const Duration(seconds: 20)),
      );
      final second = _n(
        'k3',
        _vcb,
        'Thông báo VCB',
        'Số dư TK VCB 0011001234567 -25,000 VND lúc 28-11-2026 08:03:00. Số dư 1,950,000 VND. Ref MBVCB.2 thanh toan',
        _t0.add(const Duration(minutes: 2)),
      );
      expect(await _rec(api, first, recent), isTrue);
      expect(await _rec(api, repost, recent), isFalse);
      expect(await _rec(api, second, recent), isTrue);
      expect(api.recorded, 2);
    });

    test('other server errors still surface', () async {
      final api = FakeApi()
        ..failNext = ApiException('INVALID_AMOUNT', 'Số tiền không hợp lệ.');
      final a = _n(
        'k1',
        _momo,
        'Thanh toán thành công',
        'Bạn đã thanh toán 45.000đ cho Highlands Coffee',
        _t0,
      );
      expect(
        () => recordNotification(
          api,
          a,
          accountId: 'a1',
          direction: NotifyDirection.outflow,
          amount: 45000,
          recent: RecentCaptures(),
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
