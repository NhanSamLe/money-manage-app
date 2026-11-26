import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/outbox.dart';
import '../../core/sheets.dart';
import '../../app/theme/moma_theme.dart';
import '../accounts/accounts_page.dart';
import '../dashboard/dashboard_page.dart';
import '../planning/planning_page.dart';
import '../settings/settings_page.dart';
import '../transactions/transactions_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Load queued offline commands and try to send them as soon as the app opens.
    Future.microtask(() async {
      await ref.read(outboxProvider.notifier).load();
      await ref.read(outboxProvider.notifier).flush();
    });
  }

  static const _pages = <Widget>[
    DashboardPage(),
    TransactionsPage(),
    AccountsPage(),
    PlanningPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _OutboxBanner(),
            Expanded(
              child: IndexedStack(index: _index, children: _pages),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/quick-entry'),
        tooltip: 'Nhập nhanh',
        child: const Icon(Icons.add_rounded),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Tổng quan',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_rounded),
            label: 'Giao dịch',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet_rounded),
            label: 'Tài khoản',
          ),
          NavigationDestination(
            icon: Icon(Icons.track_changes_outlined),
            selectedIcon: Icon(Icons.track_changes_rounded),
            label: 'Kế hoạch',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Cài đặt',
          ),
        ],
      ),
    );
  }
}

/// Shows queued offline commands. Rejected ones stay visible until the owner discards them (no silent loss).
class _OutboxBanner extends ConsumerWidget {
  const _OutboxBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(outboxProvider);
    if (box.items.isEmpty) return const SizedBox.shrink();
    final parts = <String>[
      if (box.waiting > 0) '${box.waiting} giao dịch chờ đồng bộ',
      if (box.failed > 0) '${box.failed} lỗi cần xử lý',
    ];
    return Material(
      color: box.failed > 0 ? const Color(0xFFFDE8E8) : const Color(0xFFFFF4D6),
      child: ListTile(
        dense: true,
        leading: Icon(
          box.syncing ? Icons.sync_rounded : Icons.cloud_off_rounded,
          color: box.failed > 0 ? MomaColors.expense : MomaColors.forest,
        ),
        title: Text(parts.join(' · ')),
        trailing: TextButton(
          onPressed: box.syncing
              ? null
              : () => showFormSheet<void>(context, (_) => const _OutboxSheet()),
          child: const Text('Xem'),
        ),
      ),
    );
  }
}

class _OutboxSheet extends ConsumerWidget {
  const _OutboxSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(outboxProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hàng đợi đồng bộ',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        for (final c in box.items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${c.type} · ${c.payload['amount'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(c.error ?? 'Đang chờ mạng'),
            trailing: c.error == null
                ? null
                : TextButton(
                    onPressed: () =>
                        ref.read(outboxProvider.notifier).discard(c.commandId),
                    child: const Text('Bỏ'),
                  ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: box.syncing
              ? null
              : () => ref.read(outboxProvider.notifier).flush(),
          child: const Text('Đồng bộ ngay'),
        ),
      ],
    );
  }
}
