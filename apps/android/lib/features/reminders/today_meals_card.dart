import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/widgets.dart';
import 'reminders_data.dart';

const _mealIcons = {
  'breakfast': Symbols.bakery_dining_rounded,
  'lunch': Symbols.lunch_dining_rounded,
  'dinner': Symbols.dinner_dining_rounded,
};

/// "Bữa ăn hôm nay": each meal shows Đã ghi / Chưa ghi / Bỏ qua hôm nay, with a switch to mark
/// "Hôm nay không ăn" (so the reminder for that meal is not sent). Renders nothing while loading or when the
/// reminders API is unavailable, so it is safe to place on Home.
class TodayMealsCard extends ConsumerStatefulWidget {
  const TodayMealsCard({super.key});

  @override
  ConsumerState<TodayMealsCard> createState() => _TodayMealsCardState();
}

class _TodayMealsCardState extends ConsumerState<TodayMealsCard> {
  final Set<String> _busy = {};

  Future<void> _toggle(String kind, bool skip) async {
    setState(() => _busy.add(kind));
    try {
      await ref.read(todayRemindersProvider.notifier).skip(kind, skip);
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          e is ApiException ? e.message : 'Không cập nhật được, thử lại sau.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(kind));
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayRemindersProvider).value;
    if (today == null) return const SizedBox.shrink();
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Bữa ăn hôm nay',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: pal.ink,
            ),
          ),
          const SizedBox(height: 4),
          for (final k in mealKinds)
            _MealRow(
              kind: k,
              done: today.done[k] == true,
              skipped: today.skipped.contains(k),
              busy: _busy.contains(k),
              onSkip: (v) => _toggle(k, v),
            ),
        ],
      ),
    );
  }
}

class _MealRow extends StatelessWidget {
  const _MealRow({
    required this.kind,
    required this.done,
    required this.skipped,
    required this.busy,
    required this.onSkip,
  });
  final String kind;
  final bool done;
  final bool skipped;
  final bool busy;
  final ValueChanged<bool> onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final (status, color) = done
        ? ('Đã ghi', MomaColors.income)
        : skipped
        ? ('Bỏ qua hôm nay', pal.muted)
        : ('Chưa ghi', const Color(0xFFE0A100));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(_mealIcons[kind], color: MomaColors.emerald, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mealLabels[kind]!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          if (!done) ...[
            Text(
              'Không ăn',
              style: TextStyle(fontSize: 12.5, color: pal.muted),
            ),
            const SizedBox(width: 4),
            Semantics(
              label: 'Hôm nay không ăn ${mealLabels[kind]!.toLowerCase()}',
              child: MomaSwitch(
                value: skipped,
                onChanged: busy ? null : onSkip,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
