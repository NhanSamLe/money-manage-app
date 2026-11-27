import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/outbox.dart';
import '../../core/sheets.dart';
import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import '../../core/ui/nav.dart';
import '../assistant/assistant_page.dart';
import '../dashboard/dashboard_page.dart';
import '../dashboard/reports_page.dart';
import '../settings/settings_page.dart';
import '../transactions/transactions_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
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
    AssistantPage(),
    ReportsPage(),
    SettingsPage(),
  ];

  static const _items = <NavItem>[
    NavItem(Icons.home_outlined, 'Trang chủ'),
    NavItem(Icons.swap_horiz_rounded, 'Giao dịch'),
    NavItem(Icons.auto_awesome_outlined, 'Trợ lý AI'),
    NavItem(Icons.bar_chart_rounded, 'Báo cáo'),
    NavItem(Icons.settings_outlined, 'Cài đặt'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          const _OutboxBanner(),
          Expanded(
            child: IndexedStack(index: index, children: _pages),
          ),
        ],
      ),
      floatingActionButton: index <= 1
          ? FloatingActionButton(
              onPressed: () => context.push('/quick-entry'),
              tooltip: 'Nhập nhanh',
              backgroundColor: MomaColors.emerald,
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              child: const Icon(Icons.add_rounded, size: 32),
            )
          : null,
      bottomNavigationBar: MomaNavBar(
        items: _items,
        index: index,
        onSelect: (i) => ref.read(shellTabProvider.notifier).select(i),
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
