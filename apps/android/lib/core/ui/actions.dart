import 'package:material_ui/material_ui.dart';

/// Mobile action-button patterns (UX standard):
/// * 1 action  -> one full-width primary button.
/// * 2 actions -> two equal buttons side by side, safe action on the left, primary on the right.
/// * 3 actions -> primary full width on top, secondary below, tertiary as a text button last.
/// A busy primary shows a spinner and disables every button so nothing can be double-submitted.
class ActionButtons extends StatelessWidget {
  const ActionButtons({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.tertiaryLabel,
    this.onTertiary,
    this.busy = false,
    this.destructive = false,
  });

  final String primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? tertiaryLabel;
  final VoidCallback? onTertiary;
  final bool busy;

  /// Primary is a destructive action (cancel/archive/delete): red instead of brand green.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final primary = FilledButton(
      onPressed: busy ? null : onPrimary,
      style: destructive
          ? FilledButton.styleFrom(backgroundColor: const Color(0xFFD64545))
          : null,
      child: busy
          ? const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(primaryLabel, textAlign: TextAlign.center),
    );
    if (secondaryLabel == null) return primary;
    final secondary = OutlinedButton(
      onPressed: busy ? null : onSecondary,
      child: Text(secondaryLabel!, textAlign: TextAlign.center),
    );
    if (tertiaryLabel == null) {
      return Row(
        children: [
          Expanded(child: secondary),
          const SizedBox(width: 12),
          Expanded(child: primary),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        primary,
        const SizedBox(height: 12),
        secondary,
        const SizedBox(height: 4),
        TextButton(
          onPressed: busy ? null : onTertiary,
          child: Text(tertiaryLabel!),
        ),
      ],
    );
  }
}
