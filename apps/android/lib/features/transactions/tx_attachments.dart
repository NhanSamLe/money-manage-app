import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/offline.dart';
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

/// On-device files for attachments: a disk cache of viewed pictures (an id never changes content, so a cached
/// copy is always valid) and the queue of pictures taken offline. Missing storage (tests) just disables both.
class AttachmentFiles {
  AttachmentFiles({
    Future<Directory?> Function()? cacheRoot,
    Future<Directory?> Function()? queueRoot,
  }) : _cacheRoot = cacheRoot ?? _defaultCache,
       _queueRoot = queueRoot ?? _defaultQueue;

  final Future<Directory?> Function() _cacheRoot;
  final Future<Directory?> Function() _queueRoot;

  static final instance = AttachmentFiles();

  static Future<Directory?> _defaultCache() async {
    try {
      return Directory(
        p.join((await getApplicationCacheDirectory()).path, 'attachments'),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Directory?> _defaultQueue() async {
    try {
      return Directory(
        p.join((await getApplicationSupportDirectory()).path, 'upload_queue'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _dir(Future<Directory?> Function() root) async {
    final d = await root();
    if (d == null) return null;
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> cacheDir() => _dir(_cacheRoot);
  Future<Directory?> queueDir() => _dir(_queueRoot);

  Future<Uint8List?> readCached(String id) async {
    final d = await cacheDir();
    if (d == null) return null;
    final f = File(p.join(d.path, id));
    try {
      return f.existsSync() ? f.readAsBytesSync() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCached(String id, List<int> bytes) async {
    final d = await cacheDir();
    if (d == null) return;
    try {
      File(p.join(d.path, id)).writeAsBytesSync(bytes, flush: true);
    } catch (_) {}
  }

  Future<void> removeCached(String id) async {
    final d = await cacheDir();
    if (d == null) return;
    try {
      final f = File(p.join(d.path, id));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Size of cached pictures + queued uploads.
  Future<int> sizeBytes() async {
    var n = 0;
    for (final d in [await cacheDir(), await queueDir()]) {
      if (d == null) continue;
      try {
        for (final f in d.listSync().whereType<File>()) {
          n += f.lengthSync();
        }
      } catch (_) {}
    }
    return n;
  }

  /// Drops cached pictures (they come back from the server when viewed). [queue]: also the upload queue.
  Future<void> clear({bool queue = false}) async {
    for (final d in [await cacheDir(), if (queue) await queueDir()]) {
      if (d == null) continue;
      try {
        for (final f in d.listSync().whereType<File>()) {
          f.deleteSync();
        }
      } catch (_) {}
    }
  }
}

final attachmentFilesProvider = Provider<AttachmentFiles>(
  (_) => AttachmentFiles.instance,
);

/// Picture bytes: disk cache first, then the server (saved for next time, so it also opens offline).
/// Re-runs when the connection comes back, so a picture that could not load offline appears by itself.
final attachmentBytesProvider = FutureProvider.family<Uint8List, String>((
  ref,
  id,
) async {
  ref.watch(netStateProvider.select((s) => s.offline));
  final files = ref.watch(attachmentFilesProvider);
  final cached = await files.readCached(id);
  if (cached != null) return cached;
  final bytes = Uint8List.fromList(
    await ref.watch(apiProvider).getBytes('/attachments/$id'),
  );
  await files.writeCached(id, bytes);
  return bytes;
});

/// A picture chosen while offline, kept on the phone until it can be uploaded.
class PendingUpload {
  const PendingUpload({
    required this.id,
    required this.txId,
    required this.contentType,
    required this.createdAt,
    this.path,
    this.bytes,
    this.error,
  });

  factory PendingUpload.fromJson(Map<String, dynamic> j) => PendingUpload(
    id: '${j['id']}',
    txId: '${j['tx_id']}',
    contentType: '${j['content_type']}',
    createdAt: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
    path: j['path'] as String?,
    error: j['error'] as String?,
  );

  final String id;
  final String txId;
  final String contentType;
  final DateTime createdAt;

  /// File in the app's private storage (null only when storage is unavailable; then [bytes] holds the picture).
  final String? path;
  final Uint8List? bytes;

  /// Set when the server refused the picture for good (shown on its tile, never retried silently).
  final String? error;

  Map<String, dynamic> toJson() => {
    'id': id,
    'tx_id': txId,
    'content_type': contentType,
    'at': createdAt.toIso8601String(),
    'path': path,
    'error': error,
  };

  PendingUpload withError(String message) => PendingUpload(
    id: id,
    txId: txId,
    contentType: contentType,
    createdAt: createdAt,
    path: path,
    bytes: bytes,
    error: message,
  );

  Future<Uint8List?> read() async {
    if (bytes != null) return bytes;
    final f = path;
    if (f == null) return null;
    try {
      return File(f).readAsBytesSync();
    } catch (_) {
      return null;
    }
  }
}

/// Pictures waiting to be uploaded ("Chờ tải lên"); sent by the offline sync loop as soon as there is a network.
class UploadQueue extends Notifier<List<PendingUpload>> {
  bool _loaded = false;
  bool _flushing = false;

  @override
  List<PendingUpload> build() {
    Future.microtask(_load);
    return const [];
  }

  AttachmentFiles get _files => ref.read(attachmentFilesProvider);

  Future<File?> _index() async {
    final d = await _files.queueDir();
    return d == null ? null : File(p.join(d.path, 'index.json'));
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final f = await _index();
    if (f == null || !f.existsSync()) return;
    try {
      final list = jsonDecode(f.readAsStringSync()) as List;
      final saved = [
        for (final e in list)
          PendingUpload.fromJson((e as Map).cast<String, dynamic>()),
      ];
      state = [
        ...saved,
        ...state.where((x) => !saved.any((s) => s.id == x.id)),
      ];
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = await _index();
    if (f == null) return;
    try {
      f.writeAsStringSync(
        jsonEncode([for (final u in state) u.toJson()]),
        flush: true,
      );
    } catch (_) {}
  }

  /// Keeps [bytes] for [txId] until the next successful upload.
  Future<void> add(String txId, Uint8List bytes, String contentType) async {
    await _load();
    final id = ApiClient.newId();
    final d = await _files.queueDir();
    String? path;
    if (d != null) {
      try {
        final ext = contentType == 'image/png'
            ? 'png'
            : (contentType == 'image/webp' ? 'webp' : 'jpg');
        final f = File(p.join(d.path, '$id.$ext'));
        f.writeAsBytesSync(bytes, flush: true);
        path = f.path;
      } catch (_) {}
    }
    state = [
      ...state,
      PendingUpload(
        id: id,
        txId: txId,
        contentType: contentType,
        createdAt: DateTime.now(),
        path: path,
        bytes: path == null ? bytes : null,
      ),
    ];
    await _save();
  }

  Future<void> remove(String id) async {
    final u = state.where((x) => x.id == id).firstOrNull;
    state = state.where((x) => x.id != id).toList();
    final f = u?.path;
    if (f != null) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    await _save();
  }

  /// Uploads waiting pictures oldest first; stops at the first "still offline". Returns how many were sent.
  Future<int> flush() async {
    await _load();
    if (_flushing) return 0;
    _flushing = true;
    var sent = 0;
    try {
      final api = ref.read(apiProvider);
      for (final u in [...state.where((x) => x.error == null)]) {
        final bytes = await u.read();
        if (bytes == null) {
          await remove(u.id);
          continue;
        }
        try {
          await api.postBytes(
            '/transactions/${u.txId}/attachments',
            bytes,
            contentType: u.contentType,
          );
          await remove(u.id);
          ref.invalidate(txAttachmentsProvider(u.txId));
          sent++;
        } on ApiException catch (e) {
          if (e.retryable) break;
          state = [
            for (final x in state) x.id == u.id ? x.withError(e.message) : x,
          ];
          await _save();
        }
      }
    } finally {
      _flushing = false;
    }
    return sent;
  }
}

final uploadQueueProvider = NotifierProvider<UploadQueue, List<PendingUpload>>(
  UploadQueue.new,
);

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
    this.onUploaded,
  });
  final String txId;
  final bool canAdd;

  /// Called after each picture reaches the server (id from the API, the bytes still on the phone):
  /// the detail page reads the bill and updates category / note / split (bill analysis, migration 016).
  final void Function(String? attachmentId, Uint8List bytes)? onUploaded;

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
    final queue = ref.read(uploadQueueProvider.notifier);
    setState(() => _uploading += files.length);
    var done = 0;
    var queued = 0;
    String? error;
    for (final f in files) {
      try {
        final bytes = await f.readAsBytes();
        final type = sniffImageType(bytes);
        if (type == null) {
          error = 'Ảnh không đúng định dạng (chỉ nhận JPEG, PNG, WebP).';
        } else if (queued > 0) {
          // Already offline for an earlier picture: keep the rest on the phone too.
          await queue.add(widget.txId, bytes, type);
          queued++;
        } else {
          try {
            final r = await api.postBytes(
              '/transactions/${widget.txId}/attachments',
              bytes,
              contentType: type,
            );
            done++;
            widget.onUploaded?.call(
              r is Map ? r['id'] as String? : null,
              bytes,
            );
          } on ApiException catch (e) {
            if (e.code != 'OFFLINE') rethrow;
            await queue.add(widget.txId, bytes, type);
            queued++;
          }
        }
      } on ApiException catch (e) {
        error = e.message;
      } catch (_) {
        error = 'Không đọc được ảnh. Bạn thử ảnh khác.';
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
    if (done > 0) ref.invalidate(txAttachmentsProvider(widget.txId));
    if (!mounted) return;
    if (queued > 0 && error == null) {
      showSnack(
        context,
        'Đang offline: đã giữ $queued ảnh trên máy, sẽ tự tải lên khi có mạng.',
      );
    } else if (error != null) {
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
    final waiting = [
      for (final u in ref.watch(uploadQueueProvider))
        if (u.txId == widget.txId) u,
    ];
    final offlineEmpty =
        async.hasError &&
        items.isEmpty &&
        async.error is ApiException &&
        (async.error as ApiException).code == 'OFFLINE';
    final canAdd =
        widget.canAdd &&
        items.length + _uploading + waiting.length < kMaxAttachments;
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
          if (async.hasError && items.isEmpty && !offlineEmpty)
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
                for (final u in waiting) _WaitingTile(upload: u),
                for (var i = 0; i < _uploading; i++) const _UploadingTile(),
                if (canAdd && !async.isLoading)
                  _AddTile(
                    onTap: () =>
                        _add(items.length + _uploading + waiting.length),
                  ),
                if (async.isLoading && items.isEmpty) const _UploadingTile(),
              ],
            ),
          if (offlineEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Ảnh đã lưu sẽ hiện khi có mạng.',
                style: TextStyle(color: pal.muted, fontSize: 12.5),
              ),
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
          error: (e, _) => _ImagePlaceholder(error: e, compact: true),
        ),
      ),
    );
  }
}

/// Calm stand-in for a picture that cannot be shown: offline → "Ảnh sẽ hiện khi có mạng", otherwise a neutral icon.
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.error, this.compact = false});
  final Object error;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final offline =
        error is ApiException && (error as ApiException).code == 'OFFLINE';
    final color = compact ? pal.muted : Colors.white70;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 6 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Symbols.cloud_off_rounded : Symbols.image_rounded,
              color: color,
              size: compact ? 22 : 40,
            ),
            const SizedBox(height: 6),
            Text(
              offline
                  ? 'Ảnh sẽ hiện khi có mạng'
                  : (error is ApiException
                        ? (error as ApiException).message
                        : 'Không tải được ảnh.'),
              textAlign: TextAlign.center,
              maxLines: compact ? 3 : 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: compact ? 11 : 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// A picture kept on the phone until it can be uploaded ("Chờ tải lên"); a refused one says why and can be dropped.
class _WaitingTile extends ConsumerWidget {
  const _WaitingTile({required this.upload});
  final PendingUpload upload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final failed = upload.error != null;
    return Material(
      color: pal.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final drop = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(failed ? 'Không tải lên được' : 'Chờ tải lên'),
              content: Text(
                failed ? upload.error! : 'Ảnh đang được giữ trên máy và sẽ tự tải lên khi có mạng.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Bỏ ảnh này'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
          if (drop == true) {
            await ref.read(uploadQueueProvider.notifier).remove(upload.id);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: upload.read(),
              builder: (_, s) => s.data == null
                  ? const SizedBox.shrink()
                  : Opacity(
                      opacity: 0.55,
                      child: Image.memory(
                        s.data!,
                        fit: BoxFit.cover,
                        cacheWidth: 360,
                      ),
                    ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                color: failed ? pal.dangerBg : pal.warnBg,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  failed ? 'Lỗi tải lên' : 'Chờ tải lên',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: failed ? MomaColors.expense : pal.warnInk,
                  ),
                ),
              ),
            ),
          ],
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
      await ref.read(attachmentFilesProvider).removeCached(_current.id);
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
      error: (e, _) => _ImagePlaceholder(error: e),
    );
  }
}
