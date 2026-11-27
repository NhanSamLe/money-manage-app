import 'dart:ui' show PathMetric;

import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/ui/motion.dart';

import 'package:material_symbols_icons/symbols.dart';

/// Animated vector hero: the phone floats, its chart draws itself, coins drop onto the platform and the four
/// feature tiles bob at different rhythms (stylised version of the design's illustration, drawn in code).
class WelcomeHero extends StatefulWidget {
  const WelcomeHero({super.key, this.height = 250});
  final double height;

  @override
  State<WelcomeHero> createState() => _WelcomeHeroState();
}

class _WelcomeHeroState extends State<WelcomeHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _seg(double a, double b, Curve curve) =>
      curve.transform(((_c.value - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final height = widget.height;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final enter = _seg(0.0, 0.35, Curves.easeOutBack);
              final chart = _seg(0.25, 0.8, Curves.easeInOutCubic);
              final coins = _seg(0.45, 1.0, Curves.bounceOut);
              final tiles = _seg(0.1, 0.5, Curves.easeOutBack);
              return Stack(
                alignment: Alignment.center,
                children: [
                  // platform
                  Positioned(
                    bottom: 8,
                    child: Transform.scale(
                      scale: enter,
                      child: Container(
                        width: w * 0.62,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(40),
                        ),
                      ),
                    ),
                  ),
                  // leaves sway
                  Positioned(
                    left: w * 0.24,
                    bottom: 22,
                    child: _Sway(
                      angle: -0.5,
                      child: _leaf(const Color(0xFF2F9E6E)),
                    ),
                  ),
                  Positioned(
                    right: w * 0.24,
                    bottom: 22,
                    child: _Sway(
                      angle: 0.5,
                      phase: 0.5,
                      child: _leaf(const Color(0xFF1F8A5F)),
                    ),
                  ),
                  // phone
                  Bob(
                    amplitude: 5,
                    period: const Duration(milliseconds: 3600),
                    child: Transform.scale(
                      scale: enter,
                      child: Transform.rotate(
                        angle: -0.12,
                        child: _phone(context, w, height, chart),
                      ),
                    ),
                  ),
                  // coins drop and bounce onto the platform
                  Positioned(
                    right: w * 0.2,
                    bottom: 20 + (1 - coins) * (height * 0.7),
                    child: Opacity(
                      opacity: coins.clamp(0.0, 1.0),
                      child: _coins(),
                    ),
                  ),
                  // floating tiles
                  _floating(
                    left: w * 0.08,
                    top: height * 0.12,
                    t: tiles,
                    phase: 0.0,
                    icon: Symbols.savings_rounded,
                    color: const Color(0xFF1F7A5C),
                    context: context,
                  ),
                  _floating(
                    right: w * 0.08,
                    top: height * 0.06,
                    t: tiles,
                    phase: 0.3,
                    icon: Symbols.bar_chart_rounded,
                    color: const Color(0xFF2FBF8F),
                    context: context,
                  ),
                  _floating(
                    left: w * 0.04,
                    bottom: height * 0.22,
                    t: tiles,
                    phase: 0.6,
                    icon: Symbols.restaurant_rounded,
                    color: const Color(0xFF1F7A5C),
                    context: context,
                  ),
                  _floating(
                    right: w * 0.04,
                    bottom: height * 0.3,
                    t: tiles,
                    phase: 0.85,
                    icon: Symbols.account_balance_wallet_rounded,
                    color: const Color(0xFF1F7A5C),
                    context: context,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _phone(BuildContext context, double w, double height, double chart) {
    return Container(
      width: w * 0.36,
      height: height * 0.8,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: MomaColors.forest,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33073D33),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF1FAF5),
          borderRadius: BorderRadius.circular(17),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFD8F1E3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: CustomPaint(
                  painter: _ChartPainter(chart),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      value: 0.7 * chart,
                      strokeWidth: 6,
                      color: MomaColors.emerald,
                      backgroundColor: MomaColors.mint.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final f in [1.0, 0.8, 0.6])
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.5),
                            child: FractionallySizedBox(
                              widthFactor: f * chart,
                              child: Container(
                                height: 5,
                                decoration: BoxDecoration(
                                  color: MomaColors.mint,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _floating({
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double t,
    required double phase,
    required IconData icon,
    required Color color,
    required BuildContext context,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: t,
          child: Bob(
            amplitude: 7,
            phase: phase,
            period: Duration(milliseconds: 2600 + (phase * 1400).round()),
            child: _tile(context, icon, color),
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, Color color) => Container(
    width: 54,
    height: 54,
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22073D33),
          blurRadius: 10,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Icon(icon, color: color, size: 30),
  );

  Widget _leaf(Color color) => Container(
    width: 46,
    height: 96,
    decoration: BoxDecoration(
      color: color,
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(46),
        topRight: Radius.circular(8),
        bottomLeft: Radius.circular(8),
        bottomRight: Radius.circular(46),
      ),
    ),
  );

  Widget _coins() => SizedBox(
    width: 64,
    height: 56,
    child: Stack(
      children: [
        for (var i = 0; i < 4; i++)
          Positioned(
            left: 4.0 + (i % 2) * 6,
            bottom: i * 9.0,
            child: Container(
              width: 44,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFFF5C542),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE0A800), width: 1.5),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Slow rotation back and forth (leaves in the wind).
class _Sway extends StatefulWidget {
  const _Sway({required this.child, required this.angle, this.phase = 0});
  final Widget child;
  final double angle;
  final double phase;
  @override
  State<_Sway> createState() => _SwayState();
}

class _SwayState extends State<_Sway> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
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
    builder: (_, child) => Transform.rotate(
      angle: widget.angle + (Curves.easeInOut.transform(_c.value) - 0.5) * 0.12,
      alignment: Alignment.bottomCenter,
      child: child,
    ),
  );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(s.width * 0.08, s.height * 0.78)
      ..lineTo(s.width * 0.28, s.height * 0.5)
      ..lineTo(s.width * 0.45, s.height * 0.62)
      ..lineTo(s.width * 0.68, s.height * 0.32)
      ..lineTo(s.width * 0.9, s.height * 0.18);
    final PathMetric m = p.computeMetrics().first;
    final drawn = m.extractPath(0, m.length * progress);
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = MomaColors.emerald,
    );
    if (progress > 0) {
      final tan = m.getTangentForOffset(m.length * progress);
      if (tan != null) {
        canvas.drawCircle(
          tan.position,
          4.5,
          Paint()..color = MomaColors.emerald,
        );
        canvas.drawCircle(
          tan.position,
          8,
          Paint()..color = MomaColors.emerald.withValues(alpha: 0.25),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.progress != progress;
}
