import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/moma_theme.dart';
import '../../../app/theme/palette.dart';
import '../../../core/network/api_client.dart';
import '../../../core/providers.dart';
import '../../../core/widgets.dart';
import '../../banks/bank_connect_page.dart' show bankAccountsProvider;
import '../../notify_capture/notify_capture_page.dart'
    show openNotifyCaptureSettings;
import 'sync_sources.dart';

String _when(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)} ${two(l.day)}/${two(l.month)}/${l.year}';
}

/// "Tích hợp" tab: state of SePay, notification access and push notifications.
class IntegrationsTab extends ConsumerStatefulWidget {
  const IntegrationsTab({super.key});
  @override
  ConsumerState<IntegrationsTab> createState() => _IntegrationsTabState();
}

class _IntegrationsTabState extends ConsumerState<IntegrationsTab> {
  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final r = await ref
          .read(apiProvider)
          .post('/banks/sepay/sync', <String, dynamic>{});
      refreshAll(ref);
      ref.invalidate(bankLinksProvider);
      if (mounted) {
        final n = r is Map ? (r['applied'] as num?)?.toInt() ?? 0 : 0;
        showSnack(
          context,
          n == 0
              ? 'Không có giao dịch mới'
              : 'Đã nhận $n giao dịch mới từ ngân hàng',
        );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sepay = ref.watch(bankAccountsProvider);
    final links = ref.watch(bankLinksProvider);
    final notify = ref.watch(notifySyncStateProvider);
    final push = ref.watch(pushPermissionProvider);

    final linkList = links.value ?? const <BankLink>[];
    final lastSync = linkList
        .map((l) => l.bankBalanceAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (m, t) => m == null || t.isAfter(m) ? t : m);
    final notConfigured =
        sepay.error is ApiException &&
        (sepay.error! as ApiException).code == 'BANK_NOT_CONFIGURED';

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(bankAccountsProvider)
          ..invalidate(bankLinksProvider)
          ..invalidate(notifySyncStateProvider)
          ..invalidate(pushPermissionProvider);
        await ref
            .read(bankLinksProvider.future)
            .catchError((_) => <BankLink>[]);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _StatusCard(
            icon: Symbols.account_balance_rounded,
            title: 'Đồng bộ ngân hàng (SePay)',
            status: sepay.isLoading
                ? null
                : notConfigured
                ? ('Chưa cấu hình', false)
                : sepay.hasError
                ? ('Không kết nối được', false)
                : (
                    linkList.isEmpty ? 'Chưa liên kết' : 'Đang hoạt động',
                    linkList.isNotEmpty,
                  ),
            lines: [
              if (sepay.hasValue)
                'Tài khoản trên SePay: ${sepay.value!.length}',
              if (sepay.hasError && !notConfigured)
                (sepay.error is ApiException
                    ? (sepay.error! as ApiException).message
                    : 'Không tải được danh sách tài khoản SePay.'),
              if (links.hasValue) 'Đã liên kết với MoMa: ${linkList.length}',
              if (lastSync != null) 'Cập nhật gần nhất: ${_when(lastSync)}',
            ],
            actions: [
              if (linkList.isNotEmpty)
                FilledButton.icon(
                  onPressed: _syncing ? null : _sync,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.sync_rounded),
                  label: const Text('Đồng bộ ngay'),
                ),
              OutlinedButton(
                onPressed: () async {
                  await context.push('/banks');
                  ref
                    ..invalidate(bankAccountsProvider)
                    ..invalidate(bankLinksProvider);
                },
                child: const Text('Quản lý liên kết'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StatusCard(
            icon: Symbols.notifications_rounded,
            title: 'Đọc thông báo Android',
            status: notify.isLoading
                ? null
                : notify.value?.granted == true
                ? ('Đã cấp quyền', true)
                : ('Chưa cấp quyền', false),
            lines: [
              if (notify.hasValue) ...[
                'Tài khoản đang tự ghi: ${notify.value!.map.values.toSet().length}',
                'Thông báo chờ xử lý: ${notify.value!.pending}',
                if (!notify.value!.autoRecord) 'Tự động ghi đang tắt',
              ],
            ],
            actions: [
              if (notify.value?.granted != true)
                FilledButton(
                  onPressed: () async {
                    await ref.read(notifyAccessProvider).openSettings();
                    ref.invalidate(notifySyncStateProvider);
                  },
                  child: const Text('Cấp quyền'),
                ),
              OutlinedButton(
                onPressed: () async {
                  await openNotifyCaptureSettings(context);
                  ref.invalidate(notifySyncStateProvider);
                },
                child: const Text('Thông báo chờ xử lý'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StatusCard(
            icon: Symbols.campaign_rounded,
            title: 'Thông báo đẩy',
            status: push.isLoading
                ? null
                : switch (push.value) {
                    true => ('Đã bật', true),
                    false => ('Chưa bật', false),
                    null => ('Không rõ', false),
                  },
            lines: const [
              'Báo khi có tiền vào, tiền ra từ ngân hàng, nhắc nhở và phân tích.',
            ],
            actions: [
              OutlinedButton(
                onPressed: () => context.push('/reminders'),
                child: const Text('Nhắc nhở & thông báo'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.lines,
    required this.actions,
  });
  final IconData icon;
  final String title;

  /// (label, ok); null while loading.
  final (String, bool)? status;
  final List<String> lines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final s = status;
    final c = s == null
        ? pal.muted
        : s.$2
        ? MomaColors.income
        : const Color(0xFFB7791F);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: MomaColors.emerald.withValues(alpha: 0.12),
                child: Icon(icon, color: MomaColors.emerald, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: pal.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (s == null)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Text(
                        s.$1,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l,
                  style: TextStyle(fontSize: 13, color: pal.muted, height: 1.4),
                ),
              ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Buttons are full width by theme (minimumSize: fromHeight), so they stack.
            for (final (i, b) in actions.indexed) ...[
              if (i > 0) const SizedBox(height: 8),
              b,
            ],
          ],
        ],
      ),
    );
  }
}
