import 'package:material_ui/material_ui.dart';

import '../app/theme/moma_theme.dart';
import 'network/api_client.dart';

/// Shared Loading / Failure / Empty presentation for async read models (preserves a retry path).
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final msg = error is ApiException
        ? (error as ApiException).message
        : 'Không tải được dữ liệu.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: MomaColors.muted,
            ),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(minimumSize: const Size(140, 44)),
              child: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
  });
  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: MomaColors.mint),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MomaColors.muted),
            ),
          ],
        ),
      ),
    );
  }
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
      backgroundColor: Colors.white,
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
                  Icons.priority_high_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: MomaColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.45,
                color: MomaColors.ink,
              ),
            ),
            const SizedBox(height: 22),
            const Divider(height: 1, color: Color(0xFFEEF2F0)),
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
