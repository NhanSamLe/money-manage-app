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
