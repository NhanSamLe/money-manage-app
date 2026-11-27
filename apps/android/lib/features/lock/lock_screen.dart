import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/ui/brand.dart';
import '../../core/widgets.dart';
import 'lock_controller.dart';
import 'lock_services.dart';
import 'pin_pad.dart';

/// PIN entry wired to [LockController.checkPin] with the wrong-attempt countdown.
/// [unlock] also clears the app lock on success (lock screen); otherwise it only verifies (settings).
class PinChallenge extends ConsumerStatefulWidget {
  const PinChallenge({
    super.key,
    required this.onSuccess,
    this.unlock = false,
    this.onBrand = false,
    this.extraKey,
  });
  final VoidCallback onSuccess;
  final bool unlock;
  final bool onBrand;
  final Widget? extraKey;

  @override
  ConsumerState<PinChallenge> createState() => _PinChallengeState();
}

class _PinChallengeState extends ConsumerState<PinChallenge> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _ensureTicker() {
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final until = ref.read(lockControllerProvider).coolUntil;
      if (until == null || !until.isAfter(ref.read(lockClockProvider)())) {
        _tick?.cancel();
        _tick = null;
      }
      setState(() {});
    });
  }

  Future<String?> _submit(String pin) async {
    final c = ref.read(lockControllerProvider.notifier);
    final r = widget.unlock
        ? await c.unlockWithPin(pin)
        : await c.checkPin(pin);
    if (r.ok) {
      widget.onSuccess();
      return null;
    }
    if (r.waitUntil != null) {
      _ensureTicker();
      return 'Bạn đã nhập sai nhiều lần';
    }
    return 'Mã PIN không đúng. Còn ${r.remaining} lần thử.';
  }

  @override
  Widget build(BuildContext context) {
    final until = ref.watch(lockControllerProvider.select((s) => s.coolUntil));
    final now = ref.read(lockClockProvider)();
    final cooling = until != null && until.isAfter(now);
    if (cooling) _ensureTicker();
    final secs = cooling
        ? (until.difference(now).inMilliseconds / 1000).ceil()
        : 0;
    return PinEntry(
      onCompleted: _submit,
      enabled: !cooling,
      message: cooling ? 'Thử lại sau $secs giây' : null,
      onBrand: widget.onBrand,
      extraKey: widget.extraKey,
    );
  }
}

/// Full-screen lock: logo, "Nhập mã PIN để mở MoMa", keypad, biometric key (auto-prompts once), "Quên mã PIN?".
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, this.onDone});

  /// Standalone use (widget sheet): called with true when unlocked, false after "Quên mã PIN?" or "Hủy".
  /// Null inside the app gate, which hides the screen by itself when the state unlocks.
  final ValueChanged<bool>? onDone;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(lockControllerProvider).config.biometric) _bio();
    });
  }

  Future<void> _bio() async {
    final ok = await ref
        .read(lockControllerProvider.notifier)
        .unlockWithBiometric();
    if (ok && mounted) widget.onDone?.call(true);
  }

  Future<void> _forgot() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Quên mã PIN?',
      message: 'Bạn cần đăng xuất rồi đăng nhập lại bằng mật khẩu. Khóa ứng dụng sẽ được tắt, bạn có thể bật lại trong Cài đặt.',
      confirmLabel: 'Đăng xuất',
    );
    if (!ok || !mounted) return;
    await ref.read(lockControllerProvider.notifier).forgotPin();
    if (mounted) widget.onDone?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final bio = ref.watch(
      lockControllerProvider.select((s) => s.config.biometric),
    );
    return Scaffold(
      backgroundColor: MomaColors.forest,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF04261F), MomaColors.forest, Color(0xFF1B7A62)],
            stops: [0, 0.55, 1],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onDone != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => widget.onDone!(false),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Hủy'),
                      ),
                    ),
                  const MomaAppIcon(size: 72),
                  const SizedBox(height: 18),
                  const Text(
                    'Nhập mã PIN để mở MoMa',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 28),
                  PinChallenge(
                    unlock: true,
                    onBrand: true,
                    onSuccess: () => widget.onDone?.call(true),
                    extraKey: bio
                        ? PinKey(
                            key: const ValueKey('pin-key-bio'),
                            onBrand: true,
                            filled: false,
                            semanticLabel: 'Dùng vân tay / khuôn mặt',
                            onTap: _bio,
                            child: const Icon(
                              Symbols.fingerprint_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _forgot,
                    style: TextButton.styleFrom(
                      foregroundColor: MomaColors.mint,
                    ),
                    child: const Text('Quên mã PIN?'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts the lock screen above the whole router when the app is locked. Wrap the `MaterialApp.router` builder
/// child with it. Waits while the splash is showing so the launch animation plays first.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child, this.router});
  final Widget child;
  final GoRouter? router;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  late bool _signedIn;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.router?.routerDelegate.addListener(_onRoute);
    _signedIn = ref.read(lockSignedInProvider)();
  }

  @override
  void didUpdateWidget(LockGate old) {
    super.didUpdateWidget(old);
    if (old.router != widget.router) {
      old.router?.routerDelegate.removeListener(_onRoute);
      widget.router?.routerDelegate.addListener(_onRoute);
    }
  }

  @override
  void dispose() {
    widget.router?.routerDelegate.removeListener(_onRoute);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The router can notify while the tree is building (initial route): rebuild after that frame then.
  void _onRoute() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      ref.read(lockControllerProvider.notifier).onLifecycle(state);

  /// Back while locked must not pop the pages hidden underneath.
  @override
  Future<bool> didPopRoute() async => _showing;

  bool get _onSplash {
    final r = widget.router;
    if (r == null) return false;
    final path = r.routerDelegate.currentConfiguration.uri.path;
    return path.isEmpty || path == '/splash';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(lockControllerProvider);
    final signedIn = ref.read(lockSignedInProvider)();
    if (signedIn != _signedIn) {
      _signedIn = signedIn;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(lockControllerProvider.notifier).onAuthChanged();
      });
    }
    final show = signedIn && !_onSplash && (s.locked || !s.loaded);
    _showing = show;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Overlay.wrap also gives the builder's SelectionArea (which sits above the router's Navigator) the
        // Overlay it requires for its handles and toolbar.
        ExcludeSemantics(
          excluding: show,
          child: Overlay.wrap(child: widget.child),
        ),
        if (show)
          Positioned.fill(
            child: s.loaded
                ? const _LockLayer()
                : const ColoredBox(color: MomaColors.forest),
          ),
      ],
    );
  }
}

/// Own navigator so the lock screen's dialogs draw above it (the app navigator sits underneath).
class _LockLayer extends StatelessWidget {
  const _LockLayer();
  @override
  Widget build(BuildContext context) => HeroControllerScope.none(
    child: Navigator(
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const LockScreen(),
        transitionDuration: Duration.zero,
      ),
    ),
  );
}

/// For screens running outside the main app (the home-screen quick-entry sheet): asks for the PIN when the
/// lock is on and the app was not unlocked within the chosen delay. True = go ahead, false = close the sheet.
Future<bool> ensureUnlocked(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final c = container.read(lockControllerProvider.notifier);
  await c.ready;
  if (!container.read(lockControllerProvider).enabled) return true;
  if (!container.read(lockSignedInProvider)()) return true;
  if (await c.recentlyActive()) return true;
  if (!context.mounted) return false;
  final ok = await Navigator.of(context, rootNavigator: true).push<bool>(
    PageRouteBuilder<bool>(
      opaque: true,
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(ctx).pop(false);
        },
        child: LockScreen(onDone: (v) => Navigator.of(ctx).pop(v)),
      ),
    ),
  );
  return ok ?? false;
}
