import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/ui/motion.dart';
import 'package:moma/features/profile/avatar.dart';
import 'package:moma/features/profile/owner_account.dart';
import 'package:moma/features/profile/profile_page.dart';

import 'support/fake_api.dart';

class MemoryAvatarStore extends AvatarStore {
  Uint8List? bytes;
  @override
  Future<Uint8List?> load() async => bytes;
  @override
  Future<void> save(Uint8List b) async => bytes = b;
  @override
  Future<void> clear() async => bytes = null;
}

class FakeAccount implements OwnerAccount {
  final calls = <({String current, String next})>[];
  ApiException? fail;
  bool signedOut = false;

  @override
  String? get email => 'owner@moma.vn';
  @override
  String? get createdAt => '2026-03-05T02:00:00Z';

  @override
  Future<void> changePassword({
    required String current,
    required String next,
  }) async {
    if (fail != null) throw fail!;
    calls.add((current: current, next: next));
  }

  @override
  Future<void> signOut() async => signedOut = true;
}

FakeApi profileApi({String name = 'Lê Đào Nhân Sâm'}) => FakeApi(
  data: {
    ...FakeApi.defaultData(),
    '/profile': {'display_name': name, 'version': 3},
  },
);

Future<void> pumpProfile(
  WidgetTester tester,
  FakeApi api, {
  FakeAccount? account,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(api),
        ownerAccountProvider.overrideWithValue(account ?? FakeAccount()),
        avatarStoreProvider.overrideWithValue(MemoryAvatarStore()),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const ProfilePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder nameField() => find.byType(TextFormField).first;

void main() {
  setUpAll(() => Motion.continuous = false);

  testWidgets(
    'shows a person silhouette, not initials, when there is no photo',
    (tester) async {
      await pumpProfile(tester, profileApi());
      final placeholder = find.byKey(const ValueKey('avatar-placeholder'));
      expect(placeholder, findsOneWidget);
      expect(
        find.descendant(
          of: placeholder,
          matching: find.byIcon(Symbols.person_rounded),
        ),
        findsOneWidget,
      );
      expect(find.text('NS'), findsNothing);
      expect(find.text('L'), findsNothing);
      expect(find.text('owner@moma.vn'), findsOneWidget);
      expect(find.text('Thành viên từ 05/03/2026'), findsOneWidget);
    },
  );

  testWidgets('display name is validated only on save', (tester) async {
    final api = profileApi();
    await pumpProfile(tester, api);
    expect(find.text('Lê Đào Nhân Sâm'), findsWidgets);

    await tester.enterText(nameField(), '');
    await tester.pump();
    expect(find.text('Vui lòng nhập tên.'), findsNothing);

    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Vui lòng nhập tên.'), findsOneWidget);

    await tester.enterText(nameField(), 'A');
    await tester.pumpAndSettle();
    expect(find.text('Tên cần từ 2 ký tự.'), findsOneWidget);

    await tester.enterText(nameField(), '123');
    await tester.pumpAndSettle();
    expect(find.text('Tên cần có chữ cái.'), findsOneWidget);
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(api.commands, isEmpty);
  });

  testWidgets('save sends PROFILE_UPDATE with expected_version', (
    tester,
  ) async {
    final api = profileApi();
    await pumpProfile(tester, api);
    await tester.enterText(nameField(), '  Nhân Sâm  ');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(api.commands, hasLength(1));
    expect(api.commands.single.type, 'PROFILE_UPDATE');
    expect(api.commands.single.payload, {
      'expected_version': 3,
      'display_name': 'Nhân Sâm',
    });
    expect(find.text('Đã cập nhật hồ sơ'), findsOneWidget);
  });

  testWidgets('server error on save opens a modal', (tester) async {
    final api = profileApi()
      ..failNext = ApiException('VERSION_CONFLICT', 'Hồ sơ đã thay đổi.');
    await pumpProfile(tester, api);
    await tester.enterText(nameField(), 'Nhân Sâm');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Hồ sơ đã thay đổi.'), findsOneWidget);
    expect(find.text('Đã hiểu'), findsOneWidget);
  });

  testWidgets('password change validates and calls the account', (
    tester,
  ) async {
    final account = FakeAccount();
    await pumpProfile(tester, profileApi(), account: account);
    await tester.tap(find.text('Đổi mật khẩu'));
    await tester.pumpAndSettle();

    final fields = find.descendant(
      of: find.byType(ChangePasswordSheet),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'old-pass1');
    await tester.enterText(fields.at(1), 'newpass12');
    await tester.enterText(fields.at(2), 'newpass13');
    await tester.tap(find.widgetWithText(FilledButton, 'Đổi mật khẩu'));
    await tester.pumpAndSettle();
    expect(find.text('Mật khẩu nhập lại không khớp.'), findsOneWidget);
    expect(account.calls, isEmpty);

    await tester.enterText(fields.at(2), 'newpass12');
    await tester.tap(find.widgetWithText(FilledButton, 'Đổi mật khẩu'));
    await tester.pumpAndSettle();
    expect(account.calls.single, (current: 'old-pass1', next: 'newpass12'));
    expect(find.text('Đã đổi mật khẩu'), findsOneWidget);
  });

  testWidgets('wrong current password is shown in a modal', (tester) async {
    final account = FakeAccount()
      ..fail = ApiException('BAD_CREDENTIALS', 'Mật khẩu hiện tại không đúng.');
    await pumpProfile(tester, profileApi(), account: account);
    await tester.tap(find.text('Đổi mật khẩu'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(ChangePasswordSheet),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'wrong-pass1');
    await tester.enterText(fields.at(1), 'newpass12');
    await tester.enterText(fields.at(2), 'newpass12');
    await tester.tap(find.widgetWithText(FilledButton, 'Đổi mật khẩu'));
    await tester.pumpAndSettle();
    expect(find.text('Mật khẩu hiện tại không đúng.'), findsOneWidget);
  });

  testWidgets('sign-out asks for confirmation first', (tester) async {
    final account = FakeAccount();
    await pumpProfile(tester, profileApi(), account: account);
    await tester.scrollUntilVisible(
      find.text('Đăng xuất'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();
    expect(account.signedOut, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await tester.pumpAndSettle();
    expect(account.signedOut, isTrue);
  });
}
