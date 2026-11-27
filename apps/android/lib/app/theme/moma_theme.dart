import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand tokens from the MoMa design: Forest, Emerald, Mint, Cloud.
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

ThemeData buildMomaTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: MomaColors.emerald,
    primary: MomaColors.emerald,
    surface: Colors.white,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: MomaColors.cloud,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: Color(0xFFDDE6E2)),
  );
  return base.copyWith(
    textTheme: GoogleFonts.beVietnamProTextTheme(base.textTheme),
    appBarTheme: const AppBarTheme(
      backgroundColor: MomaColors.cloud,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: MomaColors.forest,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MomaColors.emerald,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: MomaColors.forest,
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: MomaColors.mint),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: border,
      enabledBorder: border,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}
