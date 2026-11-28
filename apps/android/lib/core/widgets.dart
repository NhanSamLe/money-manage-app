import 'package:material_ui/material_ui.dart';

import '../app/theme/moma_theme.dart';
import 'network/api_client.dart';
import 'storage/offline_cache.dart';
import '../app/theme/palette.dart';
import 'ui/moma_switch.dart';

import 'package:material_symbols_icons/symbols.dart';

/// Shared Loading / Failure / Empty presentation for async read models (preserves a retry path).
/// No connection is not an error (D-021): reads normally come from the saved copy, so this only shows when
/// nothing was saved yet, in a calm tone, and it reloads by itself as soon as the connection is back.
class ErrorView extends StatefulWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  State<ErrorView> createState() => _ErrorViewState();
}

class _ErrorViewState extends State<ErrorView> {
  bool get _offline =>
      widget.error is ApiException &&
      (widget.error as ApiException).code == 'OFFLINE';

  @override
  void initState() {
    super.initState();
    NetStatus.notifier.addListener(_onNet);
  }

  @override
  void dispose() {
    NetStatus.notifier.removeListener(_onNet);
    super.dispose();
  }

  void _onNet() {
    if (_offline && !NetStatus.offline && mounted) widget.onRetry();
  }

  @override
  Widget build(BuildContext context) {
    final offline = _offline;
    final error = widget.error;
    final msg = offline
        ? 'Phần này chưa được lưu trên máy. MoMa sẽ tự tải khi có mạng.'
        : error is ApiException
        ? error.message
        : 'Có lỗi khi tải dữ liệu. Bạn thử lại sau ít phút nhé.';
    return EmptyState(
      icon: offline ? Symbols.cloud_off_rounded : Symbols.error_rounded,
      tone: offline ? const Color(0xFFE0A100) : MomaColors.expense,
      title: offline ? 'Đang offline' : 'Không tải được dữ liệu',
      hint: msg,
      actionLabel: 'Thử lại',
      onAction: widget.onRetry,
    );
  }
}

/// Illustrated empty state used by every list (production standard): soft layered artwork, a short title, one
/// sentence of guidance and (when the user can fix it) one primary action plus an optional secondary action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.tone,
    this.embedded = false,
  });

  /// True when placed inside a list or scroll view: sizes to its content instead of centring in a scroller.
  final bool embedded;
  final IconData icon;
  final String title;
  final String hint;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Accent of the artwork; defaults to the brand emerald.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final c = tone ?? MomaColors.emerald;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 150,
          height: 130,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 124,
                height: 124,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: 0.08),
                ),
              ),
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: 0.14),
                ),
              ),
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [c, MomaColors.forest],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.3),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 30),
              ),
              Positioned(
                right: 8,
                top: 10,
                child: _dot(c.withValues(alpha: 0.35), 10),
              ),
              Positioned(left: 6, bottom: 22, child: _dot(MomaColors.mint, 14)),
              Positioned(
                right: 18,
                bottom: 10,
                child: _dot(c.withValues(alpha: 0.2), 7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: pal.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.45, color: pal.muted),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ),
        ],
        if (secondaryLabel != null) ...[
          const SizedBox(height: 6),
          TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ],
    );
    if (embedded) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: body,
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: body,
      ),
    );
  }

  static Widget _dot(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Server / network / unexpected failures are shown as a modal dialog the user must acknowledge.
/// Inline text is reserved for field validation (see docs/decision-log.md D-011).
Future<void> showErrorDialog(
  BuildContext context,
  String message, {
  String title = 'Thông báo',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: context.pal.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MomaColors.expense.withValues(alpha: 0.08),
              ),
              child: Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: MomaColors.expense,
                ),
                child: const Icon(
                  Symbols.priority_high_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: context.pal.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.45,
                color: context.pal.ink,
              ),
            ),
            const SizedBox(height: 22),
            Divider(height: 1, color: context.pal.lineSoft),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Đã hiểu'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Confirmation before a destructive or irreversible action. Two equal buttons: safe action left, confirm right.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Đồng ý',
  String cancelLabel = 'Hủy',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = destructive ? MomaColors.expense : MomaColors.emerald;
      return Dialog(
        backgroundColor: context.pal.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: 0.1),
                ),
                child: Icon(
                  destructive ? Symbols.delete_rounded : Symbols.help_rounded,
                  color: c,
                  size: 40,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: context.pal.muted,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(cancelLabel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: c),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return ok ?? false;
}

/// Explains a field or concept. Opened from the small "?" next to a label; never shown as inline helper text.
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: context.pal.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF2F80ED).withValues(alpha: 0.1),
              ),
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF2F80ED),
                ),
                child: const Icon(
                  Symbols.info_rounded,
                  color: Colors.white,
                  size: 32,
                  fill: 1,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: context.pal.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: context.pal.ink,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Đã hiểu'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Label with an optional required marker and an optional "?" that opens an explanation dialog.
class HelpLabel extends StatelessWidget {
  const HelpLabel(
    this.label, {
    super.key,
    this.required = false,
    this.helpTitle,
    this.help,
  });
  final String label;
  final bool required;
  final String? helpTitle;
  final String? help;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text.rich(
            TextSpan(
              text: label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: context.pal.ink,
              ),
              children: [
                if (required)
                  const TextSpan(
                    text: ' *',
                    style: TextStyle(color: MomaColors.expense),
                  ),
              ],
            ),
          ),
        ),
        if (help != null)
          InkResponse(
            radius: 18,
            onTap: () => showInfoDialog(
              context,
              title: helpTitle ?? label,
              message: help!,
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Symbols.help_rounded,
                size: 18,
                color: context.pal.muted,
                semanticLabel: 'Giải thích $label',
              ),
            ),
          ),
      ],
    );
  }
}

/// Switch row: title with the "?" explanation, optional marker free.
class LabeledSwitch extends StatelessWidget {
  const LabeledSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: HelpLabel(label, help: help)),
      MomaSwitch(value: value, onChanged: onChanged),
    ],
  );
}
