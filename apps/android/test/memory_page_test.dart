import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/models.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/assistant/memory_page.dart';
import 'package:moma/features/transactions/tx_detail_page.dart'
    show txSourceLabel;

import 'support/fake_api.dart';

/// FakeApi with an in-memory /ai/memory store (GET list, POST add, DELETE remove).
class _MemoryApi extends FakeApi {
  _MemoryApi(this.rows);
  final List<Map<String, dynamic>> rows;
  final posts = <Map<String, dynamic>>[];
  final deletes = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/ai/memory') return [...rows];
    return super.get(path, query: query);
  }

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    final b = Map<String, dynamic>.from(body as Map);
    posts.add(b);
    final row = {
      'id': 'm${rows.length + 10}',
      'kind': b['kind'],
      'key': b['key'] ?? b['value'],
      'weight': 0.9,
      'source': 'user',
      'text': b['kind'] == 'ALIAS'
          ? '"${b['key']}" nghĩa là "${b['value']}"'
          : b['value'],
    };
    rows.add(row);
    return row;
  }

  @override
  Future<dynamic> delete(String path) async {
    deletes.add(path);
    rows.removeWhere((r) => path.endsWith('/${r['id']}'));
    return {'deleted': true};
  }
}

Map<String, dynamic> _m(
  String id,
  String kind,
  String text, {
  double weight = 0.8,
  String source = 'pattern',
}) => {
  'id': id,
  'kind': kind,
  'key': text.toLowerCase(),
  'weight': weight,
  'source': source,
  'text': text,
};

Future<_MemoryApi> _open(
  WidgetTester tester,
  List<Map<String, dynamic>> rows,
) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final api = _MemoryApi(rows);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openAssistantMemory(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('empty state invites the owner to add a memory', (tester) async {
    await _open(tester, []);
    expect(find.text('Trợ lý đã học được gì'), findsOneWidget);
    expect(find.text('Trợ lý chưa ghi nhớ điều gì'), findsOneWidget);
    expect(find.text('+ Thêm ghi nhớ'), findsOneWidget);
  });

  testWidgets('groups entries by kind with labels and confidence bars', (
    tester,
  ) async {
    await _open(tester, [
      _m('1', 'ALIAS', '"nc đậu" nghĩa là "nước đậu"', weight: 0.62),
      _m(
        '2',
        'CATEGORY_RULE',
        '"nước đậu" thuộc danh mục Ăn uống',
        source: 'correction',
      ),
      _m(
        '3',
        'HABIT',
        'Ăn sáng thường khoảng 35.000 ₫',
        weight: 0.5,
        source: 'reflection',
      ),
      _m('4', 'NOTE', 'Lương về ngày 5', weight: 0.9, source: 'user'),
    ]);
    expect(find.text('Từ viết tắt'), findsOneWidget);
    expect(find.text('Cách xếp danh mục'), findsOneWidget);
    expect(find.text('Thói quen chi tiêu'), findsOneWidget);
    expect(find.text('Ghi chú của bạn'), findsOneWidget);
    expect(find.text('Người quen'), findsNothing);
    expect(find.text('"nc đậu" nghĩa là "nước đậu"'), findsOneWidget);
    expect(find.text('62% · Học từ cách bạn nói'), findsOneWidget);
    expect(find.text('80% · Học từ lần bạn sửa'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(4));
  });

  testWidgets('deleting asks for confirmation first', (tester) async {
    final api = await _open(tester, [
      _m('1', 'NOTE', 'Ghi chú sai', source: 'user'),
      _m('2', 'NOTE', 'Ghi chú đúng', source: 'user'),
    ]);
    await tester.tap(find.byTooltip('Xóa ghi nhớ').first);
    await tester.pumpAndSettle();
    expect(find.text('Xóa ghi nhớ này?'), findsOneWidget);
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(api.deletes, isEmpty);

    await tester.tap(find.byTooltip('Xóa ghi nhớ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xóa'));
    await tester.pumpAndSettle();
    expect(api.deletes, ['/ai/memory/1']);
    expect(find.text('Ghi chú sai'), findsNothing);
    expect(find.text('Ghi chú đúng'), findsOneWidget);
  });

  testWidgets('add sheet validates under the field and saves an alias', (
    tester,
  ) async {
    final api = await _open(tester, []);
    await tester.tap(find.text('+ Thêm ghi nhớ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viết tắt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lưu ghi nhớ'));
    await tester.pumpAndSettle();
    expect(find.text('Vui lòng nhập từ viết tắt.'), findsOneWidget);
    expect(find.text('Vui lòng nhập nghĩa.'), findsOneWidget);
    expect(api.posts, isEmpty);

    await tester.enterText(find.byType(TextFormField).at(0), 'nc đậu');
    await tester.enterText(find.byType(TextFormField).at(1), 'nước đậu');
    await tester.tap(find.text('Lưu ghi nhớ'));
    await tester.pumpAndSettle();
    expect(api.posts, [
      {'kind': 'ALIAS', 'key': 'nc đậu', 'value': 'nước đậu'},
    ]);
    expect(find.text('"nc đậu" nghĩa là "nước đậu"'), findsOneWidget);
  });

  test('transaction source labels', () {
    MomaTx tx(String? source) => MomaTx.fromJson({
      'id': 't',
      'kind': 'EXPENSE',
      'status': 'POSTED',
      'effective_at': '2026-11-27T05:00:00Z',
      'amount': '1000',
      'fee': '0',
      'version': 1,
      'source': ?source,
    });
    expect(txSourceLabel(tx(null)), 'Thủ công');
    expect(tx(null).source, 'MANUAL');
    expect(txSourceLabel(tx('BANK')), 'Ngân hàng tự động');
    expect(txSourceLabel(tx('AI')), 'Trợ lý tài chính');
    expect(txSourceLabel(tx('NOTIFICATION')), 'Thông báo ngân hàng trên máy');
    expect(txSourceLabel(tx('IMPORT')), 'Nhập từ file');
    expect(txSourceLabel(tx('RECURRING')), 'Định kỳ');
    expect(txSourceLabel(tx('SYSTEM')), 'Hệ thống');
  });
}
