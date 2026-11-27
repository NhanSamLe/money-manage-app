import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

const _palette = <Color>[
  Color(0xFF21896E),
  Color(0xFF1D4ED8),
  Color(0xFF7C3AED),
  Color(0xFFDB2777),
  Color(0xFFEA580C),
  Color(0xFF0E7490),
  Color(0xFF4D7C0F),
  Color(0xFFB45309),
];

/// Stable colour for a person's name (same name -> same colour on every run).
Color personColor(String? name) {
  final s = (name ?? '').trim().toLowerCase();
  if (s.isEmpty) return const Color(0xFF64748B);
  var h = 0;
  for (final u in s.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return _palette[h % _palette.length];
}

/// Person silhouette on a soft tinted circle, for contacts / lenders /
/// borrowers. Use instead of letter avatars.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, this.name, this.size = 40});
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = personColor(name);
    return Semantics(
      label: name,
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Symbols.person_rounded,
          fill: 1,
          color: c,
          size: size * 0.58,
        ),
      ),
    );
  }
}
