import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/push.dart';
import '../../features/classify/classify_page.dart';
import '../../features/settings/capacity_page.dart';
import '../../features/insights/insights_page.dart';
import '../../features/reminders/reminder_settings_page.dart';
import '../../core/ui/header.dart';
import '../../features/about/about_page.dart';
import '../../features/auth/login_page.dart';
import '../../features/banks/bank_connect_page.dart';
import '../../features/notifications/notifications.dart';
import '../../features/banks/receive_page.dart';
import '../../features/guide/guide_page.dart';
import '../../features/launch/intro_page.dart';
import '../../features/launch/splash_page.dart';
import '../../features/accounts/accounts_page.dart';
import '../../features/auth/onboarding_page.dart';
import '../../features/auth/setup_page.dart';
import '../../features/planning/planning_page.dart';
import '../../features/plans/plan_pages.dart';
import '../../features/profile/profile_page.dart';
import '../../features/auth/welcome_page.dart';
import '../../features/home/home_shell.dart';
import '../../features/imports/csv_import_page.dart';
import '../../features/export/export_page.dart';
import '../../features/settings/categories_page.dart';
import '../../features/auth/forgot_page.dart';
import '../../features/transactions/quick_entry_page.dart';
import '../../features/transactions/tx_detail_page.dart';
import '../../features/collect/collect.dart' show ReminderPage;
import '../../features/voice/voice_prefs.dart';

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
  final router = GoRouter(
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
            const _SubPage(title: 'Tài khoản & Đồng bộ', child: AccountsPage()),
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
      // Kế hoạch & Dự toán (pushes route here: "/plans", "/plans/event/:id", "/plans/life/:id").
      GoRoute(path: '/plans', redirect: (_, _) => '/planning?tab=4'),
      GoRoute(
        path: '/plans/event/:id',
        builder: (_, state) => EventPlanPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/plans/life/:id',
        builder: (_, state) => LifePlanPage(id: state.pathParameters['id']!),
      ),
      GoRoute(path: '/quick-entry', builder: (_, _) => const QuickEntryPage()),
      GoRoute(
        path: '/guide',
        pageBuilder: (_, state) => _fade(state, const GuidePage()),
      ),
      GoRoute(
        path: '/notifications',
        pageBuilder: (_, state) => _fade(state, const NotificationsPage()),
      ),
      GoRoute(
        path: '/banks',
        pageBuilder: (_, state) => _fade(state, const BankConnectPage()),
      ),
      GoRoute(
        path: '/receive',
        pageBuilder: (_, state) => _fade(state, const ReceivePage()),
      ),
      // Entry points for launcher shortcuts and the home-screen widget (moma://app/ai, ?voice=1 starts listening).
      GoRoute(
        path: '/ai',
        builder: (_, state) =>
            _TabEntry(2, voice: state.uri.queryParameters['voice'] == '1'),
      ),
      GoRoute(path: '/import', builder: (_, _) => const CsvImportPage()),
      GoRoute(path: '/export', builder: (_, _) => const ExportPage()),
      GoRoute(path: '/categories', builder: (_, _) => const CategoriesPage()),
      GoRoute(path: '/about', builder: (_, _) => const AboutPage()),
      GoRoute(
        path: '/tx/:id',
        builder: (_, state) => TxDetailPage(
          txId: state.pathParameters['id']!,
          initial: state.extra is MomaTx ? state.extra as MomaTx : null,
        ),
      ),
      GoRoute(
        path: '/forgot',
        pageBuilder: (_, state) => _fade(state, const ForgotPage()),
      ),
      GoRoute(path: '/insights', builder: (_, _) => const InsightsPage()),
      GoRoute(
        path: '/insights/:id',
        builder: (_, state) =>
            InsightDetailPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/reminders',
        builder: (_, _) => const ReminderSettingsPage(),
      ),
      GoRoute(path: '/profile', builder: (_, _) => const ProfilePage()),
      // "Chọn loại nhanh": unclear money (push "N khoản chưa rõ loại", bell, home banner).
      GoRoute(path: '/classify', builder: (_, _) => const QuickClassifyPage()),
      // Push "Dữ liệu đã dùng N% dung lượng miễn phí" (migration 022).
      GoRoute(
        path: '/settings/capacity',
        builder: (_, _) => const CapacityPage(),
      ),
      // Push "Nhắc Nam trả 535.000đ?" / "Sắp đến hạn trả…": message + QR / creditor bank (migration 019).
      GoRoute(
        path: '/debts/remind/:id',
        builder: (_, s) => ReminderPage(debtId: s.pathParameters['id']!),
      ),
    ],
  );
  // Notification taps navigate through this router (queued until the app is past splash/sign-in).
  Push.attachRouter(router);
  return router;
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

/// Selects a main tab and shows the shell (used by deep links such as the AI shortcut).
class _TabEntry extends ConsumerStatefulWidget {
  const _TabEntry(this.tab, {this.voice = false});
  final int tab;

  /// Opened from the widget's microphone: the assistant starts listening.
  final bool voice;
  @override
  ConsumerState<_TabEntry> createState() => _TabEntryState();
}

class _TabEntryState extends ConsumerState<_TabEntry> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(shellTabProvider.notifier).select(widget.tab);
      if (widget.voice) ref.read(voiceLaunchProvider.notifier).request();
      if (mounted) context.go('/home');
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}
