import 'package:material_ui/material_ui.dart';

import '../app/theme/moma_theme.dart';
import 'network/api_client.dart';

/// Opens a keyboard-aware bottom sheet for a short form.
Future<T?> showFormSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: builder(ctx),
      ),
    ),
  );
}

/// Runs one command-like action with shared busy/error handling for sheet forms.
class FormRunner {
  FormRunner(this.setState);
  final void Function(VoidCallback) setState;
  bool busy = false;
  String? error;

  Future<bool> run(Future<void> Function() job) async {
    if (busy) return false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await job();
      return true;
    } on ApiException catch (e) {
      setState(() => error = e.message);
      return false;
    } finally {
      setState(() => busy = false);
    }
  }
}

class FormError extends StatelessWidget {
  const FormError(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(message!, style: const TextStyle(color: MomaColors.expense)),
    );
  }
}

String dateLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One row of a [showChoiceSheet].
class ChoiceOption<T> {
  const ChoiceOption({
    required this.value,
    required this.label,
    this.icon,
    this.leading,
  });
  final T value;
  final String label;
  final IconData? icon;
  final Widget? leading;
}

/// Bottom-sheet picker used for every filter / selection (design reference: "Giao diện" sheet).
/// Returns the chosen value, or null when dismissed.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceOption<T>> options,
  T? selected,
  String? footnote,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: MomaColors.ink,
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F7F5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: Color(0xFFD9E3DE),
                    ),
                    itemBuilder: (_, i) {
                      final o = options[i];
                      final on = o.value == selected;
                      return InkWell(
                        onTap: () => Navigator.of(ctx).pop(o.value),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 15,
                          ),
                          child: Row(
                            children: [
                              if (o.leading != null)
                                o.leading!
                              else if (o.icon != null)
                                Icon(o.icon, color: MomaColors.muted, size: 24),
                              if (o.leading != null || o.icon != null)
                                const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  o.label,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: on
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: MomaColors.ink,
                                  ),
                                ),
                              ),
                              if (on)
                                const Icon(
                                  Icons.check_rounded,
                                  color: MomaColors.emerald,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (footnote != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    footnote,
                    style: const TextStyle(
                      color: MomaColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
