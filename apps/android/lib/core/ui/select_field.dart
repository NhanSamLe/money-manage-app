import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../sheets.dart';
import '../widgets.dart';

String _textOf(Widget? w, [String fallback = '']) {
  if (w is Text) return w.data ?? w.textSpan?.toPlainText() ?? fallback;
  return fallback;
}

/// Select field: label above, rounded value box, opens a bottom sheet (with search when the list is long).
/// Drop-in replacement for `DropdownButtonFormField` (same `initialValue` / `items` / `onChanged` shape):
/// the label comes from `decoration.labelText`, optional fields pass `optional: true`.
class PickField<T> extends StatefulWidget {
  const PickField({
    super.key,
    this.initialValue,
    this.decoration,
    required this.items,
    required this.onChanged,
    this.isExpanded = true,
    this.optional = false,
    this.help,
    this.validator,
    this.icon,
  });
  final T? initialValue;
  final InputDecoration? decoration;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final bool optional;
  final String? help;
  final String? Function(T?)? validator;
  final IconData? icon;

  @override
  State<PickField<T>> createState() => _PickFieldState<T>();
}

class _PickFieldState<T> extends State<PickField<T>> {
  T? _value;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  void didUpdateWidget(PickField<T> old) {
    super.didUpdateWidget(old);
    if (widget.initialValue != old.initialValue) _value = widget.initialValue;
  }

  String get _label =>
      widget.decoration?.labelText ?? widget.decoration?.hintText ?? 'Lựa chọn';

  String? _labelFor(T? v) {
    for (final i in widget.items) {
      if (i.value == v) return _textOf(i.child);
    }
    return null;
  }

  Future<void> _open() async {
    // Optional selects can be cleared: a leading "Không chọn" row maps to null.
    final picked = await showChoiceSheetBoxed<Object?>(
      context,
      title: _label,
      selected: _value,
      searchable: widget.items.length > 7,
      options: [
        for (final i in widget.items)
          ChoiceOption<Object?>(value: i.value, label: _textOf(i.child)),
      ],
    );
    if (!mounted || picked == null) return; // dismissed
    setState(() {
      _value = picked.value as T?;
      _error = widget.validator?.call(_value);
    });
    widget.onChanged?.call(_value);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final shown = _labelFor(_value);
    final enabled = widget.onChanged != null;
    final hasError = _error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(_label, required: !widget.optional, help: widget.help),
        const SizedBox(height: 6),
        Material(
          color: pal.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? _open : null,
            child: Container(
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hasError ? MomaColors.expense : pal.line,
                  width: hasError ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, color: pal.muted, size: 22),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      shown ?? 'Chọn ${_label.toLowerCase()}',
                      style: TextStyle(
                        fontSize: 15,
                        color: shown == null ? pal.hint : pal.ink,
                      ),
                    ),
                  ),
                  Icon(Symbols.keyboard_arrow_down_rounded, color: pal.muted),
                ],
              ),
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 0, 0),
            child: Text(
              _error!,
              style: const TextStyle(color: MomaColors.expense, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// Rounded segmented control (replaces the squared Material SegmentedButton). Same call shape:
/// `segments`, `selected`, `onSelectionChanged`.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = false,
    this.style,
  });
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>> onSelectionChanged;
  final bool showSelectedIcon;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: pal.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final s in segments)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelectionChanged({s.value}),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  constraints: const BoxConstraints(minHeight: 40),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: selected.contains(s.value)
                        ? pal.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: selected.contains(s.value)
                        ? const [
                            BoxShadow(
                              color: Color(0x1A073D33),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    _textOf(s.label),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected.contains(s.value)
                          ? FontWeight.w800
                          : FontWeight.w600,
                      color: selected.contains(s.value)
                          ? MomaColors.emerald
                          : pal.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
