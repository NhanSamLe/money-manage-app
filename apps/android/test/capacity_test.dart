import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/settings/capacity_page.dart';

import 'support/fake_api.dart';

class _CapApi extends FakeApi {
  _CapApi(Map<String, dynamic> report)
    : super(data: {...FakeApi.defaultData(), '/system/capacity': report});
  final posts = <String>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    posts.add(path);
    return {
      'passes': 1,
      'totals': {'pf_command': 120, 'pf_change': 30},
      'month_stats': 0,
      'more': false,
    };
  }
}

Map<String, dynamic> _report({
  double pct = 8.4,
  String label = 'Đủ dùng ~12 năm nữa',
}) => {
  'db_bytes': (pct / 100 * 500 * 1024 * 1024).round(),
  'db_limit_bytes': 500 * 1024 * 1024,
  'r2_bytes': 25 * 1024 * 1024,
  'r2_limit_bytes': 10 * 1024 * 1024 * 1024,
  'attachments': 97,
  'tx_count': 2140,
  'top': [
    {'table': 'pf_entry', 'bytes': 9000000, 'rows': 4300},
  ],
  'history': [],
  'projection': {
    'growth_per_month': 1200000,
    'months_to_80': 150.0,
    'months_to_full': 190.0,
    'label': label,
    'pct': pct,
  },
  'ai': {
    'this_month_micro_usd': 182000,
    'this_month_calls': 412,
    'by_feature': [
      {'feature': 'agent', 'calls': 160, 'micro_usd': 120000},
      {'feature': 'classify', 'calls': 230, 'micro_usd': 41000},
      {'feature': 'bill', 'calls': 22, 'micro_usd': 21000},
    ],
    'months': [
      {'period': '2026-09-01', 'micro_usd': 150000},
      {'period': '2026-10-01', 'micro_usd': 210000},
    ],
  },
  'last_run_at': '2026-11-29T20:31:00Z',
  'last_result': {},
  'runs': 12,
};

Widget _host(FakeApi api) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(theme: buildMomaTheme(), home: const CapacityPage()),
);

void main() {
  test('cost label: micro-USD to VND (reference rate) and USD', () {
    expect(aiCostLabel(182000), '≈ 4.732đ (\$0.18)');
    expect(aiCostLabel(5000), '≈ 130đ (\$0.005)');
    expect(featureLabel('classify'), 'Tự phân loại');
    expect(bytesLabel(42 * 1024 * 1024), '42.0 MB');
  });

  testWidgets(
    'shows database use, projection, pictures, AI cost per feature and the cleanup button',
    (tester) async {
      final api = _CapApi(_report());
      await tester.pumpWidget(_host(api));
      await tester.pumpAndSettle();
      expect(find.text('Dữ liệu (miễn phí 500 MB)'), findsOneWidget);
      expect(find.byKey(const Key('capacity-label')), findsOneWidget);
      expect(find.text('Đủ dùng ~12 năm nữa'), findsOneWidget);
      expect(find.textContaining('97 ảnh'), findsOneWidget);
      expect(find.byKey(const Key('ai-cost')), findsOneWidget);
      expect(find.text('Trợ lý (chat)'), findsOneWidget);
      expect(find.text('Tự phân loại'), findsOneWidget);
      expect(find.textContaining('trung bình'), findsOneWidget);
      // well under 60%: no "khi gần đầy" card
      expect(find.text('Khi gần đầy'), findsNothing);

      // OutlinedButton.icon is a private subclass: find by its label, build it (lazy list), then bring it fully in view.
      final button = find.text('Dọn dẹp ngay');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(api.posts, ['/system/cleanup']);
      expect(find.text('Đã dọn 150 dòng dữ liệu phụ.'), findsOneWidget);
    },
  );

  testWidgets(
    'near the limit it explains the free options only (no paid upgrade)',
    (tester) async {
      await tester.pumpWidget(
        _host(
          _CapApi(
            _report(
              pct: 82,
              label: 'Đã dùng trên 80% dung lượng: cần dọn dẹp hoặc lưu trữ năm cũ',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Khi gần đầy'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('miễn phí'), findsWidgets);
      expect(find.textContaining('Pro'), findsNothing);
      expect(find.textContaining('trả phí'), findsNothing);
    },
  );
}
