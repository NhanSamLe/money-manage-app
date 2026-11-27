import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/ui/header.dart';
import '../../features/auth/login_page.dart';
import '../../features/launch/intro_page.dart';
import '../../features/launch/splash_page.dart';
import '../../features/accounts/accounts_page.dart';
import '../../features/auth/onboarding_page.dart';
import '../../features/auth/setup_page.dart';
import '../../features/planning/planning_page.dart';
import '../../features/auth/welcome_page.dart';
import '../../features/home/home_shell.dart';
import '../../features/imports/csv_import_page.dart';
import '../../features/settings/categories_page.dart';
import '../../features/auth/forgot_page.dart';
import '../../features/transactions/quick_entry_page.dart';

const _publicRoutes = {
  '/splash',
  '/intro',
  '/welcome',
  '/login',
  '/register',
  '/forgot',
};

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

/// Fade-through transition used between launch/auth screens (calmer than the platform slide).
CustomTransitionPage<void> _fade(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      transitionsBuilder: (context, animation, secondary, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

final routerProvider = Provider<GoRouter>((ref) {
  final auth = Supabase.instance.client.auth;
  final refresh = _AuthRefresh(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: Listenable.merge([refresh, signupInProgress]),
    redirect: (context, state) {
      final signedIn = auth.currentSession != null;
      final loc = state.matchedLocation;
      if (!signedIn && !_publicRoutes.contains(loc)) return '/welcome';
      // The splash decides by itself (signed in -> app) after its minimum brand time.
      if (signedIn &&
          loc != '/splash' &&
          _publicRoutes.contains(loc) &&
          !signupInProgress.value) {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        pageBuilder: (_, state) => _fade(state, const SplashPage()),
      ),
      GoRoute(
        path: '/intro',
        pageBuilder: (_, state) => _fade(state, const IntroPage()),
      ),
      GoRoute(
        path: '/welcome',
        pageBuilder: (_, state) => _fade(state, const WelcomePage()),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (_, state) => _fade(state, const LoginPage()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (_, state) => _fade(state, const SetupPage()),
      ),
      GoRoute(
        path: '/onboarding',
        pageBuilder: (_, state) => _fade(state, const OnboardingPage()),
      ),
      GoRoute(
        path: '/accounts',
        builder: (_, _) =>
            const _SubPage(title: 'Tài khoản', child: AccountsPage()),
      ),
      GoRoute(
        path: '/planning',
        builder: (_, state) => _SubPage(
          title: 'Kế hoạch',
          child: PlanningPage(
            initialTab:
                int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
          ),
        ),
      ),
      GoRoute(
        path: '/home',
        pageBuilder: (_, state) => _fade(state, const HomeShell()),
      ),
      GoRoute(path: '/quick-entry', builder: (_, _) => const QuickEntryPage()),
      GoRoute(path: '/import', builder: (_, _) => const CsvImportPage()),
      GoRoute(path: '/categories', builder: (_, _) => const CategoriesPage()),
      GoRoute(
        path: '/forgot',
        pageBuilder: (_, state) => _fade(state, const ForgotPage()),
      ),
    ],
  );
});

/// Wraps a feature page that has its own body in the shared green header with a back button.
class _SubPage extends StatelessWidget {
  const _SubPage({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: MomaPage(title: title, showBack: true, child: child),
  );
}
