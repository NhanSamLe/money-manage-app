import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/outbox.dart';
import '../../core/storage/offline_cache.dart';
import '../../core/ui/header.dart';
import '../../core/ui/offline.dart';
import '../../core/widgets.dart';
import '../transactions/tx_attachments.dart';

/// What the offline copy holds right now (Settings → "Dữ liệu ngoại tuyến").
class OfflineInfo {
  const OfflineInfo({
    required this.lastSync,
    required this.cacheBytes,
    required this.fileBytes,
  });
  final DateTime? lastSync;
  final int cacheBytes;
  final int fileBytes;
}

final offlineInfoProvider = FutureProvider.autoDispose<OfflineInfo>((
  ref,
) async {
  final cache = ref.watch(offlineCacheProvider);
  return OfflineInfo(
    lastSync: await cache.lastSync(),
    cacheBytes: await cache.sizeBytes(),
    fileBytes: await ref.watch(attachmentFilesProvider).sizeBytes(),
  );
});

/// The process-wide read cache (overridable in tests).
final offlineCacheProvider = Provider<OfflineCache>(
  (_) => OfflineCache.instance,
);

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class OfflineDataPage extends ConsumerStatefulWidget {
  const OfflineDataPage({super.key});
  @override
  ConsumerState<OfflineDataPage> createState() => _OfflineDataPageState();
}

class _OfflineDataPageState extends ConsumerState<OfflineDataPage> {
  bool _busy = false;

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xóa bộ nhớ đệm?'),
        content: const Text(
          'Dữ liệu đã lưu để dùng offline và ảnh đã xem sẽ bị xóa khỏi máy; MoMa tải lại khi có mạng. '
          'Giao dịch và ảnh đang chờ đồng bộ được giữ nguyên.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Giữ lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await ref.read(offlineCacheProvider).clear();
    await ref.read(attachmentFilesProvider).clear();
    ref.invalidate(offlineInfoProvider);
    if (mounted) {
      setState(() => _busy = false);
      showSnack(context, 'Đã xóa bộ nhớ đệm.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final info = ref.watch(offlineInfoProvider);
    final net = ref.watch(netStateProvider);
    final box = ref.watch(outboxProvider);
    final uploads = ref.watch(uploadQueueProvider);
    Widget row(IconData icon, String label, String value) => ListTile(
      leading: Icon(icon, color: pal.accentInk),
      title: Text(label),
      trailing: Text(
        value,
        style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
      ),
    );
    return Scaffold(
      body: MomaPage(
        title: 'Dữ liệu ngoại tuyến',
        showBack: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: pal.tintSoft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'Có mạng thì MoMa dùng dữ liệu mới nhất từ máy chủ; mất mạng thì dùng bản đã lưu trên máy. '
                'Giao dịch nhập lúc offline và ảnh chứng từ được giữ lại và tự gửi khi có mạng. '
                'Dữ liệu ít thay đổi (danh mục, hồ sơ, mã QR nhận tiền) chỉ được tải lại vài giờ một lần.',
                style: TextStyle(color: pal.ink, height: 1.45, fontSize: 13.5),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: pal.surface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  row(
                    net.offline
                        ? Symbols.cloud_off_rounded
                        : Symbols.cloud_done_rounded,
                    'Trạng thái',
                    net.offline ? 'Đang offline' : 'Đang trực tuyến',
                  ),
                  row(
                    Symbols.schedule_rounded,
                    'Đồng bộ gần nhất',
                    info.value?.lastSync == null
                        ? 'Chưa có'
                        : updatedLabel(info.value!.lastSync)
                              .replaceFirst('cập nhật lúc ', ''),
                  ),
                  row(
                    Symbols.database_rounded,
                    'Dữ liệu đã lưu',
                    info.value == null
                        ? '…'
                        : formatBytes(info.value!.cacheBytes),
                  ),
                  row(
                    Symbols.image_rounded,
                    'Ảnh đã lưu',
                    info.value == null
                        ? '…'
                        : formatBytes(info.value!.fileBytes),
                  ),
                  row(
                    Symbols.sync_rounded,
                    'Đang chờ đồng bộ',
                    '${box.waiting} giao dịch · ${uploads.length} ảnh',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy || net.offline
                  ? null
                  : () async {
                      await ref.read(offlineSyncProvider).sync(reload: true);
                      ref.invalidate(offlineInfoProvider);
                      if (context.mounted) {
                        showSnack(context, 'Đã đồng bộ.');
                      }
                    },
              icon: const Icon(Symbols.sync_rounded),
              label: const Text('Đồng bộ ngay'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _clear,
              icon: const Icon(Symbols.delete_sweep_rounded),
              label: const Text('Xóa bộ nhớ đệm'),
            ),
          ],
        ),
      ),
    );
  }
}
