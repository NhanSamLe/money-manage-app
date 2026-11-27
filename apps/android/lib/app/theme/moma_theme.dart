import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

import 'palette.dart';

/// Brand tokens from the MoMa design: Forest, Emerald, Mint, Cloud (identical in Light and Dark).
/// Background / divider / body-text colours are theme dependent and live in [Pal] (`context.pal`).
class MomaColors {
  const MomaColors._();
  static const forest = Color(0xFF073D33);
  static const emerald = Color(0xFF21896E);
  static const mint = Color(0xFFB1E5B6);
  static const cloud = Color(0xFFF5F7F6);
  static const income = Color(0xFF1B8A5A);
  static const expense = Color(0xFFD64545);
  static const muted = Color(0xFF5B6B64);
  static const ink = Color(0xFF0B2A1F);
}

ThemeData buildMomaTheme([Brightness brightness = Brightness.light]) {
  final dark = brightness == Brightness.dark;
  final pal = dark ? Pal.dark : Pal.light;
  final primary = dark ? const Color(0xFF2FA383) : MomaColors.emerald;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: MomaColors.emerald,
        brightness: brightness,
      ).copyWith(
        primary: primary,
        onPrimary: Colors.white,
        surface: pal.surface,
        onSurface: pal.ink,
        onSurfaceVariant: pal.muted,
        outline: pal.line,
        outlineVariant: pal.lineSoft,
        error: MomaColors.expense,
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: pal.bg,
    canvasColor: pal.surface,
    dividerColor: pal.lineSoft,
    extensions: [pal],
  );
  OutlineInputBorder outline(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide(color: c, width: w),
  );
  final border = outline(pal.line);
  return base.copyWith(
    textTheme: GoogleFonts.beVietnamProTextTheme(base.textTheme)
        .apply(bodyColor: pal.ink, displayColor: pal.ink),
    appBarTheme: AppBarTheme(
      backgroundColor: pal.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: pal.ink,
    ),
    dividerTheme: DividerThemeData(color: pal.lineSoft, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: pal.surface,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: pal.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: dark ? MomaColors.mint : MomaColors.forest,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        side: BorderSide(color: dark ? pal.line : MomaColors.mint),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        minimumSize: const Size(48, 44),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: pal.surface,
      border: border,
      enabledBorder: border,
      disabledBorder: outline(pal.lineSoft),
      focusedBorder: outline(primary, 1.6),
      errorBorder: outline(MomaColors.expense),
      focusedErrorBorder: outline(MomaColors.expense, 1.6),
      hintStyle: TextStyle(color: pal.hint),
      errorStyle: const TextStyle(
        color: MomaColors.expense,
        fontWeight: FontWeight.w500,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    cardTheme: CardThemeData(
      color: pal.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2C4037) : MomaColors.forest,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
