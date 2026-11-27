import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

/// Ring chart drawn with a [CustomPainter]; [center] sits in the hole.
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.values,
    required this.colors,
    required this.trackColor,
    this.size = 168,
    this.thickness = 22,
    this.center,
  });
  final List<double> values;
  final List<Color> colors;
  final Color trackColor;
  final double size;
  final double thickness;
  final Widget? center;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CustomPaint(
          size: Size.square(size),
          painter: _DonutPainter(values, colors, trackColor, thickness),
        ),
        if (center != null)
          Padding(padding: EdgeInsets.all(thickness + 10), child: center),
      ],
    ),
  );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors, this.track, this.thickness);
  final List<double> values;
  final List<Color> colors;
  final Color track;
  final double thickness;

  @override
  void paint(Canvas canvas, Size s) {
    final inset = thickness / 2 + 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      s.width - inset * 2,
      s.height - inset * 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final gap = values.where((v) => v > 0).length > 1 ? 0.035 : 0.0;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweep = values[i] / total * 2 * math.pi;
      paint.color = colors[i % colors.length];
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(sweep - gap, 0.012),
        false,
        paint,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      !listEquals(old.values, values) ||
      !listEquals(old.colors, colors) ||
      old.track != track;
}
