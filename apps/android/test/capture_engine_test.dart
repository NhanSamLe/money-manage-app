import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moma/core/models.dart';
import 'package:moma/features/notify_capture/capture_engine.dart';
import 'package:moma/features/notify_capture/notify_capture_service.dart';
import 'package:moma/features/notify_capture/parser.dart';

import 'support/fake_api.dart';

/// In-memory ledger: accounts with balances, records transactions (replays by notification key).
class _Ledger implements CaptureLedger {
  _Ledger({List<Account>? accounts, this.linked = const {}})
    : list = accounts ?? [];
  final List<Account> list;
  final Set<String> linked;
  final created = <Map<String, Object?>>[];
  final recorded = <String>{};
  final updates = <Map<String, dynamic>>[];
  var _n = 0;

  int? balanceOf(String id) => list.firstWhere((a) => a.id == id).balance;
  void _set(String id, int? balance, {String? last4, int bump = 0}) {
    final i = list.indexWhere((a) => a.id == id);
    final a = list[i];
    list[i] = Account(
      id: a.id,
      kind: a.kind,
      institution: a.institution,
      name: a.name,
      last4: last4 ?? a.last4,
      balance: balance,
      version: a.version + bump,
    );
  }

  @override
  Future<List<Account>> accounts() async => [...list];
  @override
  Future<List<Category>> categories() async => [];
  @override
  Future<Set<String>> linkedAccountIds() async => linked;

  @override
  Future<String> createAccount({
    required String kind,
    required String institution,
    required String name,
    String? last4,
    int? opening,
    DateTime? baselineAt,
  }) async {
    final id = 'new-${++_n}';
    created.add({
      'kind': kind,
      'institution': institution,
      'name': name,
      'last4': last4,
      'opening': opening,
      'baselineAt': baselineAt,
    });
    list.add(
      Account(
        id: id,
        kind: kind,
        institution: institution,
        name: name,
        last4: last4,
        balance: opening,
        version: 1,
      ),
    );
    return id;
  }

  @override
  Future<bool> record(
    CapturedNotification n, {
    required String accountId,
    required NotifyDirection direction,
    required int amount,
    required List<Category> categories,
  }) async {
    if (!recorded.add(n.key)) return false;
    final b = balanceOf(accountId);
    if (b != null) {
      _set(
        accountId,
        b + (direction == NotifyDirection.inflow ? amount : -amount),
      );
    }
    return true;
  }

  @override
  Future<void> updateAccount(Account a, Map<String, dynamic> fields) async {
    updates.add({'id': a.id, ...fields});
    final bal = fields['balance'] == null
        ? balanceOf(a.id)
        : int.parse('${fields['balance']}');
    _set(a.id, bal, last4: fields['last4'] as String?, bump: 1);
  }
}

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

Account _acc(
  String id,
  String kind,
  String inst, {
  int? balance,
  String? last4,
}) => Account(
  id: id,
  kind: kind,
  institution: inst,
  name: inst,
  last4: last4,
  balance: balance,
  version: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  final t0 = DateTime(2026, 11, 28, 3, 0);

  test('gap math: lower, higher, equal, with open gaps', () {
    expect(balanceGap(momaBalance: 100000, reported: 70000), -30000);
    expect(balanceGap(momaBalance: 100000, reported: 120000), 20000);
    expect(balanceGap(momaBalance: 100000, reported: 100000), 0);
    expect(
      balanceGap(momaBalance: 100000, reported: 70000, openGaps: -30000),
      0,
    );
  });

  test('owner queue on upgrade: VCB auto-created at the reported balance, TPBank (SePay-linked) skipped, MoMo created', () async {
    final ledger = _Ledger(
      accounts: [_acc('tp', 'BANK', 'TPBank', balance: 4000, last4: '2004')],
      linked: {'tp'},
    );
    final prefs = NotifyCapturePrefs();
    final items = [
      _n(
        'vcb',
        'com.VCB',
        '',
        'Số dư TK VCB 1026746096 +4,000 VND lúc 28-11-2026 03:24:23. Số dư 13,684,007 VND. Ref 159036437923-LE DAO NHAN SAM chuyen tien qua MoMo',
        t0.add(const Duration(minutes: 24)),
      ),
      _n(
        'tpb',
        'com.tpb.mb.gprsandroid',
        '',
        '(TPBank): 28/11/26;03:08\nTK: xxxx4102004\nPS:+4.000VND\nSD: 4.000VND\nSD KHA DUNG: 4.000VND',
        t0.add(const Duration(minutes: 8)),
      ),
      _n(
        'momo',
        momoPackage,
        'Nhận tiền chuyển khoản từ LE DAO NHAN SAM',
        'Số tiền 10.000 ₫, kèm lời nhắn: "LE DAO NHAN SAM chuyen FT26332327719412".',
        t0.add(const Duration(minutes: 20)),
      ),
    ];
    final out = await runCapture(items: items, ledger: ledger, prefs: prefs);
    expect(out.acked.toSet(), {'vcb', 'tpb', 'momo'});
    expect(out.recorded, 2);
    expect(ledger.recorded, {'vcb', 'momo'}); // TPBank comes from SePay
    final vcb = ledger.created.firstWhere((c) => c['name'] == 'Vietcombank');
    expect(vcb['kind'], 'BANK');
    expect(vcb['opening'], 13680007);
    expect(vcb['last4'], '6096');
    final vcbId = ledger.list.firstWhere((a) => a.name == 'Vietcombank').id;
    expect(ledger.balanceOf(vcbId), 13684007); // equals the bank after the tx
    final momo = ledger.created.firstWhere((c) => c['name'] == 'MoMo');
    expect(momo['kind'], 'WALLET');
    expect(momo['opening'], isNull);
    final map = await prefs.accountMap();
    expect(map['com.VCB'], vcbId);
    expect(map.containsKey('com.tpb.mb.gprsandroid'), isFalse);
    expect((await prefs.accountNumbers())[vcbId], '1026746096');
    expect(out.gaps, isEmpty);
  });

  test(
    'reported balance LOWER than expected: a missing-spending gap, not posted',
    () async {
      final ledger = _Ledger(
        accounts: [_acc('mm', 'WALLET', 'MoMo', balance: 500000)],
      );
      final prefs = NotifyCapturePrefs();
      await prefs.setAccount(momoPackage, 'mm');
      final out = await runCapture(
        items: [
          _n(
            '1',
            momoPackage,
            'MoMo',
            'Nhận được +100.000đ. Số dư ví: 450.000đ',
            t0,
          ),
        ],
        ledger: ledger,
        prefs: prefs,
      );
      expect(
        out.gaps.single.amount,
        -150000,
      ); // 500k + 100k expected, 450k reported
      expect(out.gaps.single.missingOutflow, isTrue);
      expect(ledger.balanceOf('mm'), 600000); // gap is never posted by itself
      expect((await prefs.gaps()).single.reported, 450000);
    },
  );

  test('HIGHER: a missing-income gap; EQUAL: none; repeated notifications do not double the gap', () async {
    final ledger = _Ledger(
      accounts: [_acc('mm', 'WALLET', 'MoMo', balance: 100000)],
    );
    final prefs = NotifyCapturePrefs();
    await prefs.setAccount(momoPackage, 'mm');
    final out1 = await runCapture(
      items: [
        _n('a', momoPackage, '', 'Nhận được +10.000đ. Số dư ví: 110.000đ', t0),
        _n(
          'b',
          momoPackage,
          '',
          'Nhận được +20.000đ. Số dư ví: 150.000đ',
          t0.add(const Duration(hours: 1)),
        ),
        _n(
          'c',
          momoPackage,
          '',
          'Nhận được +5.000đ. Số dư ví: 155.000đ',
          t0.add(const Duration(hours: 2)),
        ),
      ],
      ledger: ledger,
      prefs: prefs,
    );
    // a: equal. b: 130k expected vs 150k -> +20k. c: 135k + 20k open = 155k -> no new gap.
    expect(out1.gaps.map((g) => g.amount), [20000]);
    expect(out1.gaps.single.from, t0); // last time the balance matched
    expect((await prefs.gaps()).length, 1);
  });

  test('unknown balance on an existing account: the reported balance becomes MoMa\'s', () async {
    final ledger = _Ledger(accounts: [_acc('v', 'BANK', 'Vietcombank')]);
    final prefs = NotifyCapturePrefs();
    final out = await runCapture(
      items: [
        _n('x', 'com.VCB', '', 'TK 1234 +50,000 VND. So du 1,050,000 VND', t0),
      ],
      ledger: ledger,
      prefs: prefs,
    );
    expect(ledger.created, isEmpty); // matched the existing Vietcombank account
    expect(ledger.updates.single, containsPair('balance', '1050000'));
    expect(ledger.updates.single, containsPair('last4', '1234'));
    expect(out.gaps, isEmpty);
  });

  test(
    'auto-record off: nothing happens; unparsed items stay pending',
    () async {
      final prefs = NotifyCapturePrefs();
      await prefs.setAutoRecord(false);
      final ledger = _Ledger();
      final out = await runCapture(
        items: [_n('x', momoPackage, 'MoMo', 'Nhận được +10.000đ', t0)],
        ledger: ledger,
        prefs: prefs,
      );
      expect(out.acked, isEmpty);
      await prefs.setAutoRecord(true);
      final out2 = await runCapture(
        items: [_n('y', momoPackage, 'MoMo', 'Xác nhận giao dịch của bạn', t0)],
        ledger: ledger,
        prefs: prefs,
      );
      expect(out2.acked, isEmpty);
      expect(ledger.created, isEmpty);
    },
  );

  test('reportBalance (weekly wallet update / shared receipt)', () async {
    final prefs = NotifyCapturePrefs();
    final ledger = _Ledger(
      accounts: [_acc('mm', 'WALLET', 'MoMo', balance: 300000)],
    );
    final gap = await reportBalance(
      account: ledger.list.first,
      reported: 250000,
      ledger: ledger,
      prefs: prefs,
    );
    expect(gap!.amount, -50000);
    final none = await reportBalance(
      account: ledger.list.first,
      reported: 250000,
      ledger: ledger,
      prefs: prefs,
    );
    expect(none, isNull); // the open gap already explains it
  });

  test(
    'real API commands for the zero-tap path (VCB opening balance)',
    () async {
      final api = _FakeLedgerApi();
      final prefs = NotifyCapturePrefs();
      final at = DateTime.utc(2026, 11, 27, 20, 24, 23);
      final out = await runCapture(
        items: [
          _n(
            'vcb',
            'com.VCB',
            '',
            'Số dư TK VCB 1026746096 +4,000 VND lúc 28-11-2026 03:24:23. Số dư 13,684,007 VND. Ref 159036437923-LE DAO NHAN SAM chuyen tien qua MoMo',
            at,
          ),
        ],
        ledger: ApiCaptureLedger(api),
        prefs: prefs,
      );
      expect(out.recorded, 1);
      final create = api.commands.firstWhere((c) => c.type == 'ACCOUNT_CREATE');
      expect(create.payload, {
        'kind': 'BANK',
        'institution': 'Vietcombank',
        'name': 'Vietcombank',
        'last4': '6096',
        'opening_amount': '13680007',
        'baseline_at': '2026-11-27T20:24:22.000Z',
      });
      final tx = api.commands.firstWhere((c) => c.type == 'TX_CREATE');
      expect(tx.payload['account_id'], 'acc-new');
      expect(tx.payload['amount'], '4000');
      expect(tx.payload['source'], 'NOTIFICATION');
      expect(tx.payload['effective_at'], '2026-11-27T20:24:23.000Z');
    },
  );
}

class _FakeLedgerApi extends FakeApi {
  _FakeLedgerApi()
    : super(
        data: {
          ...FakeApi.defaultData(),
          '/banks/links': <Object>[],
          '/accounts': <Object>[],
        },
      );
  @override
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    final r = await super.command(type, payload, commandId: commandId);
    return type == 'ACCOUNT_CREATE' ? {...r, 'account_id': 'acc-new'} : r;
  }
}
