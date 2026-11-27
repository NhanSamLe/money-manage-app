import 'package:material_ui/material_ui.dart';

import '../app/theme/moma_theme.dart';
import 'network/api_client.dart';
import 'quick_parse.dart';
import '../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

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

/// Result wrapper so "chose the row whose value is null" can be told apart from "dismissed the sheet".
class ChoiceResult<T> {
  const ChoiceResult(this.value);
  final T value;
}

/// Bottom-sheet picker used for every filter / selection (design reference: "Giao diện" sheet).
/// Long lists get a search box (diacritic-insensitive). Returns the chosen value, or null when dismissed.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceOption<T>> options,
  T? selected,
  String? footnote,
  bool? searchable,
}) async => (await showChoiceSheetBoxed<T>(
  context,
  title: title,
  options: options,
  selected: selected,
  footnote: footnote,
  searchable: searchable,
))?.value;

Future<ChoiceResult<T>?> showChoiceSheetBoxed<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceOption<T>> options,
  T? selected,
  String? footnote,
  bool? searchable,
}) {
  return showModalBottomSheet<ChoiceResult<T>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: context.pal.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => _ChoiceSheet<T>(
      title: title,
      options: options,
      selected: selected,
      footnote: footnote,
      searchable: searchable ?? options.length > 7,
    ),
  );
}

class _ChoiceSheet<T> extends StatefulWidget {
  const _ChoiceSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.footnote,
    required this.searchable,
  });
  final String title;
  final List<ChoiceOption<T>> options;
  final T? selected;
  final String? footnote;
  final bool searchable;

  @override
  State<_ChoiceSheet<T>> createState() => _ChoiceSheetState<T>();
}

class _ChoiceSheetState<T> extends State<_ChoiceSheet<T>> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final needle = foldVietnamese(_q.text.trim());
    final shown = needle.isEmpty
        ? widget.options
        : widget.options
              .where((o) => foldVietnamese(o.label).contains(needle))
              .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: pal.ink,
                  ),
                ),
                if (widget.searchable) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _q,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Tìm kiếm',
                      prefixIcon: const Icon(Symbols.search_rounded),
                      filled: true,
                      fillColor: pal.surfaceAlt,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(
                          color: MomaColors.emerald,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Flexible(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                            'Không tìm thấy kết quả',
                            style: TextStyle(color: pal.muted),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: pal.surfaceAlt,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: shown.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: pal.line,
                            ),
                            itemBuilder: (_, i) {
                              final o = shown[i];
                              final on = o.value == widget.selected;
                              return InkWell(
                                onTap: () =>
                                    Navigator.of(context)
                                        .pop(ChoiceResult<T>(o.value)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      if (o.leading != null)
                                        o.leading!
                                      else if (o.icon != null)
                                        Icon(
                                          o.icon,
                                          color: pal.muted,
                                          size: 22,
                                        ),
                                      if (o.leading != null || o.icon != null)
                                        const SizedBox(width: 14),
                                      Expanded(
                                        child: Text(
                                          o.label,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: on
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: pal.ink,
                                          ),
                                        ),
                                      ),
                                      if (on)
                                        const Icon(
                                          Symbols.check_rounded,
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
                if (widget.footnote != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.footnote!,
                      style: TextStyle(color: pal.muted, fontSize: 13),
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
}
