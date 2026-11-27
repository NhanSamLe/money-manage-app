import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/app/theme/palette.dart';
import 'package:moma/app/theme/theme_mode.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/core/ui/motion.dart';
import 'package:moma/core/storage/local_store.dart';
import 'package:moma/features/auth/welcome_page.dart';
import 'package:moma/features/launch/intro_page.dart';
import 'package:moma/features/launch/splash_page.dart';

class MemStore extends LocalStore {
  MemStore({this.seen = false});
  bool seen;
  String mode = 'system';
  @override
  Future<bool> introSeen() async => seen;
  @override
  Future<void> setIntroSeen() async => seen = true;
  @override
  Future<String> themeMode() async => mode;
  @override
  Future<void> setThemeMode(String v) async => mode = v;
}

Widget launchApp(MemStore store) {
  final router = GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, _) => const SplashPage(minDuration: Duration.zero),
      ),
      GoRoute(path: '/intro', builder: (_, _) => const IntroPage()),
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomePage()),
      GoRoute(path: '/login', builder: (_, _) => const Text('login-page')),
      GoRoute(
        path: '/register',
        builder: (_, _) => const Text('register-page'),
      ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    overrides: [storeProvider.overrideWithValue(store)],
    child: MaterialApp.router(
      theme: buildMomaTheme(),
      darkTheme: buildMomaTheme(Brightness.dark),
      routerConfig: router,
    ),
  );
}

void main() {
  setUpAll(() => Motion.continuous = false);
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'first launch: splash -> intro slides -> welcome, intro is remembered',
    (tester) async {
      tall(tester);
      final store = MemStore();
      await tester.pumpWidget(launchApp(store));
      await tester.pump(); // splash built
      expect(find.text('Hiểu dòng tiền.'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        find.text('Quản lý tài chính thông minh, đơn giản'),
        findsOneWidget,
      );
      await tester.tap(find.text('Tiếp tục'));
      await tester.pumpAndSettle();
      expect(find.text('Ghi nhanh bằng câu nói tự nhiên'), findsOneWidget);
      await tester.tap(find.text('Tiếp tục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bắt đầu'));
      await tester.pumpAndSettle();
      expect(find.text('Tôi đã có tài khoản'), findsOneWidget);
      expect(store.seen, isTrue);
    },
  );

  testWidgets('later launches skip the intro and go to welcome', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(launchApp(MemStore(seen: true)));
    await tester.pumpAndSettle();
    expect(find.text('Tôi đã có tài khoản'), findsOneWidget);
    expect(find.text('Quản lý tài chính thông minh, đơn giản'), findsNothing);
  });

  testWidgets('skip on the intro marks it as seen', (tester) async {
    tall(tester);
    final store = MemStore();
    await tester.pumpWidget(launchApp(store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bỏ qua'));
    await tester.pumpAndSettle();
    expect(store.seen, isTrue);
    expect(find.text('Tôi đã có tài khoản'), findsOneWidget);
  });

  group('light and dark themes', () {
    testWidgets('provide different surface tokens and brand colours stay', (
      tester,
    ) async {
      late Pal light, dark;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMomaTheme(),
          home: Builder(
            builder: (c) {
              light = c.pal;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMomaTheme(Brightness.dark),
          home: Builder(
            builder: (c) {
              dark = c.pal;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle(); // ThemeData animates between themes
      expect(light.surface, isNot(dark.surface));
      expect(light.bg.computeLuminance(), greaterThan(0.8));
      expect(dark.bg.computeLuminance(), lessThan(0.05));
      // body text must stay readable on its own surface in both themes
      double contrast(Color a, Color b) {
        final l1 = a.computeLuminance() + 0.05,
            l2 = b.computeLuminance() + 0.05;
        return l1 > l2 ? l1 / l2 : l2 / l1;
      }

      expect(contrast(light.ink, light.surface), greaterThan(7));
      expect(contrast(dark.ink, dark.surface), greaterThan(7));
      expect(contrast(light.muted, light.surface), greaterThan(4.5));
      expect(contrast(dark.muted, dark.surface), greaterThan(4.5));
    });

    test('theme mode round-trips through its storage string', () {
      for (final m in ThemeMode.values) {
        expect(themeModeFromString(themeModeToString(m)), m);
      }
      expect(themeModeFromString('garbage'), ThemeMode.system);
    });

    testWidgets('welcome screen renders in dark mode without layout errors', (
      tester,
    ) async {
      tall(tester);
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const WelcomePage())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: buildMomaTheme(),
            darkTheme: buildMomaTheme(Brightness.dark),
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Tôi đã có tài khoản'), findsOneWidget);
    });
  });
}
