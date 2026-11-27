import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Banknote-style security pattern (guilloche rosettes, stacked wave bands and a stylised lotus) drawn very
/// faintly behind money surfaces: balance hero, totals cards, QR receive card. Generic motifs only: it never
/// reproduces an actual banknote design.
class MoneyPattern extends StatelessWidget {
  const MoneyPattern({
    super.key,
    required this.child,
    this.color = Colors.white,
    this.opacity = 0.10,
    this.rosette = true,
    this.lotus = true,
    this.borderRadius,
  });

  final Widget child;

  /// Ink colour of the lines (white on dark/green surfaces, emerald on light cards).
  final Color color;
  final double opacity;
  final bool rosette;
  final bool lotus;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final painted = CustomPaint(
      painter: _MoneyPatternPainter(
        color: color.withValues(alpha: opacity),
        rosette: rosette,
        lotus: lotus,
      ),
      child: child,
    );
    if (borderRadius == null) return ClipRect(child: painted);
    return ClipRRect(borderRadius: borderRadius!, child: painted);
  }
}

class _MoneyPatternPainter extends CustomPainter {
  _MoneyPatternPainter({
    required this.color,
    required this.rosette,
    required this.lotus,
  });

  final Color color;
  final bool rosette;
  final bool lotus;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final thin = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..isAntiAlias = true;

    _waveBands(canvas, size, thin);
    if (rosette) {
      final r = math.min(size.height * 0.62, size.width * 0.36);
      _guillocheRosette(
        canvas,
        Offset(size.width - r * 0.55, size.height * 0.42),
        r,
        thin,
      );
    }
    if (lotus) {
      final s = math.min(size.height * 0.34, 64.0);
      _lotus(
        canvas,
        Offset(size.width * 0.12, size.height - s * 0.35),
        s,
        thin,
      );
    }
  }

  /// Stacked sine bands across the bottom, like the micro-line borders on banknotes.
  void _waveBands(Canvas canvas, Size size, Paint p) {
    const lines = 7;
    final baseY = size.height * 0.80;
    for (var i = 0; i < lines; i++) {
      final path = Path();
      final amp = 5.0 + i * 0.6;
      final phase = i * 0.55;
      final y0 = baseY + i * 3.2;
      for (double x = 0; x <= size.width; x += 3) {
        final y =
            y0 + math.sin(x / 22 + phase) * amp * math.cos(x / 140 + i * 0.3);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, p);
    }
  }

  /// Hypotrochoid rosettes (classic guilloche) layered with small offsets.
  void _guillocheRosette(Canvas canvas, Offset c, double radius, Paint p) {
    for (var layer = 0; layer < 3; layer++) {
      final big = radius * (1 - layer * 0.16);
      final small = big * 0.27;
      final d = big * (0.42 + layer * 0.05);
      final path = Path();
      const steps = 900;
      for (var k = 0; k <= steps; k++) {
        final t = k / steps * 2 * math.pi * 9;
        final x =
            (big - small) * math.cos(t) +
            d * math.cos((big - small) / small * t);
        final y =
            (big - small) * math.sin(t) -
            d * math.sin((big - small) / small * t);
        final pt = c + Offset(x, y) * 0.52;
        if (k == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(path, p);
    }
    canvas.drawCircle(c, radius * 0.56, p);
    canvas.drawCircle(c, radius * 0.60, p);
  }

  /// Stylised lotus outline: five petals and a base line.
  void _lotus(Canvas canvas, Offset base, double s, Paint p) {
    final petals = <List<double>>[
      [0, 1.0, 0.24],
      [-0.42, 0.78, 0.22],
      [0.42, 0.78, 0.22],
      [-0.78, 0.48, 0.2],
      [0.78, 0.48, 0.2],
    ];
    for (final pet in petals) {
      final tip = base + Offset(pet[0] * s, -pet[1] * s);
      final w = pet[2] * s;
      final path = Path()
        ..moveTo(base.dx, base.dy)
        ..quadraticBezierTo(
          (base.dx + tip.dx) / 2 - w,
          (base.dy + tip.dy) / 2,
          tip.dx,
          tip.dy,
        )
        ..quadraticBezierTo(
          (base.dx + tip.dx) / 2 + w,
          (base.dy + tip.dy) / 2,
          base.dx,
          base.dy,
        );
      canvas.drawPath(path, p);
    }
    canvas.drawLine(base + Offset(-s * 0.9, 0), base + Offset(s * 0.9, 0), p);
  }

  @override
  bool shouldRepaint(_MoneyPatternPainter old) =>
      old.color != color || old.rosette != rosette || old.lotus != lotus;
}

/// Page background for every screen: a soft mint gradient (deep green in dark mode) with the banknote pattern
/// printed very faintly, instead of a flat white page.
class MoneyBackground extends StatelessWidget {
  const MoneyBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF0B1511), Color(0xFF0E1E18), Color(0xFF0B1A14)]
              : const [Color(0xFFF2F8F4), Color(0xFFE8F3EC), Color(0xFFF4F8F1)],
        ),
      ),
      child: MoneyPattern(
        color: dark ? const Color(0xFF6FCF97) : const Color(0xFF1B8A5A),
        opacity: dark ? 0.07 : 0.06,
        child: child,
      ),
    );
  }
}
