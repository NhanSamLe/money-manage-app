import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/features/lock/lock_controller.dart';
import 'package:moma/features/lock/lock_screen.dart';
import 'package:moma/features/lock/lock_services.dart';
import 'package:moma/features/lock/lock_settings_page.dart';
import 'package:moma/features/lock/pin_hasher.dart';

class MemLockStorage implements LockStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class FakeBio implements BiometricAuth {
  FakeBio({this.available = true, this.result = false});
  bool available;
  bool result;
  int prompts = 0;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return result;
  }
}

class Clock {
  DateTime now = DateTime(2026, 11, 28, 9);
  DateTime call() => now;
}

const fastHasher = PinHasher(iterations: 10, offThread: false);

Future<MemLockStorage> storeWithPin(
  String pin, {
  bool bio = false,
  LockDelay delay = LockDelay.m30,
}) async {
  final s = MemLockStorage();
  s.data[kLockConfigKey] = LockConfig(
    pinHash: await fastHasher.hash(pin),
    biometric: bio,
    delay: delay,
  ).encode();
  return s;
}

List<Override> overrides({
  required LockStorage store,
  required BiometricAuth bio,
  required Clock clock,
  bool signedIn = true,
  List<String>? signOuts,
}) => [
  lockStorageProvider.overrideWithValue(store),
  biometricProvider.overrideWithValue(bio),
  pinHasherProvider.overrideWithValue(fastHasher),
  lockClockProvider.overrideWithValue(clock.call),
  lockSignedInProvider.overrideWithValue(() => signedIn),
  lockSignOutProvider.overrideWithValue(() async => signOuts?.add('out')),
];

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    test('matches RFC 7914 / reference vectors', () {
      expect(
        hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 4096)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
      expect(
        hex(
          pbkdf2Sha256(
            utf8.encode('123456'),
            List<int>.generate(16, (i) => i),
            1000,
          ),
        ),
        '6e3849111be8d3070634220666e93c55dbfd75e923f34d35716805464c0a7eaf',
      );
    });
  });

  group('PinHasher', () {
    const h = PinHasher(iterations: 50, offThread: false);
    test('verifies the right PIN only, never stores it in clear', () async {
      final enc = await h.hash('482913');
      expect(enc, startsWith(r'pbkdf2-sha256$50$'));
      expect(enc, isNot(contains('482913')));
      expect(await h.verify('482913', enc), isTrue);
      expect(await h.verify('482914', enc), isFalse);
      expect(await h.verify('', enc), isFalse);
    });
    test('random salt: same PIN hashes differently', () async {
      expect(await h.hash('111111'), isNot(await h.hash('111111')));
    });
    test('uses the iteration count stored with the hash', () async {
      final enc = await const PinHasher(
        iterations: 7,
        offThread: false,
      ).hash('123456');
      expect(await h.verify('123456', enc), isTrue);
    });
    test('rejects malformed hashes', () async {
      expect(await h.verify('123456', 'plain'), isFalse);
      expect(await h.verify('123456', r'pbkdf2-sha256$x$a$b'), isFalse);
      expect(await h.verify('123456', r'pbkdf2-sha256$5$@@$@@'), isFalse);
    });
  });

  group('AttemptPolicy', () {
    test('fixed 10 s wait after every 5 wrong tries', () {
      for (var n = 1; n <= 4; n++) {
        expect(AttemptPolicy.cooldownAfter(n), isNull);
      }
      expect(AttemptPolicy.cooldownAfter(5), const Duration(seconds: 10));
      expect(AttemptPolicy.cooldownAfter(6), isNull);
      expect(AttemptPolicy.cooldownAfter(10), const Duration(seconds: 10));
      expect(AttemptPolicy.remaining(0), 5);
      expect(AttemptPolicy.remaining(3), 2);
      expect(AttemptPolicy.remaining(4), 1);
    });
  });

  group('LockController', () {
    late Clock clock;
    setUp(() => clock = Clock());

    Future<ProviderContainer> make(
      LockStorage store, {
      bool signedIn = true,
      FakeBio? bio,
      List<String>? signOuts,
    }) async {
      final c = ProviderContainer(
        overrides: overrides(
          store: store,
          bio: bio ?? FakeBio(),
          clock: clock,
          signedIn: signedIn,
          signOuts: signOuts,
        ),
      );
      addTearDown(c.dispose);
      await c.read(lockControllerProvider.notifier).ready;
      return c;
    }

    test('cold start locks only when enabled and signed in', () async {
      expect(
        (await make(MemLockStorage())).read(lockControllerProvider).locked,
        isFalse,
      );
      final store = await storeWithPin('123456');
      expect((await make(store)).read(lockControllerProvider).locked, isTrue);
      expect(
        (await make(
          store,
          signedIn: false,
        )).read(lockControllerProvider).locked,
        isFalse,
      );
    });

    test('5 wrong PINs -> 10 s wait, then 5 new tries', () async {
      final store = await storeWithPin('123456');
      final c = await make(store);
      final ctl = c.read(lockControllerProvider.notifier);
      for (var i = 1; i <= 4; i++) {
        final r = await ctl.unlockWithPin('000000');
        expect(r.ok, isFalse);
        expect(r.remaining, 5 - i);
      }
      final fifth = await ctl.unlockWithPin('000000');
      expect(fifth.waitUntil, clock.now.add(const Duration(seconds: 10)));
      // Even the right PIN is refused during the wait, and the wait does not grow.
      final during = await ctl.unlockWithPin('123456');
      expect(during.ok, isFalse);
      expect(during.waitUntil, fifth.waitUntil);
      expect(c.read(lockControllerProvider).locked, isTrue);
      // Persisted, so restarting the app does not skip the wait.
      expect(store.data[kLockAttemptsKey], isNotNull);

      clock.now = clock.now.add(const Duration(seconds: 10));
      final again = await ctl.unlockWithPin('000000');
      expect(again.waitUntil, isNull);
      expect(again.remaining, 4);
      for (var i = 0; i < 3; i++) {
        await ctl.unlockWithPin('000000');
      }
      final tenth = await ctl.unlockWithPin('000000');
      expect(tenth.waitUntil, clock.now.add(const Duration(seconds: 10)));

      clock.now = clock.now.add(const Duration(seconds: 11));
      expect((await ctl.unlockWithPin('123456')).ok, isTrue);
      expect(c.read(lockControllerProvider).locked, isFalse);
      expect(c.read(lockControllerProvider).failures, 0);
      expect(store.data[kLockAttemptsKey], isNull);
    });

    test('short app switch never locks; longer than the delay does', () async {
      final c = await make(await storeWithPin('123456'));
      final ctl = c.read(lockControllerProvider.notifier);
      await ctl.unlockWithPin('123456');

      ctl.onLifecycle(AppLifecycleState.inactive);
      ctl.onLifecycle(AppLifecycleState.hidden);
      ctl.onLifecycle(AppLifecycleState.paused);
      clock.now = clock.now.add(const Duration(minutes: 29));
      ctl.onLifecycle(AppLifecycleState.resumed);
      expect(c.read(lockControllerProvider).locked, isFalse);

      ctl.onLifecycle(AppLifecycleState.paused);
      clock.now = clock.now.add(const Duration(minutes: 30));
      ctl.onLifecycle(AppLifecycleState.resumed);
      expect(c.read(lockControllerProvider).locked, isTrue);
    });

    test('enable stores only a hash; change / disable / settings', () async {
      final store = MemLockStorage();
      final c = await make(store);
      final ctl = c.read(lockControllerProvider.notifier);
      await ctl.enable('246810');
      expect(store.data[kLockConfigKey], isNot(contains('246810')));
      expect(c.read(lockControllerProvider).enabled, isTrue);
      expect(c.read(lockControllerProvider).locked, isFalse);
      expect(c.read(lockControllerProvider).config.delay, LockDelay.m30);

      await ctl.setDelay(LockDelay.h2);
      await ctl.changePin('135790');
      expect((await ctl.checkPin('246810')).ok, isFalse);
      expect((await ctl.checkPin('135790')).ok, isTrue);
      expect(LockConfig.decode(store.data[kLockConfigKey]).delay, LockDelay.h2);

      await ctl.disable();
      expect(c.read(lockControllerProvider).enabled, isFalse);
    });

    test('quên mã PIN clears the lock and signs out', () async {
      final outs = <String>[];
      final store = await storeWithPin('123456');
      final c = await make(store, signOuts: outs);
      await c.read(lockControllerProvider.notifier).forgotPin();
      expect(outs, ['out']);
      expect(c.read(lockControllerProvider).enabled, isFalse);
      expect(c.read(lockControllerProvider).locked, isFalse);
      expect(LockConfig.decode(store.data[kLockConfigKey]).enabled, isFalse);
    });

    test('recentlyActive for the widget sheet follows the delay', () async {
      final store = await storeWithPin('123456');
      final c = await make(store);
      final ctl = c.read(lockControllerProvider.notifier);
      expect(await ctl.recentlyActive(), isFalse);
      await ctl.unlockWithPin('123456');
      await Future<void>.delayed(Duration.zero);
      expect(await ctl.recentlyActive(), isTrue);
      clock.now = clock.now.add(const Duration(minutes: 31));
      expect(await ctl.recentlyActive(), isFalse);
    });
  });

  group('UI', () {
    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> enter(WidgetTester tester, String pin) async {
      for (final d in pin.split('')) {
        await tester.tap(find.byKey(ValueKey('pin-key-$d')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Widget gatedApp({
      required LockStorage store,
      required FakeBio bio,
      required Clock clock,
      String initial = '/home',
    }) {
      final router = GoRouter(
        initialLocation: initial,
        routes: [
          GoRoute(path: '/splash', builder: (_, _) => const Text('splash')),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('so du 1.000.000')),
          ),
        ],
      );
      addTearDown(router.dispose);
      return ProviderScope(
        overrides: overrides(store: store, bio: bio, clock: clock),
        child: MaterialApp.router(
          theme: buildMomaTheme(),
          routerConfig: router,
          builder: (context, child) => LockGate(
            router: router,
            child: SelectionArea(child: child ?? const SizedBox.shrink()),
          ),
        ),
      );
    }

    testWidgets('PIN setup: mismatch shakes and restarts, match returns PIN', (
      tester,
    ) async {
      tall(tester);
      String? result;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildMomaTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => result = await Navigator.of(context)
                      .push<String>(
                        MaterialPageRoute(builder: (_) => const PinSetupPage()),
                      ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Nhập mã PIN gồm 6 số'), findsOneWidget);
      await enter(tester, '123456');
      expect(find.text('Nhập lại mã PIN'), findsOneWidget);
      await enter(tester, '123450');
      expect(find.text('Mã PIN không khớp. Nhập lại từ đầu.'), findsOneWidget);
      expect(find.text('Nhập mã PIN gồm 6 số'), findsOneWidget);
      // Backspace removes the last digit.
      await enter(tester, '12345');
      await tester.tap(find.byKey(const ValueKey('pin-key-del')));
      await tester.pump();
      await enter(tester, '56');
      expect(find.text('Nhập lại mã PIN'), findsOneWidget);
      await enter(tester, '123456');
      expect(result, '123456');
    });

    testWidgets('lock overlay hides the app until the right PIN', (
      tester,
    ) async {
      tall(tester);
      final clock = Clock();
      final store = await storeWithPin('123456');
      await tester.pumpWidget(
        gatedApp(store: store, bio: FakeBio(), clock: clock),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nhập mã PIN để mở MoMa'), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-key-bio')), findsNothing);

      await enter(tester, '111111');
      expect(find.text('Mã PIN không đúng. Còn 4 lần thử.'), findsOneWidget);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsOneWidget);

      await enter(tester, '123456');
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
      expect(find.text('so du 1.000.000'), findsOneWidget);
    });

    testWidgets('countdown after 5 wrong PINs', (tester) async {
      tall(tester);
      final clock = Clock();
      final store = await storeWithPin('123456');
      await tester.pumpWidget(
        gatedApp(store: store, bio: FakeBio(), clock: clock),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await enter(tester, '999999');
      }
      expect(find.text('Thử lại sau 10 giây'), findsOneWidget);
      // Keypad is disabled during the wait.
      await enter(tester, '123456');
      expect(find.text('Nhập mã PIN để mở MoMa'), findsOneWidget);
      clock.now = clock.now.add(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Thử lại sau 6 giây'), findsOneWidget);
      clock.now = clock.now.add(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Thử lại sau'), findsNothing);
      await enter(tester, '123456');
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
    });

    testWidgets('biometric auto-prompts once and unlocks', (tester) async {
      tall(tester);
      final bio = FakeBio(result: true);
      final store = await storeWithPin('123456', bio: true);
      await tester.pumpWidget(gatedApp(store: store, bio: bio, clock: Clock()));
      await tester.pumpAndSettle();
      expect(bio.prompts, 1);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
      expect(find.text('so du 1.000.000'), findsOneWidget);
    });

    testWidgets('cancelled biometric leaves the PIN pad and its button', (
      tester,
    ) async {
      tall(tester);
      final bio = FakeBio(result: false);
      final store = await storeWithPin('123456', bio: true);
      await tester.pumpWidget(gatedApp(store: store, bio: bio, clock: Clock()));
      await tester.pumpAndSettle();
      expect(bio.prompts, 1);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsOneWidget);
      bio.result = true;
      await tester.tap(find.byKey(const ValueKey('pin-key-bio')));
      await tester.pumpAndSettle();
      expect(bio.prompts, 2);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
    });

    testWidgets('no lock over the splash; no lock when disabled', (
      tester,
    ) async {
      tall(tester);
      final store = await storeWithPin('123456');
      await tester.pumpWidget(
        gatedApp(
          store: store,
          bio: FakeBio(),
          clock: Clock(),
          initial: '/splash',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('splash'), findsOneWidget);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        gatedApp(store: MemLockStorage(), bio: FakeBio(), clock: Clock()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
      expect(find.text('so du 1.000.000'), findsOneWidget);
    });

    testWidgets('ensureUnlocked asks for the PIN when the lock is on', (
      tester,
    ) async {
      tall(tester);
      final store = await storeWithPin('123456');
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(store: store, bio: FakeBio(), clock: Clock()),
          child: MaterialApp(
            theme: buildMomaTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => result = await ensureUnlocked(context),
                  child: const Text('quick'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('quick'));
      await tester.pumpAndSettle();
      expect(find.text('Nhập mã PIN để mở MoMa'), findsOneWidget);
      await enter(tester, '123456');
      expect(result, isTrue);
      expect(find.text('Nhập mã PIN để mở MoMa'), findsNothing);
    });
  });
}
