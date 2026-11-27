import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';

/// MoMa brand mark: a two-peak ribbon "M" (design: logo on every header). Vector, resolution independent.
class MomaMark extends StatelessWidget {
  const MomaMark({super.key, this.size = 40, this.solid});
  final double size;

  /// Single colour variant (monochrome surfaces); null = brand gradient.
  final Color? solid;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Logo MoMa',
    child: CustomPaint(
      size: Size(size * 1.25, size),
      painter: _MarkPainter(solid),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.solid);
  final Color? solid;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final path = Path()
      ..moveTo(w * 0.10, h * 0.80)
      ..lineTo(w * 0.30, h * 0.22)
      ..lineTo(w * 0.50, h * 0.64)
      ..lineTo(w * 0.70, h * 0.22)
      ..lineTo(w * 0.90, h * 0.80);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.26
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (solid != null) {
      paint.color = solid!;
    } else {
      paint.shader = const LinearGradient(
        colors: [Color(0xFF7DF2C4), Color(0xFF34D399), Color(0xFF21B58A)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.solid != solid;
}

/// Mark + "MoMa" + "MoneyManage" lockup, used in headers and on the welcome screen.
class MomaWordmark extends StatelessWidget {
  const MomaWordmark({super.key, this.size = 36, this.dark = false});
  final double size;

  /// true on light backgrounds (forest text), false on the green header (white text).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final main = dark ? MomaColors.forest : Colors.white;
    final sub = dark ? MomaColors.emerald : MomaColors.mint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MomaMark(size: size),
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
    child: MomaMark(size: size * 0.5),
  );
}
