import 'dart:async';

import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/ui/motion.dart';

/// Status line that advances through [stages] (and stays on the last one) while work is in progress, the same
/// pattern as the assistant's "thinking" bubble.
class StagedStatus extends StatefulWidget {
  const StagedStatus({
    super.key,
    this.stages = const ['Đang tổng hợp số liệu…', 'Đang phân tích…'],
  });
  final List<String> stages;

  @override
  State<StagedStatus> createState() => _StagedStatusState();
}

class _StagedStatusState extends State<StagedStatus> {
  Timer? _timer;
  int _stage = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1400), (t) {
      if (_stage >= widget.stages.length - 1) {
        t.cancel();
        return;
      }
      setState(() => _stage++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Motion.loops(context)
                ? const CircularProgressIndicator(strokeWidth: 2.4)
                : const Icon(
                    Symbols.auto_awesome_rounded,
                    color: MomaColors.emerald,
                    size: 20,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                widget.stages[_stage],
                key: ValueKey(_stage),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: pal.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
