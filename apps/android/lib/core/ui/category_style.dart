import 'package:material_ui/material_ui.dart';

import '../icons.dart';

import 'package:material_symbols_icons/symbols.dart';

/// Colour + glyph per category, matching the design's tinted circular avatars.
class CategoryStyle {
  const CategoryStyle(this.icon, this.color);
  final IconData icon;
  final Color color;
}

CategoryStyle categoryStyle(String? key) {
  switch (key) {
    case 'restaurant':
      return const CategoryStyle(Symbols.restaurant_rounded, Color(0xFFFF8A3D));
    case 'directions_car':
      return const CategoryStyle(
        Symbols.directions_car_rounded,
        Color(0xFF2F80ED),
      );
    case 'home':
      return const CategoryStyle(Symbols.home_rounded, Color(0xFF2F80ED));
    case 'receipt_long':
      return const CategoryStyle(
        Symbols.receipt_long_rounded,
        Color(0xFF3B82F6),
      );
    case 'shopping_bag':
      return const CategoryStyle(
        Symbols.shopping_bag_rounded,
        Color(0xFF8B5CF6),
      );
    case 'sports_esports':
      return const CategoryStyle(
        Symbols.sports_esports_rounded,
        Color(0xFF7C4DFF),
      );
    case 'favorite':
      return const CategoryStyle(Symbols.favorite_rounded, Color(0xFFEF4444));
    case 'school':
      return const CategoryStyle(Symbols.school_rounded, Color(0xFF6366F1));
    case 'payments':
      return const CategoryStyle(
        Symbols.account_balance_wallet_rounded,
        Color(0xFF1B8A5A),
      );
    case 'redeem':
      return const CategoryStyle(Symbols.redeem_rounded, Color(0xFFEC4899));
    case 'savings':
      return const CategoryStyle(Symbols.savings_rounded, Color(0xFF1B8A5A));
    case 'add_card':
      return const CategoryStyle(Symbols.add_card_rounded, Color(0xFF1B8A5A));
    default:
      return CategoryStyle(categoryIcon(key), const Color(0xFF64748B));
  }
}

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    this.iconKey,
    this.size = 44,
    this.iconData,
    this.color,
  });
  final String? iconKey;
  final double size;
  final IconData? iconData;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = categoryStyle(iconKey);
    final c = color ?? s.color;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(iconData ?? s.icon, color: c, size: size * 0.5),
    );
  }
}
