import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Motion switches. Continuous/looping animation is turned off in widget tests (so `pumpAndSettle` can finish)
/// and whenever the user asked the OS to reduce animations.
class Motion {
  const Motion._();

  /// Tests set this to false.
  static bool continuous = true;

  static bool loops(BuildContext context) =>
      continuous && !MediaQuery.of(context).disableAnimations;
}

/// Entrance: fades in while sliding up, after [delay]. One controller (no timers), so it is test friendly.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 520),
    this.dy = 26,
    this.dx = 0,
  });
  final Widget child;
  final Duration delay;
  final Duration duration;
  final double dy;
  final double dx;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    final total = widget.delay + widget.duration;
    _c = AnimationController(vsync: this, duration: total);
    _a = CurvedAnimation(
      parent: _c,
      curve: Interval(
        widget.delay.inMilliseconds / total.inMilliseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    child: widget.child,
    builder: (_, child) => Opacity(
      opacity: _a.value.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(widget.dx * (1 - _a.value), widget.dy * (1 - _a.value)),
        child: child,
      ),
    ),
  );
}

/// Gentle continuous floating (up and down), each instance with its own [phase].
class Bob extends StatefulWidget {
  const Bob({
    super.key,
    required this.child,
    this.amplitude = 8,
    this.period = const Duration(milliseconds: 3200),
    this.phase = 0,
  });
  final Widget child;
  final double amplitude;
  final Duration period;

  /// 0..1 offset into the cycle so neighbours do not move in lockstep.
  final double phase;

  @override
  State<Bob> createState() => _BobState();
}

class _BobState extends State<Bob> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
    value: widget.phase,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.loops(context)) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (_, child) => Transform.translate(
      offset: Offset(
        0,
        (Curves.easeInOut.transform(_c.value) - 0.5) * 2 * widget.amplitude,
      ),
      child: child,
    ),
  );
}

/// Counts a number up (or down) to [value] whenever it changes.
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    required this.builder,
    this.duration = const Duration(milliseconds: 900),
  });
  final int value;
  final String Function(int) builder;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: value.toDouble()),
    duration: duration,
    curve: Curves.easeOutCubic,
    builder: (_, v, _) => Text(builder(v.round())),
  );
}

/// Rising translucent bubbles, rings and golden coins behind a screen (splash / welcome backdrop).
class Floaters extends StatefulWidget {
  const Floaters({
    super.key,
    this.count = 18,
    this.seed = 7,
    this.coins = true,
  });
  final int count;
  final int seed;
  final bool coins;

  @override
  State<Floaters> createState() => _FloatersState();
}

class _FloatersState extends State<Floaters>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  late final List<_Particle> _p = () {
    final r = math.Random(widget.seed);
    return List.generate(widget.count, (i) {
      final coin = widget.coins && i % 6 == 0;
      return _Particle(
        x: r.nextDouble(),
        size: coin ? 10 + r.nextDouble() * 8 : 6 + r.nextDouble() * 26,
        speed: 0.4 + r.nextDouble() * 0.9,
        phase: r.nextDouble(),
        sway: 6 + r.nextDouble() * 18,
        ring: !coin && i % 3 == 0,
        coin: coin,
      );
    });
  }();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.loops(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size.infinite,
          painter: _FloaterPainter(_p, _c.value),
        ),
      ),
    ),
  );
}

class _Particle {
  const _Particle({
    required this.x,
    required this.size,
    required this.speed,
    required this.phase,
    required this.sway,
    required this.ring,
    required this.coin,
  });
  final double x, size, speed, phase, sway;
  final bool ring, coin;
}

class _FloaterPainter extends CustomPainter {
  _FloaterPainter(this.particles, this.t);
  final List<_Particle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size s) {
    for (final p in particles) {
      // 24 s cycle; whole-number multipliers keep the loop seamless.
      final cycle = (t * (p.speed * 3).round().clamp(1, 4) + p.phase) % 1.0;
      final y = s.height * (1.05 - cycle * 1.15);
      final x =
          s.width * p.x + math.sin((cycle + p.phase) * math.pi * 2) * p.sway;
      final fade = math.sin(cycle * math.pi).clamp(0.0, 1.0);
      if (p.coin) {
        final paint = Paint()
          ..color = const Color(0xFFF5C542).withValues(alpha: 0.55 * fade);
        canvas.drawCircle(Offset(x, y), p.size / 2, paint);
        canvas.drawCircle(
          Offset(x, y),
          p.size / 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = const Color(0xFFE0A800).withValues(alpha: 0.7 * fade),
        );
      } else if (p.ring) {
        canvas.drawCircle(
          Offset(x, y),
          p.size / 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = Colors.white.withValues(alpha: 0.18 * fade),
        );
      } else {
        canvas.drawCircle(
          Offset(x, y),
          p.size / 2,
          Paint()..color = Colors.white.withValues(alpha: 0.10 * fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FloaterPainter old) => old.t != t;
}

/// Expanding, fading rings from the centre (pulse), driven by a 0..1 animation value.
class PulseRings extends CustomPainter {
  PulseRings(this.t, {this.color = Colors.white, this.rings = 3});
  final double t;
  final Color color;
  final int rings;

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final maxR = s.shortestSide / 2;
    for (var i = 0; i < rings; i++) {
      final p = ((t * 1.0) - i / rings) % 1.0;
      if (p < 0) continue;
      canvas.drawCircle(
        c,
        maxR * (0.35 + 0.65 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(PulseRings old) => old.t != t;
}
