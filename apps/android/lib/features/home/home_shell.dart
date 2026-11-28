import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/outbox.dart';
import '../../core/sheets.dart';
import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import '../../core/ui/nav.dart';
import '../../core/ui/offline.dart';
import '../assistant/assistant_page.dart';
import '../dashboard/dashboard_page.dart';
import '../dashboard/reports_page.dart';
import '../notify_capture/notify_capture_page.dart';
import '../settings/settings_page.dart';
import '../transactions/transactions_page.dart';
import '../update/update_sheet.dart';
import '../widgets/widgets.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme/palette.dart';

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
      // Bank/e-wallet notifications captured while the app was closed: record those with a chosen account.
      if (mounted) {
        try {
          await autoRecordNotifications(ref);
        } catch (_) {}
      }
      if (mounted) WidgetSync.refresh(ref).ignore(); // home-screen widget data
    });
    // In-app update check (at most once per 12 hours), after the first screen has settled.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) maybeAutoCheckForUpdate(context).ignore();
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
    NavItem(Symbols.home_rounded, 'Trang chủ'),
    NavItem(Symbols.swap_horiz_rounded, 'Giao dịch'),
    NavItem(Symbols.auto_awesome_rounded, 'Trợ lý AI'),
    NavItem(Symbols.bar_chart_rounded, 'Báo cáo'),
    NavItem(Symbols.settings_rounded, 'Cài đặt'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    // Offline sync loop: sends the outbox and queued pictures as soon as the connection is back.
    ref.watch(offlineSyncProvider);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          const OfflineBanner(),
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
              child: const Icon(Symbols.add_rounded, size: 32),
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
      color: box.failed > 0 ? context.pal.dangerBg : context.pal.warnBg,
      child: ListTile(
        dense: true,
        leading: Icon(
          box.syncing ? Symbols.sync_rounded : Symbols.cloud_off_rounded,
          color: box.failed > 0 ? MomaColors.expense : context.pal.warnInk,
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
