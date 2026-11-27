import 'package:material_ui/material_ui.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import 'goal_insights.dart';

/// Circular progress with the percentage in the middle.
class GoalProgressRing extends StatelessWidget {
  const GoalProgressRing({
    super.key,
    required this.value,
    required this.color,
    this.size = 56,
    this.stroke = 6,
    this.fontSize = 13,
  });
  final double value;
  final Color color;
  final double size;
  final double stroke;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: context.pal.lineSoft,
              color: color,
            ),
          ),
          Padding(
            padding: EdgeInsets.all(stroke + 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$pct%',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small trophy drawn from icons and shapes (no image assets).
class _Trophy extends StatelessWidget {
  const _Trophy();

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFF2B01E);
    return SizedBox.square(
      dimension: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  gold.withValues(alpha: 0.28),
                  MomaColors.mint.withValues(alpha: 0.35),
                ],
              ),
            ),
          ),
          const Icon(
            Symbols.emoji_events_rounded,
            size: 36,
            fill: 1,
            color: gold,
          ),
          const Positioned(
            top: 2,
            right: 4,
            child: Icon(Symbols.star_rounded, size: 14, fill: 1, color: gold),
          ),
          Positioned(
            bottom: 6,
            left: 4,
            child: Icon(
              Symbols.star_rounded,
              size: 10,
              fill: 1,
              color: MomaColors.emerald.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

/// Overview at the top of the goals tab.
class GoalsSummaryCard extends StatelessWidget {
  const GoalsSummaryCard({super.key, required this.board});
  final GoalsBoard board;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final label = TextStyle(fontSize: 13, color: pal.muted);
    final value = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: pal.ink,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pal.line),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [pal.tint, pal.surface],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tổng mục tiêu', style: label),
                    const SizedBox(height: 2),
                    Text('${board.items.length} mục tiêu', style: value),
                    const SizedBox(height: 10),
                    Text('Tổng cần tiết kiệm', style: label),
                    const SizedBox(height: 2),
                    Text(
                      formatVnd(board.target),
                      style: value.copyWith(fontSize: 18),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const _Trophy(),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              GoalProgressRing(
                value: board.progress,
                color: MomaColors.emerald,
                size: 64,
                stroke: 7,
                fontSize: 15,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Đã tiết kiệm', style: label),
                    const SizedBox(height: 2),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: formatVnd(board.saved),
                            style: value.copyWith(color: MomaColors.emerald),
                          ),
                          TextSpan(
                            text: ' / ${formatVnd(board.target)}',
                            style: label,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Chỉ là khoản dành riêng, không trừ vào số dư tài khoản.',
                      style: TextStyle(fontSize: 12, color: pal.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Filter chip with a count, e.g. "Đang thực hiện (2)".
class GoalFilterChip extends StatelessWidget {
  const GoalFilterChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Material(
      color: active ? MomaColors.emerald : context.pal.surface,
      shape: StadiumBorder(
        side: BorderSide(color: active ? MomaColors.emerald : context.pal.line),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : context.pal.ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// One savings goal: icon tile, amounts, progress bar, deadline, ring and an encouragement pill.
class GoalCard extends StatelessWidget {
  const GoalCard({
    super.key,
    required this.item,
    required this.now,
    this.onTap,
  });
  final GoalItem item;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final g = item.goal;
    final style = goalStyleFor(g.name);
    final mood = goalMood(item, now);
    final barColor = item.done ? MomaColors.income : style.color;
    final label = TextStyle(fontSize: 13, color: pal.muted);
    TextSpan amount(int v, Color c) => TextSpan(
      text: formatVnd(v),
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          style.color.withValues(alpha: 0.26),
                          style.color.withValues(alpha: 0.08),
                        ],
                      ),
                    ),
                    child: Icon(
                      style.icon,
                      size: 30,
                      fill: 1,
                      color: style.color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(style.icon, size: 16, color: style.color),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                g.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: pal.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text.rich(
                          TextSpan(
                            style: label,
                            children: [
                              const TextSpan(text: 'Mục tiêu: '),
                              amount(g.target, pal.ink),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            style: label,
                            children: [
                              const TextSpan(text: 'Đã tiết kiệm: '),
                              amount(g.allocated, MomaColors.emerald),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GoalProgressRing(value: g.progress, color: barColor),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: g.progress,
                  minHeight: 8,
                  backgroundColor: pal.lineSoft,
                  color: barColor,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Symbols.event_rounded, size: 16, color: pal.muted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(goalDeadlineLabel(item, now), style: label),
                      ),
                    ],
                  ),
                  _MoodPill(mood: mood),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoodPill extends StatelessWidget {
  const _MoodPill({required this.mood});
  final GoalMood mood;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: mood.color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(mood.icon, size: 14, fill: 1, color: mood.color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            mood.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: mood.color,
            ),
          ),
        ),
      ],
    ),
  );
}
