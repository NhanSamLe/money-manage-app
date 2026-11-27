import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/providers.dart';

/// Value loaded from storage in `main()` before the first frame so the app never flashes the wrong theme.
ThemeMode initialThemeMode = ThemeMode.system;

ThemeMode themeModeFromString(String v) => switch (v) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String themeModeToString(ThemeMode m) => switch (m) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => initialThemeMode;

  Future<void> set(ThemeMode m) async {
    state = m;
    await ref.read(storeProvider).setThemeMode(themeModeToString(m));
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
