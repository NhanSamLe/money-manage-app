import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import 'report_data.dart';

/// Bottom sheet with a year stepper and a 4x3 month grid. Returns `YYYY-MM`, or null when dismissed.
/// Months after the current one are disabled (nothing to report yet).
Future<String?> showMonthPickerSheet(BuildContext context, String selected) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (_) => _MonthPicker(selected: selected),
  );
}

class _MonthPicker extends StatefulWidget {
  const _MonthPicker({required this.selected});
  final String selected;

  @override
  State<_MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<_MonthPicker> {
  late int _year = monthYear(widget.selected);
  final String _now = currentMonthKey();

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final nowYear = monthYear(_now);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Chọn tháng',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Năm trước',
                  icon: const Icon(Symbols.chevron_left_rounded),
                  onPressed: () => setState(() => _year--),
                ),
                Expanded(
                  child: Text(
                    'Năm $_year',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: pal.ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Năm sau',
                  icon: const Icon(Symbols.chevron_right_rounded),
                  onPressed: _year >= nowYear
                      ? null
                      : () => setState(() => _year++),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.9,
              children: [for (var m = 1; m <= 12; m++) _cell(context, m)],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, int m) {
    final pal = context.pal;
    final key = monthKey(_year, m);
    final selected = key == widget.selected;
    final enabled = key.compareTo(_now) <= 0;
    final isNow = key == _now;
    return Material(
      color: selected ? MomaColors.emerald : pal.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? () => Navigator.of(context).pop(key) : null,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: isNow && !selected
                ? Border.all(color: MomaColors.emerald, width: 1.2)
                : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Thg $m',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? Colors.white
                    : enabled
                    ? pal.ink
                    : pal.hint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
