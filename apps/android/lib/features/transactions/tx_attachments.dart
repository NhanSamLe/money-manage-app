import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';

/// One receipt / transfer screenshot attached to a transaction (migration 013). The picture itself lives in
/// Cloudflare R2 behind the API; only its id and metadata come with the list.
class TxAttachment {
  const TxAttachment({
    required this.id,
    required this.txId,
    required this.contentType,
    required this.sizeBytes,
    required this.createdAt,
  });

  factory TxAttachment.fromJson(Map<String, dynamic> j) => TxAttachment(
    id: '${j['id']}',
    txId: '${j['tx_id']}',
    contentType: '${j['content_type'] ?? 'image/jpeg'}',
    sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse('${j['created_at']}')?.toLocal() ?? DateTime.now(),
  );

  final String id;
  final String txId;
  final String contentType;
  final int sizeBytes;
  final DateTime createdAt;

  String get extension => switch (contentType) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    _ => 'jpg',
  };
}

const kMaxAttachments = 10;

/// Pictures of a transaction, including those attached to earlier versions before an edit.
final txAttachmentsProvider = FutureProvider.autoDispose
    .family<List<TxAttachment>, String>((ref, txId) async {
      final data = await ref
          .watch(apiProvider)
          .get('/transactions/$txId/attachments');
      return [
        for (final e in (data as List? ?? const []))
          TxAttachment.fromJson((e as Map).cast<String, dynamic>()),
      ];
    });

/// Picture bytes, kept for the session (an id never changes content), so scrolling back costs nothing.
final attachmentBytesProvider = FutureProvider.family<Uint8List, String>((
  ref,
  id,
) async {
  final bytes = await ref.watch(apiProvider).getBytes('/attachments/$id');
  return Uint8List.fromList(bytes);
});

/// Image type from the first bytes (what the server checks too).
String? sniffImageType(List<int> b) {
  if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) {
    return 'image/jpeg';
  }
  if (b.length >= 4 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// "Ảnh chứng từ" card on the transaction detail page: thumbnails, add (camera / gallery, several at once),
/// full-screen viewer with share and delete. Pictures are shrunk on the phone (max 1600 px, JPEG ~75%) first.
class TxAttachmentsSection extends ConsumerStatefulWidget {
  const TxAttachmentsSection({
    super.key,
    required this.txId,
    this.canAdd = true,
  });
  final String txId;
  final bool canAdd;

  @override
  ConsumerState<TxAttachmentsSection> createState() =>
      _TxAttachmentsSectionState();
}

class _TxAttachmentsSectionState extends ConsumerState<TxAttachmentsSection> {
  int _uploading = 0;

  Future<void> _add(int current) async {
    final source = await showChoiceSheet<ImageSource>(
      context,
      title: 'Thêm ảnh chứng từ',
      options: const [
        ChoiceOption(
          value: ImageSource.camera,
          label: 'Chụp ảnh',
          icon: Symbols.photo_camera_rounded,
        ),
        ChoiceOption(
          value: ImageSource.gallery,
          label: 'Chọn từ thư viện',
          icon: Symbols.photo_library_rounded,
        ),
      ],
    );
    if (source == null || !mounted) return;
    final room = kMaxAttachments - current;
    List<XFile> files;
    try {
      final picker = ImagePicker();
      if (source == ImageSource.camera) {
        final f = await picker.pickImage(
          source: source,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 75,
        );
        files = f == null ? const [] : [f];
      } else {
        files = await picker.pickMultiImage(
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 75,
          limit: room > 1 ? room : null,
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      final denied = e.code.contains('denied') || e.code.contains('permission');
      await showErrorDialog(
        context,
        denied
            ? 'MoMa chưa có quyền dùng máy ảnh hoặc thư viện ảnh. Bạn bật quyền trong Cài đặt điện thoại rồi thử lại.'
            : 'Không mở được ảnh (${e.code}). Bạn thử lại.',
      );
      return;
    }
    if (files.isEmpty || !mounted) return;
    if (files.length > room) {
      files = files.take(room).toList();
      showSnack(context, 'Mỗi giao dịch giữ tối đa $kMaxAttachments ảnh.');
    }
    await _upload(files);
  }

  Future<void> _upload(List<XFile> files) async {
    final api = ref.read(apiProvider);
    setState(() => _uploading += files.length);
    var done = 0;
    String? error;
    for (final f in files) {
      try {
        final bytes = await f.readAsBytes();
        final type = sniffImageType(bytes);
        if (type == null) {
          error = 'Ảnh không đúng định dạng (chỉ nhận JPEG, PNG, WebP).';
        } else {
          await api.postBytes(
            '/transactions/${widget.txId}/attachments',
            bytes,
            contentType: type,
          );
          done++;
        }
      } on ApiException catch (e) {
        error = e.message;
      } catch (_) {
        error = 'Không đọc được ảnh. Bạn thử ảnh khác.';
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
    ref.invalidate(txAttachmentsProvider(widget.txId));
    if (!mounted) return;
    if (error != null) {
      await showErrorDialog(
        context,
        done > 0 ? 'Đã lưu $done ảnh. Ảnh còn lại lỗi: $error' : error,
      );
    } else {
      showSnack(context, done == 1 ? 'Đã lưu ảnh.' : 'Đã lưu $done ảnh.');
    }
  }

  Future<void> _open(List<TxAttachment> items, int index) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AttachmentViewer(items: items, initial: index),
      ),
    );
    if (deleted == true) ref.invalidate(txAttachmentsProvider(widget.txId));
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final async = ref.watch(txAttachmentsProvider(widget.txId));
    final items = async.value ?? const <TxAttachment>[];
    final canAdd = widget.canAdd && items.length + _uploading < kMaxAttachments;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.receipt_long_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  items.isEmpty
                      ? 'Ảnh chứng từ'
                      : 'Ảnh chứng từ (${items.length})',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                    color: pal.ink,
                  ),
                ),
              ),
              if (async.isLoading && items.isNotEmpty)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Lưu hóa đơn, ảnh chuyển khoản làm bằng chứng. Ảnh được nén và lưu riêng tư, chỉ bạn xem được.',
            style: TextStyle(fontSize: 12.5, color: pal.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (async.hasError && items.isEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    async.error is ApiException
                        ? (async.error as ApiException).message
                        : 'Không tải được ảnh.',
                    style: TextStyle(color: pal.muted, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(txAttachmentsProvider(widget.txId)),
                  child: const Text('Thử lại'),
                ),
              ],
            )
          else
            GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final (i, a) in items.indexed)
                  _Thumb(attachment: a, onTap: () => _open(items, i)),
                for (var i = 0; i < _uploading; i++) const _UploadingTile(),
                if (canAdd && !async.isLoading)
                  _AddTile(onTap: () => _add(items.length + _uploading)),
                if (async.isLoading && items.isEmpty) const _UploadingTile(),
              ],
            ),
        ],
      ),
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb({required this.attachment, required this.onTap});
  final TxAttachment attachment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final bytes = ref.watch(attachmentBytesProvider(attachment.id));
    return Material(
      color: pal.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: bytes.when(
          data: (b) => Image.memory(
            b,
            fit: BoxFit.cover,
            cacheWidth: 360,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                Icon(Symbols.broken_image_rounded, color: pal.muted),
          ),
          loading: () => const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (_, _) => Icon(Symbols.cloud_off_rounded, color: pal.muted),
        ),
      ),
    );
  }
}

class _UploadingTile extends StatelessWidget {
  const _UploadingTile();
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: context.pal.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Material(
      color: pal.tintSoft,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.add_a_photo_rounded, color: pal.accentInk, size: 26),
            const SizedBox(height: 6),
            Text(
              'Thêm ảnh',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: pal.accentInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen pictures: swipe between them, pinch to zoom, share or delete. Pops `true` after a delete.
class AttachmentViewer extends ConsumerStatefulWidget {
  const AttachmentViewer({
    super.key,
    required this.items,
    required this.initial,
  });
  final List<TxAttachment> items;
  final int initial;

  @override
  ConsumerState<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends ConsumerState<AttachmentViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late List<TxAttachment> _items = [...widget.items];
  late int _index = widget.initial;
  bool _changed = false;
  bool _busy = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  TxAttachment get _current => _items[_index];

  Future<void> _share() async {
    final a = _current;
    try {
      final bytes = await ref.read(attachmentBytesProvider(a.id).future);
      final name = 'MoMa-chung-tu-${a.id.substring(0, 8)}.${a.extension}';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, name: name, mimeType: a.contentType)],
          fileNameOverrides: [name],
        ),
      );
    } catch (_) {
      if (mounted) await showErrorDialog(context, 'Không chia sẻ được ảnh.');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xóa ảnh này?'),
        content: const Text('Ảnh sẽ bị xóa vĩnh viễn khỏi kho lưu trữ.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Giữ lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            style: TextButton.styleFrom(foregroundColor: MomaColors.expense),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).delete('/attachments/${_current.id}');
      _changed = true;
      if (!mounted) return;
      if (_items.length == 1) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _items = [..._items]..removeAt(_index);
        if (_index >= _items.length) _index = _items.length - 1;
      });
      showSnack(context, 'Đã xóa ảnh.');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            _items.length > 1
                ? 'Ảnh ${_index + 1}/${_items.length}'
                : 'Ảnh chứng từ',
          ),
          leading: IconButton(
            icon: const Icon(Symbols.close_rounded),
            onPressed: () => Navigator.pop(context, _changed),
          ),
          actions: [
            IconButton(
              tooltip: 'Chia sẻ / lưu ảnh',
              icon: const Icon(Symbols.share_rounded),
              onPressed: _busy ? null : _share,
            ),
            IconButton(
              tooltip: 'Xóa ảnh',
              icon: const Icon(Symbols.delete_rounded),
              onPressed: _busy ? null : _delete,
            ),
          ],
        ),
        body: PageView.builder(
          controller: _pages,
          itemCount: _items.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) => _FullImage(attachment: _items[i]),
        ),
      ),
    );
  }
}

class _FullImage extends ConsumerWidget {
  const _FullImage({required this.attachment});
  final TxAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(attachmentBytesProvider(attachment.id));
    return bytes.when(
      data: (b) => InteractiveViewer(
        maxScale: 5,
        child: Center(child: Image.memory(b, fit: BoxFit.contain)),
      ),
      loading: () =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            e is ApiException ? e.message : 'Không tải được ảnh.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
