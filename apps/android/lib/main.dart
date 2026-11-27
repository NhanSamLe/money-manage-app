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
import 'features/notify_capture/entrypoints.dart' as capture_entry;
import 'features/widgets/entrypoints.dart' as widget_entry;

// Secondary Dart entry points started by Android directly (QuickEntryActivity, WidgetActionReceiver,
// BackgroundCapture, ShareReceiveActivity). They MUST be declared in this root library: in release (AOT) builds
// a lookup by library URI ("package:moma/features/.../entrypoints.dart") fails with "Could not resolve main
// entrypoint function", leaving an empty window. The Kotlin side therefore starts them without a library URI.
@pragma('vm:entry-point')
Future<void> quickEntryMain(List<String> args) =>
    widget_entry.quickEntryMain(args);

@pragma('vm:entry-point')
Future<void> widgetRefreshMain() => widget_entry.widgetRefreshMain();

@pragma('vm:entry-point')
Future<void> captureMain() => capture_entry.captureMain();

@pragma('vm:entry-point')
Future<void> shareEntryMain(List<String> args) =>
    capture_entry.shareEntryMain(args);

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
