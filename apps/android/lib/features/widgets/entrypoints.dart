import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/local_store.dart';
import '../../core/storage/secure_session_storage.dart';
import 'quick_entry_overlay.dart';
import 'widget_sync.dart';

/// Same backend setup as `main()` (shared config, secure session storage), without push / router.
Future<void> initWidgetBackend() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );
  // The stored session is restored asynchronously; make sure the access token is usable before calling the API.
  final auth = Supabase.instance.client.auth;
  final s = auth.currentSession;
  if (s != null && s.isExpired) {
    try {
      await auth.refreshSession();
    } catch (_) {}
  }
}

/// Entry point of the translucent quick-entry sheet (QuickEntryActivity). args[0] = expense | income.
@pragma('vm:entry-point')
Future<void> quickEntryMain(List<String> args) async {
  await initWidgetBackend();
  final income = args.isNotEmpty && args.first == 'income';
  runApp(
    ProviderScope(
      retry: (_, _) => null,
      child: QuickEntryOverlayApp(income: income),
    ),
  );
}

/// Entry point of the background widget refresh (WidgetActionReceiver): fetch, push, signal done.
@pragma('vm:entry-point')
Future<void> widgetRefreshMain() async {
  try {
    await initWidgetBackend();
    await WidgetSync.refreshWithApi(ApiClient(LocalStore()));
  } catch (_) {
    // The receiver restores the widgets either way.
  }
  try {
    await WidgetSync.channel.invokeMethod<void>('done');
  } catch (_) {}
}
