import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/router/router.dart';
import 'app/theme/moma_theme.dart';
import 'app/theme/theme_mode.dart';
import 'core/push.dart';
import 'core/storage/local_store.dart';
import 'core/config/app_config.dart';
import 'core/storage/secure_session_storage.dart';
import 'features/lock/lock_screen.dart';

// Keep the home-screen widget entry points (quick-entry sheet, background refresh) in the release snapshot:
// they are launched by Android directly, so nothing else in the app references them.
export 'features/widgets/entrypoints.dart' show quickEntryMain, widgetRefreshMain;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );
  Push.start();
  initialThemeMode = themeModeFromString(await LocalStore().themeMode());
  runApp(ProviderScope(retry: (_, _) => null, child: const MomaApp()));
}

class MomaApp extends ConsumerWidget {
  const MomaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'MoMa',
      debugShowCheckedModeBanner: false,
      theme: buildMomaTheme(),
      darkTheme: buildMomaTheme(Brightness.dark),
      // Sáng / Tối / Theo hệ thống (follows the phone's dark-mode setting and schedule).
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      // Long-press any text anywhere in the app to select and copy it.
      // App lock (PIN / biometric) draws above the router once the splash is done.
      builder: (context, child) => LockGate(
        router: ref.watch(routerProvider),
        child: SelectionArea(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
