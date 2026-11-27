import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/router/router.dart';
import 'app/theme/moma_theme.dart';
import 'app/theme/theme_mode.dart';
import 'core/storage/local_store.dart';
import 'core/config/app_config.dart';
import 'core/storage/secure_session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );
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
      routerConfig: ref.watch(routerProvider),
    );
  }
}
