import 'dart:io';

import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/ui/actions.dart';
import '../../core/widgets.dart';
import 'update_check.dart';
import 'update_service.dart';

bool _sheetOpen = false;

/// Silent check when Home opens: at most once per 12 hours, never shows an error.
Future<void> maybeAutoCheckForUpdate(BuildContext context) async {
  final svc = UpdateService();
  if (!await svc.autoCheckDue()) return;
  try {
    final status = await svc.check();
    final r = status.release;
    if (r != null && context.mounted) await showUpdateSheet(context, r, svc);
  } catch (_) {
    // Offline, rate-limited or no release yet: try again at the next due check.
  }
}

/// Settings -> "Kiểm tra cập nhật": always asks GitHub and reports the outcome.
Future<void> checkForUpdateManually(BuildContext context) async {
  final svc = UpdateService();
  showSnack(context, 'Đang kiểm tra bản cập nhật...');
  try {
    final status = await svc.check();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final r = status.release;
    if (r == null) {
      await showInfoDialog(
        context,
        title: 'Bạn đang dùng bản mới nhất',
        message:
            'MoMa ${status.installed.version} là phiên bản mới nhất.',
      );
      return;
    }
    await showUpdateSheet(context, r, svc);
  } on UpdateException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await showErrorDialog(context, e.message);
  }
}

Future<void> showUpdateSheet(
  BuildContext context,
  ReleaseInfo release,
  UpdateService svc,
) async {
  if (_sheetOpen) return;
  _sheetOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _UpdateSheet(release: release, svc: svc),
    );
  } finally {
    _sheetOpen = false;
  }
}

enum _Phase { idle, downloading, needsPermission, failed }

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.release, required this.svc});
  final ReleaseInfo release;
  final UpdateService svc;
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.idle;
  double? _progress;
  File? _apk;
  String? _error;
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the "install unknown apps" settings: try the installer again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForSettings) {
      _waitingForSettings = false;
      _install();
    }
  }

  Future<void> _update() async {
    if (_apk != null && _apk!.existsSync()) return _install();
    setState(() {
      _phase = _Phase.downloading;
      _progress = null;
      _error = null;
    });
    try {
      final f = await widget.svc.download(
        widget.release,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      _apk = f;
      await _install();
    } on UpdateException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = 'Không tải được bản cập nhật. Bạn thử lại nhé.';
        });
      }
    }
  }

  Future<void> _install() async {
    final apk = _apk;
    if (apk == null) return;
    final outcome = await widget.svc.install(apk);
    if (!mounted) return;
    switch (outcome) {
      case InstallOutcome.started:
        Navigator.of(context).pop();
      case InstallOutcome.needsPermission:
        setState(() => _phase = _Phase.needsPermission);
      case InstallOutcome.failed:
        setState(() {
          _phase = _Phase.failed;
          _error = 'Không mở được trình cài đặt. Bạn thử lại nhé.';
        });
    }
  }

  Future<void> _openSettings() async {
    _waitingForSettings = true;
    await widget.svc.openInstallPermissionSettings();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final r = widget.release;
    final downloading = _phase == _Phase.downloading;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: pal.tint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Symbols.system_update_rounded,
                    color: MomaColors.emerald,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Có phiên bản mới ${r.versionName}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: pal.ink,
                        ),
                      ),
                      if (r.apkSize > 0)
                        Text(
                          'Dung lượng khoảng ${(r.apkSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                          style: TextStyle(color: pal.muted, fontSize: 13),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (r.notes.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: pal.surfaceAlt,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      r.notes,
                      style: TextStyle(color: pal.ink, height: 1.45),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (downloading) ...[
              LinearProgressIndicator(
                value: _progress,
                borderRadius: BorderRadius.circular(8),
                color: MomaColors.emerald,
              ),
              const SizedBox(height: 8),
              Text(
                _progress == null
                    ? 'Đang tải bản cập nhật...'
                    : 'Đang tải ${(_progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: TextStyle(color: pal.muted, fontSize: 13.5),
              ),
              const SizedBox(height: 16),
            ],
            if (_phase == _Phase.needsPermission) ...[
              Text(
                'Bạn cần cho phép cài ứng dụng từ MoMa. Mở cài đặt, bật "Cho phép từ nguồn này" rồi quay lại MoMa.',
                style: TextStyle(color: pal.ink, height: 1.45),
              ),
              const SizedBox(height: 16),
            ],
            if (_phase == _Phase.failed && _error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: MomaColors.expense, height: 1.4),
              ),
              const SizedBox(height: 16),
            ],
            if (_phase == _Phase.needsPermission)
              ActionButtons(
                primaryLabel: 'Mở cài đặt',
                onPrimary: _openSettings,
                secondaryLabel: 'Để sau',
                onSecondary: () => Navigator.of(context).pop(),
              )
            else
              ActionButtons(
                primaryLabel: _phase == _Phase.failed
                    ? 'Thử lại'
                    : 'Cập nhật ngay',
                onPrimary: _update,
                secondaryLabel: 'Để sau',
                onSecondary: () => Navigator.of(context).pop(),
                busy: downloading,
              ),
          ],
        ),
      ),
    );
  }
}
