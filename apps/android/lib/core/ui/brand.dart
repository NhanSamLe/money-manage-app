import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';

/// MoMa brand mark: a two-peak ribbon "M" (left ribbon light mint, right ribbon deeper emerald, soft fold
/// shadow in the middle). Vector, resolution independent. Geometry is identical to scripts/gen-brand.py
/// (mark space 96 x 64) - change both together.
class MomaMark extends StatelessWidget {
  const MomaMark({
    super.key,
    this.size = 40,
    this.solid,
    this.onLight = false,
    this.progress = 1,
  });

  /// 0..1 draw-on animation: the left ribbon is drawn first, then the right one (1 = complete mark).
  final double progress;

  /// Height of the mark; width is size * 1.5.
  final double size;

  /// Single colour variant (monochrome surfaces); null = brand gradient.
  final Color? solid;

  /// Use the deeper gradient palette (for light backgrounds).
  final bool onLight;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Logo MoMa',
    child: CustomPaint(
      size: Size(size * 1.5, size),
      painter: _MarkPainter(solid, onLight, progress),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.solid, this.onLight, this.progress);
  final Color? solid;
  final bool onLight;
  final double progress;

  static const _stroke = 13.5;
  static const _shadowSigma = 2.4;
  static const _shadowAlpha = 0.36;

  static const _palDark = [
    Color(0xFFC9F7D6),
    Color(0xFF6FE3B2),
    Color(0xFF52DBA6),
    Color(0xFF25B98B),
  ];
  static const _palLight = [
    Color(0xFF7BE0B4),
    Color(0xFF34BE92),
    Color(0xFF27A67F),
    Color(0xFF0C6A54),
  ];

  /// Builds a chain of cubics given in mark space, scaled by [k].
  static Path _chain(
    List<List<double>> segs,
    double k, [
    double dx = 0,
    double dy = 0,
  ]) {
    final p = Path()..moveTo((segs[0][0] + dx) * k, (segs[0][1] + dy) * k);
    for (final c in segs) {
      p.cubicTo(
        (c[2] + dx) * k,
        (c[3] + dy) * k,
        (c[4] + dx) * k,
        (c[5] + dy) * k,
        (c[6] + dx) * k,
        (c[7] + dy) * k,
      );
    }
    return p;
  }

  // Each row: x0,y0, c1x,c1y, c2x,c2y, x1,y1.
  static const _ribA = [
    [9.0, 53.0, 14.0, 40.0, 18.0, 11.0, 29.0, 11.0],
    [29.0, 11.0, 40.0, 11.0, 44.0, 33.0, 48.0, 42.0],
  ];
  static const _ribB = [
    [48.0, 42.0, 52.0, 33.0, 56.0, 11.0, 67.0, 11.0],
    [67.0, 11.0, 78.0, 11.0, 82.0, 40.0, 87.0, 53.0],
  ];
  static const _shadow = [
    [48.0, 42.0, 50.2, 37.0, 52.0, 28.0, 56.5, 20.0],
  ];

  @override
  void paint(Canvas canvas, Size s) {
    final k = s.height / 64.0;
    // Centre the 96 x 64 artwork if the box is wider than 1.5:1.
    final dx = (s.width - 96 * k) / 2;
    canvas.save();
    canvas.translate(dx, 0);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final pathA = _chain(_ribA, k);
    final fullB = _chain(_ribB, k);
    final fullA = pathA;
    Path part(Path path, double f) {
      final m = path.computeMetrics().first;
      return m.extractPath(0, m.length * f.clamp(0.0, 1.0));
    }

    final t = progress.clamp(0.0, 1.0);
    final drawA = t >= 1 ? fullA : part(fullA, t * 2);
    final drawB = t >= 1
        ? fullB
        : (t <= 0.5 ? null : part(fullB, (t - 0.5) * 2));
    if (solid != null) {
      stroke.color = solid!;
      canvas.drawPath(drawA, stroke);
      if (drawB != null) canvas.drawPath(drawB, stroke);
      canvas.restore();
      return;
    }
    final pal = onLight ? _palLight : _palDark;
    Paint grad(double x0, double x1, Color c0, Color c1) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..shader = LinearGradient(colors: [c0, c1])
          .createShader(Rect.fromLTRB(x0 * k, 0, x1 * k, s.height));
    canvas.drawPath(drawA, grad(0, 52, pal[0], pal[1]));
    // Fold shadow: B's start, blurred and nudged down, so B reads as lying over A.
    if (drawB != null) {
      canvas.drawPath(
        _chain(_shadow, k, 0, 1.6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke * k
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFF032620).withValues(alpha: _shadowAlpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, _shadowSigma * k),
      );
      canvas.drawPath(drawB, grad(46, 96, pal[2], pal[3]));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.solid != solid || old.onLight != onLight || old.progress != progress;
}

/// Mark + "MoMa" + "MoneyManage" lockup, used in headers and on the welcome screen.
class MomaWordmark extends StatelessWidget {
  const MomaWordmark({super.key, this.size = 36, this.dark = false});
  final double size;

  /// true on light backgrounds (forest text), false on the green header (white text).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    // `dark: true` means "sits on a light surface"; in Dark mode that surface is dark, so use the on-green colours.
    final onLight = dark && Theme.of(context).brightness == Brightness.light;
    final main = onLight ? MomaColors.forest : Colors.white;
    final sub = onLight ? MomaColors.emerald : MomaColors.mint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MomaMark(size: size * 0.9, onLight: onLight),
        SizedBox(width: size * 0.22),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MoMa',
              style: TextStyle(
                color: main,
                fontSize: size * 0.8,
                fontWeight: FontWeight.w800,
                height: 1.0,
                letterSpacing: -0.5,
              ),
            ),
            Text(
              'MoneyManage',
              style: TextStyle(
                color: sub,
                fontSize: size * 0.33,
                height: 1.2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Rounded-square app icon (same artwork as the launcher icon).
class MomaAppIcon extends StatelessWidget {
  const MomaAppIcon({super.key, this.size = 88});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.26),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [MomaColors.forest, MomaColors.emerald],
      ),
    ),
    child: MomaMark(size: size * 0.37),
  );
}
