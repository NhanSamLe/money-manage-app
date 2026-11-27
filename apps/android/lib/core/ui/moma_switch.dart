import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../sheets.dart';
import '../widgets.dart';

/// Self-drawn on/off switch: a clear track and thumb in both themes (the stock Material switch rendered an
/// invisible thumb on the owner's phone).
class MomaSwitch extends StatelessWidget {
  const MomaSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Semantics(
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 48,
            height: 28,
            padding: const EdgeInsets.all(3),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: value ? MomaColors.emerald : pal.line,
            ),
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Date field in the same style as the other inputs: label above, rounded box, calendar on tap.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.required = false,
    this.help,
    this.firstDate,
    this.lastDate,
    this.initialDate,
  });
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool required;
  final String? help;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final DateTime? initialDate;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(label, required: required, help: help),
        const SizedBox(height: 6),
        Material(
          color: pal.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: value ?? initialDate ?? now,
                firstDate: firstDate ?? DateTime(now.year - 5),
                lastDate: lastDate ?? DateTime(now.year + 10),
              );
              if (d != null) onChanged(d);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: pal.line),
              ),
              child: Row(
                children: [
                  Icon(Symbols.event_rounded, color: pal.muted, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      value == null ? 'Chọn ngày' : dateLabel(value!),
                      style: TextStyle(
                        fontSize: 15,
                        color: value == null ? pal.hint : pal.ink,
                      ),
                    ),
                  ),
                  if (value != null && !required)
                    InkResponse(
                      radius: 18,
                      onTap: () => onChanged(null),
                      child: Icon(
                        Symbols.close_rounded,
                        color: pal.muted,
                        size: 20,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
