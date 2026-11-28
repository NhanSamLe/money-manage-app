import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../features/banks/bank_connect_page.dart' show bankAccountsProvider;
import '../../features/transactions/tx_attachments.dart';
import '../outbox.dart';
import '../planning_providers.dart';
import '../providers.dart';
import '../storage/offline_cache.dart';

/// Online/offline as seen by the last API calls (D-021).
class NetStateNotifier extends Notifier<NetState> {
  @override
  NetState build() {
    void listener() => state = NetStatus.notifier.value;
    NetStatus.notifier.addListener(listener);
    ref.onDispose(() => NetStatus.notifier.removeListener(listener));
    return NetStatus.notifier.value;
  }
}

final netStateProvider = NotifierProvider<NetStateNotifier, NetState>(
  NetStateNotifier.new,
);

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "cập nhật lúc 08:15" / "cập nhật lúc 08:15 27/11" for older data.
String updatedLabel(DateTime? at, [DateTime? now]) {
  if (at == null) return 'dùng dữ liệu đã lưu';
  final n = now ?? DateTime.now();
  final sameDay = at.year == n.year && at.month == n.month && at.day == n.day;
  return sameDay
      ? 'cập nhật lúc ${_hm(at)}'
      : 'cập nhật lúc ${_hm(at)} ${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')}';
}

/// Calm strip shown while offline: what is on screen and how old it is. Nothing turns red for lack of network.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(netStateProvider);
    if (!net.offline) return const SizedBox.shrink();
    final pal = context.pal;
    return Material(
      color: pal.warnBg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Icon(Symbols.cloud_off_rounded, size: 18, color: pal.warnInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Đang offline · ${updatedLabel(net.dataAt)}',
                  style: TextStyle(
                    color: pal.warnInk,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps the phone in step without the owner doing anything: when the connection comes back (or the app returns
/// to the front) it sends the outbox and queued pictures, then reloads what is on screen from the server.
class OfflineSync {
  OfflineSync(this.ref);
  final Ref ref;
  Timer? _timer;
  bool _wasOffline = NetStatus.offline;
  bool _running = false;
  AppLifecycleListener? _life;

  void start() {
    NetStatus.notifier.addListener(_onNet);
    _life = AppLifecycleListener(onResume: () => unawaited(sync()));
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  void dispose() {
    NetStatus.notifier.removeListener(_onNet);
    _life?.dispose();
    _timer?.cancel();
  }

  void _onNet() {
    final offline = NetStatus.offline;
    if (_wasOffline && !offline) unawaited(sync(reload: true));
    _wasOffline = offline;
  }

  /// While offline (or with work waiting), try again every 20 s; a success flips the state back to online.
  Future<void> _tick() async {
    final box = ref.read(outboxProvider);
    final uploads = ref.read(uploadQueueProvider);
    if (!NetStatus.offline && box.waiting == 0 && uploads.isEmpty) return;
    if (box.waiting == 0 && uploads.isEmpty) {
      try {
        await ref.read(apiProvider).get('/health'); // cheap probe
      } catch (_) {}
      return;
    }
    await sync();
  }

  Future<void> sync({bool reload = false}) async {
    if (_running) return;
    _running = true;
    try {
      final sent = await ref.read(outboxProvider.notifier).flush();
      final uploaded = await ref.read(uploadQueueProvider.notifier).flush();
      if (reload || sent > 0 || uploaded > 0) _reload();
    } catch (_) {
      // Still offline: the next tick tries again.
    } finally {
      _running = false;
    }
  }

  void _reload() {
    ref
      ..invalidate(accountsProvider)
      ..invalidate(summaryProvider)
      ..invalidate(transactionsProvider)
      ..invalidate(categoriesProvider)
      ..invalidate(profileProvider)
      ..invalidate(contactsProvider)
      ..invalidate(debtsProvider)
      ..invalidate(goalsProvider)
      ..invalidate(budgetsProvider)
      ..invalidate(recurringProvider)
      ..invalidate(bankAccountsProvider);
  }
}

/// Watched by the home shell so the sync loop lives as long as the signed-in app.
final offlineSyncProvider = Provider<OfflineSync>((ref) {
  final s = OfflineSync(ref)..start();
  ref.onDispose(s.dispose);
  return s;
});

/// Shown by [ErrorView] for a read that failed only because there is no connection and nothing is saved yet.
class OfflineEmpty extends StatelessWidget {
  const OfflineEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.cloud_off_rounded, size: 44, color: pal.muted),
            const SizedBox(height: 12),
            Text(
              'Đang offline',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Phần này chưa được lưu trên máy. MoMa sẽ tự tải khi có mạng.',
              textAlign: TextAlign.center,
              style: TextStyle(color: pal.muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
