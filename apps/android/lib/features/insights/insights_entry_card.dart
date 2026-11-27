import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';

/// Entry card to "Phân tích & đề xuất" (shown at the top of Reports).
class InsightsEntryCard extends StatelessWidget {
  const InsightsEntryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/insights'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: MomaColors.emerald.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Symbols.auto_awesome_rounded,
                  color: MomaColors.emerald,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Phân tích & đề xuất',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: pal.ink,
                      ),
                    ),
                    Text(
                      'Xem thu chi biến động ra sao và gợi ý cho kỳ sau',
                      style: TextStyle(fontSize: 12.5, color: pal.muted),
                    ),
                  ],
                ),
              ),
              Icon(Symbols.chevron_right_rounded, color: pal.muted),
            ],
          ),
        ),
      ),
    );
  }
}
