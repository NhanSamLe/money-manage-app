import 'dart:async';

import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The OneSignal app id is public by design (the REST key that sends pushes stays on the server).
const _oneSignalAppId = 'fce35790-4bdd-420a-aedb-0d41593e7894';

/// Push notifications for money in/out and reminders. The device is tied to the owner's account id, so the server
/// can address "this owner" without ever storing a device token. Every call is best effort: push must never break
/// sign-in or the app, so failures are swallowed.
class Push {
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    try {
      OneSignal.initialize(_oneSignalAppId);
      final auth = Supabase.instance.client.auth;
      _bind(auth.currentSession?.user.id);
      auth.onAuthStateChange.listen((e) => _bind(e.session?.user.id));
    } catch (_) {
      // Push is optional; ignore.
    }
  }

  static Future<void> _bind(String? userId) async {
    try {
      if (userId == null) {
        await OneSignal.logout();
        return;
      }
      await OneSignal.login(userId);
      // Android 13+ asks once; later calls are no-ops when already decided.
      await OneSignal.Notifications.requestPermission(true);
    } catch (_) {}
  }
}
