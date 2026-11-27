import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/local_store.dart';
import '../widgets/entrypoints.dart' show initWidgetBackend;
import '../widgets/widget_sync.dart';
import 'capture_engine.dart';
import 'notify_capture_service.dart';
import 'share_capture.dart';

/// Background recording (BackgroundCapture in CaptureBridge.kt): the listener queued a notification; record every
/// pending one through the zero-tap path without opening MoMa, refresh the widgets, then signal "done". Anything
/// that fails (offline, signed out) stays queued for the next app start.
@pragma('vm:entry-point')
Future<void> captureMain() async {
  try {
    await initWidgetBackend();
    if (Supabase.instance.client.auth.currentSession != null) {
      final api = ApiClient(LocalStore());
      const channel = NotifyCaptureChannel();
      final items = await channel.pending();
      final out = await runCapture(
        items: items,
        ledger: ApiCaptureLedger(api),
        prefs: NotifyCapturePrefs(),
      );
      await channel.ack(out.acked);
      if (out.recorded > 0) {
        await WidgetSync.refreshWithApi(api)
            .timeout(const Duration(seconds: 8), onTimeout: () {});
      }
    }
  } catch (_) {
    // The queue keeps everything that was not acknowledged.
  }
  try {
    await const MethodChannel('moma/notify_capture').invokeMethod<void>('done');
  } catch (_) {}
}

/// Share target (ShareReceiveActivity): args = [text | image | none, value].
@pragma('vm:entry-point')
Future<void> shareEntryMain(List<String> args) async {
  await initWidgetBackend();
  runApp(
    ProviderScope(
      retry: (_, _) => null,
      child: ShareCaptureApp(
        kind: args.isNotEmpty ? args[0] : 'none',
        value: args.length > 1 ? args[1] : '',
      ),
    ),
  );
}
