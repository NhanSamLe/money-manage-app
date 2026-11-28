import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'network/api_client.dart';
import 'storage/local_store.dart';

/// The OneSignal app id is public by design (the REST key that sends pushes stays on the server).
const _oneSignalAppId = 'fce35790-4bdd-420a-aedb-0d41593e7894';

/// Screens where a push route must wait: the launch/auth flow decides by itself where to go next.
const _notReadyRoutes = {
  '/splash',
  '/intro',
  '/welcome',
  '/login',
  '/register',
  '/forgot',
  '/onboarding',
};

/// Push notifications for money in/out, reminders and analyses. The device is tied to the owner's account id, so
/// the server can address "this owner" without ever storing a device token. Every call is best effort: push must
/// never break sign-in or the app, so failures are swallowed.
///
/// Payload `data`: `{type: "reminder", kind, route}` with action buttons `skip_<meal>` and `log`,
/// `{type: "insight", id, route}`, `{type: "bank_tx", ...}`. A tap (or "log") opens `route`; `skip_<meal>` marks
/// that meal as skipped today without opening anything else.
class Push {
  static bool _started = false;
  static GoRouter? _router;
  static String? _pendingRoute;

  /// Ticks after a meal was skipped from a notification, so on-screen "today" state can reload.
  static final remindersChanged = ValueNotifier<int>(0);

  /// Bumped after a routine answer was recorded from a push button (lists refresh on it).
  static final routineRecorded = ValueNotifier<int>(0);

  /// API used by notification actions. Replaceable in tests.
  @visibleForTesting
  static ApiClient Function() apiFactory = () => ApiClient(LocalStore());

  static void start() {
    if (_started) return;
    _started = true;
    try {
      OneSignal.initialize(_oneSignalAppId);
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        try {
          event.preventDefault();
          event.notification.display();
        } catch (_) {}
      });
      OneSignal.Notifications.addClickListener((event) {
        unawaited(
          handleClick(
            event.result.actionId,
            event.notification.additionalData ?? const {},
          ),
        );
      });
      final auth = Supabase.instance.client.auth;
      _bind(auth.currentSession?.user.id);
      auth.onAuthStateChange.listen((e) => _bind(e.session?.user.id));
    } catch (_) {
      // Push is optional; ignore.
    }
  }

  /// Gives push the app router. A route that arrived before (cold start from a notification) is opened once the
  /// app has left the splash / sign-in screens.
  static void attachRouter(GoRouter router) {
    if (identical(_router, router)) return;
    _router?.routerDelegate.removeListener(_flush);
    _router = router;
    router.routerDelegate.addListener(_flush);
    _flush();
  }

  /// Handles a notification tap or action button.
  static Future<void> handleClick(
    String? actionId,
    Map<String, dynamic> data,
  ) async {
    try {
      // "Sáng nay bạn ăn gì? [Bánh mì 20k]": rt_<slot>_<option-key> records that answer at once;
      // "Hôm qua bạn chưa ghi gửi xe? [Ghi]": rtm_<date> records the missed daily items; rtm_no does nothing.
      if (actionId != null && actionId.startsWith('rt_')) {
        final rest = actionId.substring(3);
        final cut = rest.indexOf('_');
        if (cut > 0) {
          final r = (data['routine'] as Map?)?.cast<String, dynamic>();
          await apiFactory().post('/ai/routine/record', {
            'slot': rest.substring(0, cut),
            'keys': [rest.substring(cut + 1)],
            'date': ?r?['date'] as String?,
          });
          routineRecorded.value++;
        }
        return;
      }
      if (actionId == 'rtm_no') return;
      if (actionId != null && actionId.startsWith('rtm_')) {
        await apiFactory().post('/ai/routine/record', {
          'slot': 'missed',
          'keys': ['all'],
          'date': actionId.substring(4),
        });
        routineRecorded.value++;
        return;
      }
      if (actionId != null && actionId.startsWith('skip_')) {
        final kind = actionId.substring(5);
        await apiFactory().post('/reminders/skip', {
          'kind': kind,
          'skip': true,
        });
        remindersChanged.value++;
        return;
      }
      final route = routeFor(data);
      if (route != null) openRoute(route);
    } catch (_) {
      // Best effort: a failed action must not crash the app.
    }
  }

  /// Where a notification should lead, or null when it carries no usable route.
  static String? routeFor(Map<String, dynamic> data) {
    final r = data['route'];
    if (r is String && r.startsWith('/')) return r;
    if (data['type'] == 'insight' && data['id'] != null) {
      return '/insights/${data['id']}';
    }
    if (data['type'] == 'reminder') return '/quick-entry';
    return null;
  }

  static void openRoute(String route) {
    _pendingRoute = route;
    _flush();
  }

  static void _flush() {
    final router = _router;
    final route = _pendingRoute;
    if (router == null || route == null) return;
    final String loc;
    try {
      loc = router.routerDelegate.currentConfiguration.uri.path;
    } catch (_) {
      return;
    }
    if (loc.isEmpty || _notReadyRoutes.contains(loc)) return;
    _pendingRoute = null;
    // Not inside the delegate's notification: navigate on the next microtask.
    scheduleMicrotask(() {
      try {
        router.push(route);
      } catch (_) {}
    });
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
