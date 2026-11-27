import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';

class NavItem {
  const NavItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Bottom navigation from the design: white rounded bar, selected item in a mint pill.
class MomaNavBar extends StatelessWidget {
  const MomaNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
  });
  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.pal.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x1A073D33),
            blurRadius: 18,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    label: items[i].label,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => onSelect(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: i == index
                              ? context.pal.tint
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              items[i].icon,
                              size: 26,
                              color: i == index
                                  ? MomaColors.emerald
                                  : context.pal.muted,
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                items[i].label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: i == index
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: i == index
                                      ? MomaColors.emerald
                                      : context.pal.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
