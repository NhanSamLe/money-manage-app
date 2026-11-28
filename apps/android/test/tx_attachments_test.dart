import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/transactions/tx_attachments.dart';

import 'support/fake_api.dart';

// 1x1 transparent PNG.
const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52, //
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42, 0x60, 0x82,
];

class _AttachApi extends FakeApi {
  _AttachApi(List<Map<String, dynamic>> items)
    : super(
        data: {
          ...FakeApi.defaultData(),
          '/transactions/tx1/attachments': items,
        },
      );

  final deleted = <String>[];

  @override
  Future<List<int>> getBytes(String path) async => _png;

  @override
  Future<dynamic> delete(String path) async {
    deleted.add(path);
    final list = data['/transactions/tx1/attachments'] as List;
    list.removeWhere((e) => path.endsWith('/${(e as Map)['id']}'));
    return {'deleted': true};
  }
}

Map<String, dynamic> _att(String id) => {
  'id': id,
  'tx_id': 'tx1',
  'content_type': 'image/png',
  'size_bytes': 120000,
  'created_at': '2026-11-28T01:00:00Z',
};

Widget _host(ApiClient api, {bool canAdd = true}) => ProviderScope(
  overrides: [apiProvider.overrideWithValue(api)],
  child: MaterialApp(
    theme: buildMomaTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: TxAttachmentsSection(txId: 'tx1', canAdd: canAdd),
      ),
    ),
  ),
);

void main() {
  test('sniffImageType recognises the three accepted formats only', () {
    expect(sniffImageType(_png), 'image/png');
    expect(sniffImageType([0xFF, 0xD8, 0xFF, 0xE0]), 'image/jpeg');
    expect(
      sniffImageType([
        0x52,
        0x49,
        0x46,
        0x46,
        0,
        0,
        0,
        0,
        0x57,
        0x45,
        0x42,
        0x50,
      ]),
      'image/webp',
    );
    expect(sniffImageType('<svg/>'.codeUnits), isNull);
    expect(sniffImageType(const []), isNull);
  });

  test('TxAttachment parses the API row', () {
    final a = TxAttachment.fromJson(_att('x1'));
    expect(a.id, 'x1');
    expect(a.extension, 'png');
    expect(a.sizeBytes, 120000);
  });

  testWidgets('empty: shows the add tile and the privacy hint', (tester) async {
    await tester.pumpWidget(_host(_AttachApi([])));
    await tester.pumpAndSettle();
    expect(find.text('Ảnh chứng từ'), findsOneWidget);
    expect(find.text('Thêm ảnh'), findsOneWidget);
    expect(find.textContaining('chỉ bạn xem được'), findsOneWidget);
  });

  testWidgets(
    'lists pictures with a count and hides "add" on a cancelled transaction',
    (tester) async {
      await tester.pumpWidget(
        _host(_AttachApi([_att('a1'), _att('a2')]), canAdd: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ảnh chứng từ (2)'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('Thêm ảnh'), findsNothing);
    },
  );

  testWidgets('add tile disappears at the 10-picture limit', (tester) async {
    await tester.pumpWidget(
      _host(
        _AttachApi([for (var i = 0; i < kMaxAttachments; i++) _att('p$i')]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ảnh chứng từ ($kMaxAttachments)'), findsOneWidget);
    expect(find.text('Thêm ảnh'), findsNothing);
  });

  testWidgets(
    'viewer: delete asks first, removes the picture and refreshes the list',
    (tester) async {
      final api = _AttachApi([_att('a1'), _att('a2')]);
      await tester.pumpWidget(_host(api));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.text('Ảnh 1/2'), findsOneWidget);

      await tester.tap(find.byTooltip('Xóa ảnh'));
      await tester.pumpAndSettle();
      expect(find.text('Xóa ảnh này?'), findsOneWidget);
      await tester.tap(find.text('Giữ lại'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty);

      await tester.tap(find.byTooltip('Xóa ảnh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await tester.pumpAndSettle();
      expect(api.deleted, ['/attachments/a1']);
      expect(
        find.text('Ảnh chứng từ'),
        findsOneWidget,
      ); // single picture left: viewer shows plain title

      await tester.tap(find.byIcon(Symbols.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Ảnh chứng từ (1)'), findsOneWidget);
    },
  );
}
