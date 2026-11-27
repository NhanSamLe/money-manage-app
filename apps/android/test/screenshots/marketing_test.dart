// Renders marketing screenshots of real MoMa screens with clearly fake sample data.
//
//   MOMA_SCREENSHOTS=1 flutter test test/screenshots
//
// Opt-in (skipped otherwise) so `flutter test`, CI and the release script stay fast.
// Raw captures land in build/screenshots/ (git-ignored); `python scripts/frame.py` in this folder
// frames them into docs/images/. Nothing here talks to a server: every request is answered by
// [_SampleApi]. Fonts: Be Vietnam Pro (SIL OFL, bundled under fonts/) is registered under the
// family names google_fonts uses, plus the icon fonts from the app's FontManifest, so text and
// icons render with real glyphs instead of test boxes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/ui/header.dart';
import 'package:moma/core/ui/motion.dart';
import 'package:moma/core/ui/nav.dart';
import 'package:moma/features/accounts/accounts_page.dart';
import 'package:moma/features/accounts/sync/sync_sources.dart';
import 'package:moma/features/assistant/assistant_page.dart';
import 'package:moma/features/banks/receive_page.dart';
import 'package:moma/features/dashboard/dashboard_page.dart';
import 'package:moma/features/dashboard/reports_page.dart';
import 'package:moma/features/planning/planning_page.dart';

import '../support/fake_api.dart';

const _logical = Size(412, 915);
const _dpr = 2.625;
const _statusBar =
    28.0; // logical px reserved at the top for the framed status bar
const _gestureBar = 16.0;
final _outDir = Directory('build/screenshots');

// ---------------------------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------------------------

Future<void> _loadFonts() async {
  final dir = 'test/screenshots/fonts';
  ByteData read(String f) =>
      ByteData.sublistView(File('$dir/BeVietnamPro-$f.ttf').readAsBytesSync());
  final byWeight = <int, String>{
    100: 'Regular',
    200: 'Regular',
    300: 'Regular',
    400: 'Regular',
    500: 'Medium',
    600: 'SemiBold',
    700: 'Bold',
    800: 'ExtraBold',
    900: 'ExtraBold',
  };
  // google_fonts styles text as `BeVietnamPro_<variant>` with fallback `BeVietnamPro`.
  for (final e in byWeight.entries) {
    final variant = e.key == 400 ? 'regular' : '${e.key}';
    final loader = FontLoader('BeVietnamPro_$variant')
      ..addFont(Future.value(read(e.value)));
    await loader.load();
  }
  // Text styles without a family fall back to the test font (`FlutterTest`); map it to Be Vietnam Pro too.
  for (final family in ['BeVietnamPro', 'Roboto', 'FlutterTest']) {
    final loader = FontLoader(family);
    for (final f in {'Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'}) {
      loader.addFont(Future.value(read(f)));
    }
    await loader.load();
  }
  // Icon fonts (Material Icons, Material Symbols) from the test asset bundle.
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

// ---------------------------------------------------------------------------------------------
// Sample data (fictional owner "Minh"; numbers are made up)
// ---------------------------------------------------------------------------------------------

String _at(int daysAgo, int hour, int minute) {
  final now = DateTime.now();
  final local = DateTime(
    now.year,
    now.month,
    now.day,
    hour,
    minute,
  ).subtract(Duration(days: daysAgo));
  return local.toUtc().toIso8601String();
}

/// Days ago that still fall inside the current month (so the month charts have data).
int _d(int n) => n.clamp(0, DateTime.now().day - 1);

Map<String, dynamic> _tx(
  String id,
  String kind,
  int amount,
  String at, {
  String account = 'vcb',
  String? to,
  String? category,
  String? merchant,
  String? note,
  String source = 'MANUAL',
}) => {
  'id': id,
  'kind': kind,
  'status': 'POSTED',
  'effective_at': at,
  'amount': '$amount',
  'fee': '0',
  'account_id': account,
  'to_account_id': to,
  'category_id': category,
  'merchant': merchant,
  'note': note,
  'version': 1,
  'related_tx_id': null,
  'contact_id': null,
  'debt_linked': false,
  'source': source,
};

String _vietQr({
  required String bin,
  required String account,
  int? amount,
  String? note,
}) {
  String f(String tag, String v) =>
      '$tag${v.length.toString().padLeft(2, '0')}$v';
  final beneficiary = f('00', bin) + f('01', account);
  final merchant =
      f('00', 'A000000727') + f('01', beneficiary) + f('02', 'QRIBFTTA');
  final s = [
    f('00', '01'),
    f('01', amount == null ? '11' : '12'),
    f('38', merchant),
    f('53', '704'),
    if (amount != null) f('54', '$amount'),
    f('58', 'VN'),
    if (note != null && note.isNotEmpty) f('62', f('08', note)),
    '6304',
  ].join();
  var crc = 0xFFFF;
  for (final b in utf8.encode(s)) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return s + crc.toRadixString(16).toUpperCase().padLeft(4, '0');
}

class _SampleApi extends FakeApi {
  _SampleApi() : super(data: _data());

  static Map<String, dynamic> _data() {
    final d = FakeApi.defaultData();
    d['/profile'] = {'display_name': 'Nguyễn Minh'};
    d['/accounts'] = [
      {
        'id': 'vcb',
        'kind': 'BANK',
        'institution': 'Vietcombank',
        'name': 'Vietcombank',
        'last4': '1234',
        'balance': '18450000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
      {
        'id': 'tcb',
        'kind': 'BANK',
        'institution': 'Techcombank',
        'name': 'Techcombank',
        'last4': '5678',
        'balance': '6200000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
      {
        'id': 'momo',
        'kind': 'WALLET',
        'institution': 'MoMo',
        'name': 'Ví MoMo',
        'last4': null,
        'balance': '845000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
      {
        'id': 'cash',
        'kind': 'CASH',
        'institution': 'Ví',
        'name': 'Tiền mặt',
        'last4': null,
        'balance': '1320000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
    ];
    d['/categories'] = [
      for (final c in [
        ('c-food', 'EXPENSE', 'Ăn uống', 'restaurant'),
        ('c-move', 'EXPENSE', 'Di chuyển', 'directions_car'),
        ('c-shop', 'EXPENSE', 'Mua sắm', 'shopping_bag'),
        ('c-bill', 'EXPENSE', 'Hóa đơn', 'receipt_long'),
        ('c-fun', 'EXPENSE', 'Giải trí', 'movie'),
        ('c-salary', 'INCOME', 'Lương', 'payments'),
        ('c-bonus', 'INCOME', 'Thưởng', 'redeem'),
      ])
        {
          'id': c.$1,
          'type': c.$2,
          'name': c.$3,
          'icon': c.$4,
          'parent_id': null,
          'version': 1,
        },
    ];
    d['/reports/summary'] = {
      'income': '24500000',
      'expense': '9860000',
      'net_worth': '26815000',
      'receivable': '1500000',
      'payable': '0',
      'accounts_unknown_baseline': 0,
      'expense_by_category': [
        {
          'category_id': 'c-food',
          'name': 'Ăn uống',
          'icon': 'restaurant',
          'amount': '3820000',
        },
        {
          'category_id': 'c-bill',
          'name': 'Hóa đơn',
          'icon': 'receipt_long',
          'amount': '2450000',
        },
        {
          'category_id': 'c-shop',
          'name': 'Mua sắm',
          'icon': 'shopping_bag',
          'amount': '1890000',
        },
        {
          'category_id': 'c-move',
          'name': 'Di chuyển',
          'icon': 'directions_car',
          'amount': '1100000',
        },
        {
          'category_id': 'c-fun',
          'name': 'Giải trí',
          'icon': 'movie',
          'amount': '600000',
        },
      ],
    };
    d['/transactions'] = [
      _tx(
        't1',
        'EXPENSE',
        45000,
        _at(0, 7, 40),
        account: 'cash',
        category: 'c-food',
        merchant: 'Phở Thìn',
        source: 'AI',
      ),
      _tx(
        't2',
        'EXPENSE',
        60000,
        _at(0, 8, 5),
        account: 'momo',
        category: 'c-move',
        merchant: 'Đổ xăng',
        source: 'NOTIFICATION',
      ),
      _tx(
        't3',
        'INCOME',
        24500000,
        _at(_d(DateTime.now().day - 5), 9, 0),
        category: 'c-salary',
        note: 'Lương tháng',
        source: 'BANK',
      ),
      _tx(
        't4',
        'EXPENSE',
        1250000,
        _at(_d(4), 19, 30),
        account: 'tcb',
        category: 'c-shop',
        merchant: 'Siêu thị',
        source: 'BANK',
      ),
      _tx(
        't5',
        'EXPENSE',
        890000,
        _at(_d(6), 10, 0),
        category: 'c-bill',
        merchant: 'Tiền điện',
        source: 'BANK',
      ),
      _tx(
        't6',
        'TRANSFER',
        500000,
        _at(_d(7), 12, 0),
        to: 'momo',
        note: 'Nạp ví',
      ),
      for (var i = 8; i < 27; i++)
        _tx(
          'h$i',
          'EXPENSE',
          35000 + (i * 37 % 9) * 25000,
          _at(_d(i), 12, 15),
          account: i.isEven ? 'cash' : 'vcb',
          category: ['c-food', 'c-move', 'c-shop', 'c-fun'][i % 4],
          merchant: ['Cơm văn phòng', 'Grab', 'Shopee', 'Rạp phim'][i % 4],
        ),
    ];
    d['/contacts'] = [
      {'id': 'k1', 'alias': 'Lan', 'note': null, 'version': 1},
    ];
    d['/debts'] = [
      {
        'id': 'd1',
        'direction': 'RECEIVABLE',
        'contact_id': 'k1',
        'contact_alias': 'Lan',
        'principal': '2000000',
        'remaining': '1500000',
        'state': 'PARTIAL',
        'due_date': null,
        'originated_at': _at(20, 9, 0),
        'note': null,
        'version': 1,
        'overdue': false,
      },
    ];
    d['/goals'] = {
      'goals': [
        _goal('g1', 'Du lịch Đà Lạt', 8000000, 6200000, due: 2),
        _goal('g2', 'Mua laptop mới', 25000000, 9500000, due: 8),
        _goal('g3', 'Quỹ khẩn cấp', 30000000, 30000000),
        _goal('g4', 'Học phí khóa tiếng Anh', 6000000, 1500000, due: 5),
      ],
      'accounts': [
        {'account_id': 'vcb', 'name': 'Vietcombank', 'available': '0'},
      ],
    };
    d['/budgets'] = [
      {
        'id': 'b1',
        'category_id': 'c-food',
        'category_name': 'Ăn uống',
        'icon': 'restaurant',
        'limit_amount': '4500000',
        'carryover': false,
        'version': 1,
        'spent': '3820000',
        'carried': '0',
        'remaining': '680000',
      },
    ];
    d['/recurring'] = <Object>[];
    d['/transfers/suggestions'] = <Object>[];
    d['/reminders/today'] = {
      'date': '',
      'skipped': <String>[],
      'done': {'breakfast': true, 'lunch': false, 'dinner': false},
    };
    d['/reminders/settings'] = <String, dynamic>{};
    d['/notifications'] = {'items': <Object>[], 'unread': 2};
    d['/insights'] = <Object>[];
    d['/banks/links'] = [
      {
        'account_id': 'vcb',
        'provider': 'SEPAY',
        'external_id': 'ext-vcb',
        'last4': '1234',
        'holder_name': 'NGUYEN MINH',
        'bank_name': 'Vietcombank',
        'bank_balance': '18450000',
        'bank_balance_at': _at(0, 8, 0),
      },
    ];
    d['/banks/sepay/accounts'] = [
      {
        'external_id': 'ext-vcb',
        'bank': 'Vietcombank',
        'holder': 'NGUYEN MINH',
        'number': '0123451234',
        'number_masked': '••••1234',
        'balance': '18450000',
        'active': true,
        'label': '',
        'linked': true,
      },
    ];
    return d;
  }

  static Map<String, dynamic> _goal(
    String id,
    String name,
    int target,
    int allocated, {
    int? due,
  }) {
    final now = DateTime.now();
    final dueDate = due == null ? null : DateTime(now.year, now.month + due, 1);
    return {
      'id': id,
      'name': name,
      'target': '$target',
      'allocated': '$allocated',
      'state': 'ACTIVE',
      'due_date': dueDate?.toIso8601String().substring(0, 10),
      'version': 1,
    };
  }

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/banks/sepay/qr') {
      final amount = int.tryParse(query?['amount'] ?? '');
      return {
        'payload': _vietQr(
          bin: '970436',
          account: '0123451234',
          amount: amount,
          note: query?['note'],
        ),
        'bank': 'Vietcombank',
        'holder': 'NGUYEN MINH',
        'number_masked': '••••1234',
      };
    }
    final thisMonth = DateTime.now().toIso8601String().substring(0, 7);
    if (path == '/reports/summary' &&
        query?['month'] != null &&
        query!['month'] != thisMonth) {
      return {
        ...data[path] as Map<String, dynamic>,
        'income': '23000000',
        'expense': '11240000',
      };
    }
    if (!data.containsKey(path)) return <Object>[];
    return data[path];
  }

  int _turn = 0;

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    if (path != '/ai/agent') return <String, dynamic>{};
    final month = DateTime.now().toIso8601String().substring(0, 7);
    if (_turn++ == 0) {
      return {
        'reply': 'Mình ghi 2 khoản chi sáng nay cho bạn nhé.',
        'actions': [
          {
            'id': 's1',
            'type': 'COMMAND',
            'risk': 'low',
            'undoable': true,
            'title': 'Chi 45.000 ₫',
            'lines': ['Ăn uống', 'Tiền mặt', 'Phở'],
            'command': {
              'command_type': 'TX_CREATE',
              'payload': {'amount': '45000'},
            },
          },
          {
            'id': 's2',
            'type': 'COMMAND',
            'risk': 'low',
            'undoable': true,
            'title': 'Chi 60.000 ₫',
            'lines': ['Di chuyển', 'Ví MoMo', 'Đổ xăng'],
            'command': {
              'command_type': 'TX_CREATE',
              'payload': {'amount': '60000'},
            },
          },
        ],
        'plan': [
          {'do': 'EXPENSE'},
          {'do': 'EXPENSE'},
        ],
      };
    }
    return {
      'reply': 'Tháng này bạn đã chi 9,86 triệu, vẫn trong ngân sách.',
      'actions': [
        {
          'id': 's1',
          'type': 'ANSWER',
          'what': 'SUMMARY',
          'month': month,
          'data': data['/reports/summary'],
        },
      ],
      'plan': [
        {'do': 'ANSWER', 'what': 'SUMMARY'},
      ],
    };
  }
}

// Android notification access / per-app sync for the Accounts & Sync screen.
class _Store implements NotifySyncStore {
  final map = <String, String>{'com.mservice.momotransfer': 'momo'};
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

class _Access implements NotifyAccess {
  @override
  Future<List<String>> installedApps() async => ['com.mservice.momotransfer'];
  @override
  Future<bool> isGranted() async => true;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> pendingCount() async => 0;
}

// ---------------------------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------------------------

const _navItems = <NavItem>[
  NavItem(Symbols.home_rounded, 'Trang chủ'),
  NavItem(Symbols.swap_horiz_rounded, 'Giao dịch'),
  NavItem(Symbols.auto_awesome_rounded, 'Trợ lý AI'),
  NavItem(Symbols.bar_chart_rounded, 'Báo cáo'),
  NavItem(Symbols.settings_rounded, 'Cài đặt'),
];

/// Same chrome as the app's HomeShell (bottom navigation + quick-entry button) around one tab.
Widget _shell(Widget page, int tab) => Scaffold(
  body: page,
  floatingActionButton: tab <= 1
      ? FloatingActionButton(
          onPressed: () {},
          backgroundColor: MomaColors.emerald,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          child: const Icon(Symbols.add_rounded, size: 32),
        )
      : null,
  bottomNavigationBar: MomaNavBar(
    items: _navItems,
    index: tab,
    onSelect: (_) {},
  ),
);

final _boundary = GlobalKey();

/// The app theme. Button labels have no font family there (the phone's default font draws them); the test
/// engine has no such default, so they get Be Vietnam Pro explicitly.
ThemeData _theme(Brightness brightness) {
  final t = buildMomaTheme(brightness);
  ButtonStyle? fix(ButtonStyle? s) => s?.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (states) =>
          s.textStyle?.resolve(states)?.copyWith(fontFamily: 'BeVietnamPro'),
    ),
  );
  return t.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: fix(t.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: fix(t.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(style: fix(t.textButtonTheme.style)),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required Brightness brightness,
  _SampleApi? api,
}) async {
  tester.view.physicalSize = _logical * _dpr;
  tester.view.devicePixelRatio = _dpr;
  tester.view.padding = FakeViewPadding(
    top: _statusBar * _dpr,
    bottom: _gestureBar * _dpr,
  );
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
  // flutter_test draws elevation shadows as solid outlines unless real shadows are enabled.
  debugDisableShadows = false;
  addTearDown(() => debugDisableShadows = true);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => screen)],
  );
  addTearDown(router.dispose);
  final overrides = <Override>[
    apiProvider.overrideWithValue(api ?? _SampleApi()),
    notifySyncStoreProvider.overrideWithValue(_Store()),
    notifyAccessProvider.overrideWithValue(_Access()),
    pushPermissionProvider.overrideWith((_) async => true),
  ];
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: ProviderScope(
        retry: (_, _) => null,
        overrides: overrides,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness),
          routerConfig: router,
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Lets futures resolve, decodes every image on screen (asset decoding is real async work), then settles.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  for (var round = 0; round < 2; round++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final w = e.widget as Image;
        await precacheImage(w.image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    _outDir.createSync(recursive: true);
    File('${_outDir.path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await _settle(tester);
}

final _enabled = Platform.environment['MOMA_SCREENSHOTS'] == '1';

void main() {
  if (!_enabled) {
    test(
      'marketing screenshots (set MOMA_SCREENSHOTS=1 to render)',
      () {},
      skip: true,
    );
    return;
  }
  setUpAll(() async {
    Motion.continuous = false;
    await _loadFonts();
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? 'dark' : 'light';

    testWidgets('home ($mode)', (tester) async {
      await _pump(tester, _shell(const DashboardPage(), 0), brightness: b);
      await _capture(tester, 'home-$mode');
    });

    testWidgets('reports ($mode)', (tester) async {
      await _pump(tester, _shell(const ReportsPage(), 3), brightness: b);
      await _capture(tester, 'reports-$mode');
    });

    testWidgets('assistant ($mode)', (tester) async {
      await _pump(tester, _shell(const AssistantPage(), 2), brightness: b);
      Future<void> say(String text) async {
        await tester.enterText(find.byType(TextField).last, text);
        await tester.pump();
        await tester.tap(find.byTooltip('Gửi'));
        await _settle(tester);
      }

      await say('Sáng nay ăn phở 45k, đổ xăng 60k bằng MoMo');
      await say('Tháng này mình chi bao nhiêu rồi?');
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);
      await _capture(tester, 'assistant-$mode');
    });

    testWidgets('receive QR ($mode)', (tester) async {
      await _pump(tester, const ReceivePage(), brightness: b);
      await tester.enterText(find.byType(TextField).first, '250000');
      await tester.enterText(find.byType(TextField).at(1), 'Minh chia tien an');
      await tester.pump();
      await _tapText(tester, 'Tạo mã QR');
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);
      final card = find.textContaining('NGUYEN MINH').first;
      await tester.scrollUntilVisible(
        card,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
      await _settle(tester);
      await _capture(tester, 'receive-$mode');
    });

    testWidgets('accounts & sync ($mode)', (tester) async {
      await _pump(
        tester,
        const Scaffold(
          body: MomaPage(
            title: 'Tài khoản & Đồng bộ',
            showBack: true,
            child: AccountsPage(),
          ),
        ),
        brightness: b,
      );
      await _capture(tester, 'accounts-$mode');
    });

    testWidgets('goals ($mode)', (tester) async {
      await _pump(
        tester,
        const Scaffold(
          body: MomaPage(
            title: 'Kế hoạch',
            showBack: true,
            child: PlanningPage(initialTab: 1),
          ),
        ),
        brightness: b,
      );
      await _capture(tester, 'goals-$mode');
    });
  }
}
