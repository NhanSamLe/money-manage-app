import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';
import '../../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

/// "Báo cáo": month selector, income/expense and where the money went (deterministic server totals).
class ReportsPage extends ConsumerWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(summaryProvider);
    final month = ref.watch(selectedMonthProvider);
    final notifier = ref.read(selectedMonthProvider.notifier);
    return MomaPage(
      title: 'Báo cáo',
      subtitle: 'Phân tích thu chi theo tháng',
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(summaryProvider);
          await ref.read(summaryProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: context.pal.surface,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: 'Tháng trước',
                    icon: const Icon(Symbols.chevron_left_rounded),
                    onPressed: () => notifier.shift(-1),
                  ),
                  Flexible(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final now = DateTime.now();
                        final months = [
                          for (var i = 0; i < 12; i++)
                            DateTime(now.year, now.month - i),
                        ];
                        String key(DateTime d) =>
                            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
                        final v = await showChoiceSheet<String>(
                          context,
                          title: 'Chọn tháng',
                          selected: month,
                          options: [
                            for (final d in months)
                              ChoiceOption(
                                value: key(d),
                                label: 'Tháng ${d.month}/${d.year}',
                                icon: Symbols.calendar_month_rounded,
                              ),
                          ],
                        );
                        if (v != null) notifier.set(v);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Tháng ${month.substring(5)}/${month.substring(0, 4)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                            const Icon(Symbols.keyboard_arrow_down_rounded),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tháng sau',
                    icon: const Icon(Symbols.chevron_right_rounded),
                    onPressed: () => notifier.shift(1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            summary.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SizedBox(
                height: 280,
                child: ErrorView(
                  error: e,
                  onRetry: () => ref.invalidate(summaryProvider),
                ),
              ),
              data: (s) => _Body(summary: s),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.summary});
  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final spends = s.byCategory.where((c) => c.amount > 0).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _Flow(
                label: 'Thu nhập',
                value: '+${formatVnd(s.income)}',
                color: MomaColors.income,
                icon: Symbols.south_rounded,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Flow(
                label: 'Chi tiêu',
                value: '-${formatVnd(s.expense)}',
                color: MomaColors.expense,
                icon: Symbols.north_east_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.pal.surface,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chi tiêu theo danh mục',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
              const SizedBox(height: 12),
              if (spends.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Chưa có chi tiêu trong tháng này.',
                      style: TextStyle(color: context.pal.muted),
                    ),
                  ),
                )
              else ...[
                Center(
                  child: SizedBox(
                    width: 180,
                    height: 180,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: const Size(180, 180),
                          painter: _DonutPainter(
                            [for (final c in spends) c.amount.toDouble()],
                            [
                              for (final c in spends)
                                categoryStyle(c.icon).color,
                            ],
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Tổng chi',
                              style: TextStyle(
                                color: context.pal.muted,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              formatVnd(s.expense),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final c in spends) _Row(spend: c, total: s.expense),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Flow extends StatelessWidget {
  const _Flow({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: context.pal.muted, fontSize: 12),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.spend, required this.total});
  final CategorySpend spend;
  final int total;
  @override
  Widget build(BuildContext context) {
    final style = categoryStyle(spend.icon);
    final share = total <= 0 ? 0.0 : (spend.amount / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              CategoryAvatar(iconKey: spend.icon, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  spend.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                formatVnd(spend.amount),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 40,
                child: Text(
                  '${(share * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 6,
              backgroundColor: context.pal.lineSoft,
              color: style.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors);
  final List<double> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size s) {
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final rect = Rect.fromLTWH(14, 14, s.width - 28, s.height - 28);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 24
      ..strokeCap = StrokeCap.butt;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 2 * math.pi;
      paint.color = colors[i % colors.length];
      canvas.drawArc(rect, start, math.max(sweep - 0.03, 0.01), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.values != values;
}
