import 'package:material_ui/material_ui.dart';

/// Surface/ink tokens that change with Light/Dark mode. Brand colours (Forest, Emerald, Mint, income, expense)
/// stay in [MomaColors]; everything that is a background, divider or body text colour comes from here.
@immutable
class Pal extends ThemeExtension<Pal> {
  const Pal({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.line,
    required this.lineSoft,
    required this.ink,
    required this.muted,
    required this.tint,
    required this.tintSoft,
    required this.bubble,
    required this.hint,
  });

  /// Page background behind cards.
  final Color bg;

  /// Cards, sheets, dialogs, inputs.
  final Color surface;

  /// Grouped rows / chips sitting on a surface.
  final Color surfaceAlt;
  final Color line;
  final Color lineSoft;
  final Color ink;
  final Color muted;

  /// Selected pill / highlighted chip background.
  final Color tint;
  final Color tintSoft;

  /// Assistant chat bubble.
  final Color bubble;
  final Color hint;

  static const light = Pal(
    bg: Color(0xFFF5F7F6),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF3F7F5),
    line: Color(0xFFDDE6E2),
    lineSoft: Color(0xFFEEF2F0),
    ink: Color(0xFF0B2A1F),
    muted: Color(0xFF5B6B64),
    tint: Color(0xFFD7F0E1),
    tintSoft: Color(0xFFEAF7F0),
    bubble: Color(0xFFE3F5EC),
    hint: Color(0xFF8A9A92),
  );

  static const dark = Pal(
    bg: Color(0xFF0B1511),
    surface: Color(0xFF15231E),
    surfaceAlt: Color(0xFF1C2D27),
    line: Color(0xFF2C4037),
    lineSoft: Color(0xFF22342D),
    ink: Color(0xFFE8F2ED),
    muted: Color(0xFF9DB1A8),
    tint: Color(0xFF1F4437),
    tintSoft: Color(0xFF18322A),
    bubble: Color(0xFF1B3329),
    hint: Color(0xFF6F837A),
  );

  @override
  Pal copyWith() => this;

  @override
  Pal lerp(ThemeExtension<Pal>? other, double t) {
    if (other is! Pal) return this;
    return Pal(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineSoft: Color.lerp(lineSoft, other.lineSoft, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
      tintSoft: Color.lerp(tintSoft, other.tintSoft, t)!,
      bubble: Color.lerp(bubble, other.bubble, t)!,
      hint: Color.lerp(hint, other.hint, t)!,
    );
  }
}

extension PalContext on BuildContext {
  /// Palette of the active theme; falls back to the brightness default when a bare ThemeData is used (tests).
  Pal get pal {
    final t = Theme.of(this);
    return t.extension<Pal>() ??
        (t.brightness == Brightness.dark ? Pal.dark : Pal.light);
  }
}
