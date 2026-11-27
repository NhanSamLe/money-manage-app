import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/account_presets.dart';
import 'package:moma/core/brands/brand_registry.dart';
import 'package:moma/core/brands/person_avatar.dart';

void main() {
  group('brandFor', () {
    test('matches names with and without diacritics, case and spacing', () {
      expect(brandFor(institution: 'Vietcombank')?.code, 'VCB');
      expect(brandFor(institution: 'vcb')?.code, 'VCB');
      expect(
        brandFor(institution: 'Ngân hàng TMCP Ngoại Thương Việt Nam')?.code,
        'VCB',
      );
      expect(
        brandFor(institution: 'ngan hang tmcp ngoai thuong viet nam')?.code,
        'VCB',
      );
      expect(brandFor(institution: 'MB Bank')?.code, 'MB');
      expect(brandFor(institution: 'mbbank')?.code, 'MB');
      expect(brandFor(institution: 'TP Bank')?.code, 'TPB');
      expect(brandFor(institution: 'TCB')?.code, 'TCB');
      expect(brandFor(institution: 'Ví MoMo')?.code, 'MOMO');
      expect(brandFor(institution: 'Zalo Pay')?.code, 'ZALOPAY');
      expect(brandFor(institution: 'ViettelPay')?.code, 'VTLMONEY');
      expect(brandFor(institution: 'LienVietPostBank')?.code, 'LPB');
      expect(brandFor(institution: 'Bản Việt')?.code, 'VCCB');
    });

    test('contained aliases: longest wins', () {
      expect(brandFor(institution: 'Vietcombank - lương')?.code, 'VCB');
      expect(brandFor(institution: 'PVcomBank Pay')?.code, 'PVDB');
      expect(brandFor(institution: 'Ubank by VPBank')?.code, 'UBANK');
    });

    test('BIN, code and Android package', () {
      expect(brandFor(bin: '970436')?.code, 'VCB');
      expect(brandFor(bin: '970422')?.code, 'MB');
      expect(brandFor(code: 'ICB')?.shortName, 'VietinBank');
      expect(brandFor(code: 'momo')?.code, 'MOMO');
      expect(brandFor(package: 'com.VCB')?.code, 'VCB');
      expect(brandFor(package: 'com.mservice.momotransfer')?.code, 'MOMO');
      expect(brandFor(package: 'vn.com.vng.zalopay')?.code, 'ZALOPAY');
      expect(brandFor(package: 'com.beeasy.toppay')?.code, 'SHOPEEPAY');
      expect(brandFor(package: 'vn.com.lpb.lienviet24h')?.code, 'LPB');
      // Package wins over a conflicting name.
      expect(brandFor(institution: 'BIDV', package: 'com.VCB')?.code, 'VCB');
    });

    test('unknown or generic text does not match', () {
      expect(brandFor(institution: 'Ngân hàng ABCXYZ'), isNull);
      expect(brandFor(institution: 'Tiền mặt'), isNull);
      expect(brandFor(institution: 'Tiết kiệm'), isNull);
      expect(brandFor(institution: 'Thẻ tín dụng'), isNull);
      expect(brandFor(institution: ''), isNull);
      expect(brandFor(bin: '000000'), isNull);
      expect(brandFor(package: 'com.example.app'), isNull);
    });

    test('every preset brand and asset exists', () {
      for (final p in accountPresets.where((p) => p.brand != null)) {
        expect(brandFor(code: p.brand), isNotNull, reason: p.name);
        expect(
          brandFor(institution: p.institution)?.code,
          p.brand,
          reason: p.name,
        );
      }
      for (final b in kBrands) {
        expect(File(b.asset).existsSync(), isTrue, reason: b.asset);
      }
    });
  });

  group('AccountBadge', () {
    Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: w)),
      ),
    );

    testWidgets('shows the logo image for Vietcombank', (t) async {
      await pump(
        t,
        const AccountBadge(institution: 'Vietcombank', kind: 'BANK'),
      );
      expect(find.byType(BrandLogo), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('uses bin / package when the name is unknown', (t) async {
      await pump(
        t,
        const AccountBadge(
          institution: 'TK lương',
          kind: 'BANK',
          bin: '970407',
        ),
      );
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('unknown bank falls back to a bank icon, no letters', (
      t,
    ) async {
      await pump(
        t,
        const AccountBadge(institution: 'Ngân hàng ABC', kind: 'BANK'),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('cash keeps its icon', (t) async {
      await pump(t, const AccountBadge(institution: 'Tiền mặt', kind: 'CASH'));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets('PersonAvatar renders an icon with a stable colour', (t) async {
      await pump(t, const PersonAvatar(name: 'Anh Tuấn'));
      expect(find.byType(Icon), findsOneWidget);
      expect(personColor('Anh Tuấn'), personColor('anh tuấn'));
    });
  });
}
