import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

/// Compact money label for chart axes: 1.500.000 -> "1,5tr", 250.000 -> "250k".
String compactVnd(num v) {
  final a = v.abs();
  String trim(double x) {
    final s = x.toStringAsFixed(x >= 10 ? 0 : 1);
    return (s.endsWith('.0') ? s.substring(0, s.length - 2) : s).replaceAll(
      '.',
      ',',
    );
  }

  if (a == 0) return '0';
  if (a >= 1e9) return '${trim(a / 1e9)} tỷ';
  if (a >= 1e6) return '${trim(a / 1e6)}tr';
  if (a >= 1e3) return '${trim(a / 1e3)}k';
  return a.round().toString();
}

/// Vertical bar chart with a y axis (compact VND), sparse x labels and tap-to-inspect tooltip.
class MoneyBarChart extends StatefulWidget {
  const MoneyBarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.tooltips,
    required this.color,
    required this.gridColor,
    required this.labelColor,
    required this.tooltipColor,
    required this.tooltipTextColor,
    this.height = 190,
  });

  final List<int> values;

  /// One per bar; empty strings are skipped.
  final List<String> labels;

  /// Text shown above a tapped bar.
  final List<String> tooltips;
  final Color color;
  final Color gridColor;
  final Color labelColor;
  final Color tooltipColor;
  final Color tooltipTextColor;
  final double height;

  @override
  State<MoneyBarChart> createState() => _MoneyBarChartState();
}

class _MoneyBarChartState extends State<MoneyBarChart> {
  int? _selected;

  @override
  void didUpdateWidget(MoneyBarChart old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final i = _BarPainter.indexAt(
            d.localPosition,
            size,
            widget.values.length,
          );
          setState(() => _selected = (i == null || i == _selected) ? null : i);
        },
        child: CustomPaint(
          size: size,
          painter: _BarPainter(
            values: widget.values,
            labels: widget.labels,
            tooltips: widget.tooltips,
            selected: _selected,
            color: widget.color,
            grid: widget.gridColor,
            label: widget.labelColor,
            tip: widget.tooltipColor,
            tipText: widget.tooltipTextColor,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
      );
    },
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.values,
    required this.labels,
    required this.tooltips,
    required this.selected,
    required this.color,
    required this.grid,
    required this.label,
    required this.tip,
    required this.tipText,
    required this.textScaler,
  });
  final List<int> values;
  final List<String> labels;
  final List<String> tooltips;
  final int? selected;
  final Color color;
  final Color grid;
  final Color label;
  final Color tip;
  final Color tipText;
  final TextScaler textScaler;

  static const _axisW = 36.0;
  static const _bottomH = 20.0;
  static const _topPad = 30.0; // room for the tooltip above the tallest bar
  static const _ticks = 4;

  static Rect _plot(Size s) =>
      Rect.fromLTRB(_axisW, _topPad, s.width - 2, s.height - _bottomH);

  static int? indexAt(Offset p, Size s, int n) {
    if (n == 0) return null;
    final r = _plot(s);
    if (p.dx < r.left || p.dx > r.right) return null;
    final i = ((p.dx - r.left) / (r.width / n)).floor();
    return i.clamp(0, n - 1);
  }

  /// Rounded axis maximum split into [_ticks] even steps (1, 2, 2.5, 5 x 10^k).
  static double niceMax(double max) {
    if (max <= 0) return 1;
    final raw = max / _ticks;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final r = raw / mag;
    final step = r <= 1
        ? 1
        : r <= 2
        ? 2
        : r <= 2.5
        ? 2.5
        : r <= 5
        ? 5
        : 10;
    return step * mag * _ticks;
  }

  TextPainter _text(String s, Color c, double size, {FontWeight? w}) =>
      TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(color: c, fontSize: size, fontWeight: w),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler.clamp(maxScaleFactor: 1.2),
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size s) {
    final r = _plot(s);
    final maxV = values.fold<int>(0, math.max).toDouble();
    final top = niceMax(maxV);

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var t = 0; t <= _ticks; t++) {
      final y = r.bottom - r.height * t / _ticks;
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), gridPaint);
      final tp = _text(compactVnd(top * t / _ticks), label, 10);
      tp.paint(canvas, Offset(_axisW - 6 - tp.width, y - tp.height / 2));
    }

    final n = values.length;
    if (n == 0) return;
    final slot = r.width / n;
    final barW = math.min(slot * 0.62, 26.0);
    final radius = Radius.circular(math.min(barW / 2, 5));
    final barPaint = Paint();
    for (var i = 0; i < n; i++) {
      final cx = r.left + slot * (i + 0.5);
      if (values[i] > 0) {
        final h = math.max(values[i] / top * r.height, 2.0);
        barPaint.color = (selected == null || selected == i)
            ? color
            : color.withValues(alpha: 0.35);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(cx - barW / 2, r.bottom - h, barW, h),
            topLeft: radius,
            topRight: radius,
          ),
          barPaint,
        );
      }
      if (i < labels.length && labels[i].isNotEmpty) {
        final tp = _text(labels[i], label, 10);
        final x = (cx - tp.width / 2)
            .clamp(r.left - 4, math.max(r.left - 4, s.width - tp.width))
            .toDouble();
        tp.paint(canvas, Offset(x, r.bottom + 5));
      }
    }

    final sel = selected;
    if (sel != null && sel < n && sel < tooltips.length) {
      final cx = r.left + slot * (sel + 0.5);
      final h = values[sel] <= 0
          ? 0.0
          : math.max(values[sel] / top * r.height, 2.0);
      final tp = _text(tooltips[sel], tipText, 11, w: FontWeight.w700);
      final w = tp.width + 16;
      final hh = tp.height + 8;
      final left = (cx - w / 2)
          .clamp(0.0, math.max(0.0, s.width - w))
          .toDouble();
      final bottom = math.max(r.bottom - h - 6, hh);
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, bottom - hh, w, hh),
        const Radius.circular(8),
      );
      canvas.drawRRect(box, Paint()..color = tip);
      tp.paint(canvas, Offset(left + 8, bottom - hh + 4));
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      !listEquals(old.values, values) ||
      !listEquals(old.labels, labels) ||
      old.selected != selected ||
      old.color != color ||
      old.grid != grid ||
      old.label != label ||
      old.tip != tip;
}
