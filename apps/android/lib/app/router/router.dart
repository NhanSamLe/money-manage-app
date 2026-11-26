import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/login_page.dart';
import '../../features/auth/setup_page.dart';
import '../../features/auth/welcome_page.dart';
import '../../features/home/home_shell.dart';
import '../../features/transactions/quick_entry_page.dart';

const _publicRoutes = {'/welcome', '/login', '/setup'};

/// Rebuilds the router whenever the Supabase auth state changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Stream<AuthState> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _sub;
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final refresh = _AuthRefresh(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = auth.currentSession != null;
      final loc = state.matchedLocation;
      if (!signedIn && !_publicRoutes.contains(loc)) return '/welcome';
      if (signedIn && _publicRoutes.contains(loc)) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomePage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/setup', builder: (_, _) => const SetupPage()),
      GoRoute(path: '/home', builder: (_, _) => const HomeShell()),
      GoRoute(path: '/quick-entry', builder: (_, _) => const QuickEntryPage()),
    ],
  );
});
