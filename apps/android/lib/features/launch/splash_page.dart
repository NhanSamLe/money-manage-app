import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import '../../core/ui/brand.dart';
import '../../core/ui/motion.dart';

/// Launch screen (design 01) with a staged animation:
/// glow + rising particles -> the ribbon "M" draws itself -> app tile pops with pulse rings -> wordmark and
/// tagline slide in -> coins drop and a shimmer bar fills. Then it routes: signed in -> app,
/// first run -> introduction slides, otherwise -> welcome.
class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({
    super.key,
    this.minDuration = const Duration(milliseconds: 2800),
  });

  /// Keeps the splash on screen long enough for the animation to play (tests pass zero).
  final Duration minDuration;

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  @override
  void initState() {
    super.initState();
    _route();
  }

  Future<void> _route() async {
    final store = ref.read(storeProvider);
    final started = DateTime.now();
    var introSeen = true;
    try {
      introSeen = await store.introSeen();
    } on Object {
      // Storage unavailable: skip the intro rather than blocking the app.
    }
    final wait = widget.minDuration - DateTime.now().difference(started);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    if (!mounted) return;
    bool signedIn;
    try {
      signedIn = Supabase.instance.client.auth.currentSession != null;
    } on Object {
      signedIn = false;
    }
    context.go(signedIn ? '/home' : (introSeen ? '/welcome' : '/intro'));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _seg(double a, double b, [Curve curve = Curves.easeOut]) =>
      curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final draw = _seg(0.04, 0.38, Curves.easeInOutCubic);
          final tile = _seg(0.34, 0.54, Curves.easeOutBack);
          final pulse = _seg(0.36, 1.0, Curves.linear);
          final word = _seg(0.50, 0.70, Curves.easeOutCubic);
          final tag1 = _seg(0.62, 0.80);
          final tag2 = _seg(0.70, 0.88);
          final bar = _seg(0.30, 1.0, Curves.easeInOut);
          final glow = _seg(0.0, 0.5, Curves.easeOut);
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF04261F),
                      MomaColors.forest,
                      Color(0xFF1B7A62),
                    ],
                    stops: [0, 0.55, 1],
                  ),
                ),
              ),
              // soft radial glow behind the mark
              Opacity(
                opacity: glow,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.25),
                      radius: 0.9,
                      colors: [Color(0x552FBF8F), Color(0x00052E26)],
                    ),
                  ),
                ),
              ),
              const Floaters(),
              SafeArea(
                child: Column(
                  children: [
                    const Spacer(flex: 4),
                    SizedBox(
                      width: 260,
                      height: 260,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            size: const Size(260, 260),
                            painter: PulseRings(
                              pulse * 3 % 1.0,
                              color: MomaColors.mint,
                            ),
                          ),
                          Transform.scale(
                            scale: tile,
                            child: Opacity(
                              opacity: tile.clamp(0.0, 1.0),
                              child: Container(
                                width: 168,
                                height: 168,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(44),
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF0B5A48),
                                      MomaColors.emerald,
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF2FBF8F)
                                          .withValues(alpha: 0.35),
                                      blurRadius: 40,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          MomaMark(size: 76, progress: draw),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: word,
                      child: Transform.translate(
                        offset: Offset(0, 22 * (1 - word)),
                        child: const Column(
                          children: [
                            Text(
                              'MoMa',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 44,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1.2,
                              ),
                            ),
                            Text(
                              'MoneyManage',
                              style: TextStyle(
                                color: MomaColors.mint,
                                fontSize: 17,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(flex: 3),
                    Opacity(
                      opacity: tag1,
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - tag1)),
                        child: const Text(
                          'Hiểu dòng tiền.',
                          style: TextStyle(color: Colors.white70, fontSize: 17),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Opacity(
                      opacity: tag2,
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - tag2)),
                        child: const Text(
                          'Làm chủ tài chính.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 140,
                      height: 5,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Stack(
                          children: [
                            Container(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                            FractionallySizedBox(
                              widthFactor: bar,
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      MomaColors.mint,
                                      Color(0xFF34D399),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 44),
                  ],
                ),
              ),
              // coins dropping in from above, landing with a bounce
              for (final (i, x) in const [0.18, 0.78, 0.30, 0.66].indexed)
                _Coin(
                  t: _seg(0.28 + i * 0.07, 0.78 + i * 0.05, Curves.bounceOut),
                  fade: _seg(0.28 + i * 0.07, 0.40 + i * 0.07),
                  x: x,
                  landing: 0.60 + (i.isEven ? 0.05 : -0.02) + i * 0.03,
                  size: 20.0 + (i % 2) * 8,
                  turns: i.isEven ? 1.0 : -1.0,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Coin extends StatelessWidget {
  const _Coin({
    required this.t,
    required this.fade,
    required this.x,
    required this.landing,
    required this.size,
    required this.turns,
  });
  final double t, fade, x, landing, size, turns;

  @override
  Widget build(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    final y = -40 + (s.height * landing + 40) * t;
    return Positioned(
      left: s.width * x - size / 2,
      top: y,
      child: Opacity(
        opacity: fade,
        child: Transform.rotate(
          angle: (1 - t) * math.pi * 2 * turns,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFE082), Color(0xFFF5B800)],
              ),
              border: Border.all(color: const Color(0xFFE0A800), width: 1.5),
            ),
            child: Text(
              '₫',
              style: TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w800,
                color: const Color(0xFF8A6100),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
