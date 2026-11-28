import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// One learned answer for a part of the day ("Bánh mì" 20.000đ, paid in cash).
class RoutineOption {
  const RoutineOption({
    required this.key,
    required this.label,
    required this.amount,
  });
  factory RoutineOption.fromJson(Map<String, dynamic> j) => RoutineOption(
    key: '${j['key']}',
    label: '${j['label']}',
    amount: (j['amount'] as num?)?.toInt() ?? 0,
  );
  final String key;
  final String label;
  final int amount;

  /// "Bánh mì 20k".
  String get chip => '$label ${shortVnd(amount)}';
}

String shortVnd(int n) {
  if (n >= 1000000) {
    final v = (n / 100000).round() / 10;
    return '${v.toString().replaceAll('.0', '').replaceAll('.', ',')}tr';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$nđ';
}

class Routine {
  const Routine({
    required this.slot,
    required this.question,
    required this.recorded,
    required this.options,
  });
  final String slot;
  final String question;
  final bool recorded;
  final List<RoutineOption> options;
}

/// What to ask right now (GET /v1/ai/routine?slot=now). Null = nothing to ask (or offline: no chips, no error).
final routineProvider = FutureProvider.autoDispose<Routine?>((ref) async {
  try {
    final r = await ref
        .read(apiProvider)
        .get('/ai/routine', query: {'slot': 'now'});
    final m = (r as Map).cast<String, dynamic>();
    if (m['slot'] == null) return null;
    final options = [
      for (final o in (m['options'] as List? ?? const []))
        RoutineOption.fromJson((o as Map).cast<String, dynamic>()),
    ];
    if (options.isEmpty || m['recorded'] == true) return null;
    return Routine(
      slot: '${m['slot']}',
      question: '${m['question'] ?? ''}',
      recorded: m['recorded'] == true,
      options: options,
    );
  } catch (_) {
    return null;
  }
});

/// Records a learned option with one tap and offers Hoàn tác. Shared by the chips, push buttons and the widget.
Future<String?> recordRoutine(
  ApiClient api, {
  required String slot,
  required List<String> keys,
  String? date,
}) async {
  final r = await api.post('/ai/routine/record', {
    'slot': slot,
    'keys': keys,
    'date': ?date,
  });
  final m = (r as Map).cast<String, dynamic>();
  return m['message'] as String?;
}

/// "Sáng nay bạn ăn gì?  [Bánh mì 20k] [Cà phê sữa 25k] [Khác] [Hôm nay không]".
class RoutineChips extends ConsumerStatefulWidget {
  const RoutineChips({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 10, 16, 0),
  });
  final EdgeInsetsGeometry margin;
  @override
  ConsumerState<RoutineChips> createState() => _RoutineChipsState();
}

class _RoutineChipsState extends ConsumerState<RoutineChips> {
  bool _hidden = false;
  String? _busy;

  Future<void> _pick(Routine r, RoutineOption o) async {
    setState(() => _busy = o.key);
    final api = ref.read(apiProvider);
    try {
      final res = await api.post('/ai/routine/record', {
        'slot': r.slot,
        'keys': [o.key],
      });
      final m = (res as Map).cast<String, dynamic>();
      final rec = ((m['recorded'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      refreshAll(ref);
      if (!mounted) return;
      setState(() => _hidden = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${m['message'] ?? 'Đã ghi'}'),
          action: rec.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Hoàn tác',
                  onPressed: () async {
                    try {
                      await api.post('/ai/undo', {
                        'step_command_id': rec.first['command_id'],
                        'ops': (rec.first['undo'] as Map)['ops'],
                      });
                      refreshAll(ref);
                    } catch (_) {}
                  },
                ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _skip(Routine r) async {
    setState(() => _hidden = true);
    try {
      await ref.read(apiProvider).post('/reminders/skip', {
        'kind': r.slot,
        'skip': true,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final r = ref.watch(routineProvider).value;
    if (r == null) return const SizedBox.shrink();
    final pal = context.pal;
    return Container(
      width: double.infinity,
      margin: widget.margin,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: pal.tintSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.wb_sunny_rounded, size: 18, color: pal.accentInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.question,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    color: pal.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in r.options)
                ActionChip(
                  avatar: _busy == o.key
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.add_rounded, size: 16),
                  label: Text(o.chip),
                  onPressed: _busy == null ? () => _pick(r, o) : null,
                ),
              ActionChip(
                label: const Text('Khác'),
                onPressed: () => context.push('/quick-entry'),
              ),
              ActionChip(
                label: const Text('Hôm nay không'),
                onPressed: () => _skip(r),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A one-tap question from the assistant ("Chia hóa đơn 849.000đ cho ~3 người?"): the reason in one line, the
/// answers as chips, and the bill's items when it has them.
class ChoicesCard extends StatefulWidget {
  const ChoicesCard({super.key, required this.json, required this.onChoose});
  final Map<String, dynamic> json;
  final Future<void> Function(Map<String, dynamic>) onChoose;

  @override
  State<ChoicesCard> createState() => _ChoicesCardState();
}

class _ChoicesCardState extends State<ChoicesCard> {
  bool _answered = false;
  bool _items = false;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final options = [
      for (final o in (widget.json['options'] as List? ?? const []))
        (o as Map).cast<String, dynamic>(),
    ];
    final items = [
      for (final i in (widget.json['items'] as List? ?? const []))
        (i as Map).cast<String, dynamic>(),
    ];
    final reason = '${widget.json['reason'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: pal.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.json['question'] ?? ''}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: pal.ink,
            ),
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              reason,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: pal.muted),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                ActionChip(
                  label: Text('${o['label'] ?? ''}'),
                  onPressed: _answered
                      ? null
                      : () async {
                          final text = '${o['text'] ?? ''}';
                          // Prefill answers keep the card open (the owner finishes typing).
                          if (o['action'] != null || text.isNotEmpty) {
                            setState(() => _answered = true);
                          }
                          await widget.onChoose(o);
                        },
                ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _items = !_items),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _items
                      ? 'Ẩn các món'
                      : 'Xem các món (${items.length}) · chia theo món',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: MomaColors.emerald,
                  ),
                ),
              ),
            ),
            if (_items) ...[
              for (final i in items)
                Text(
                  '${i['qty']} × ${i['name']}${i['amount'] == null ? '' : ' · ${i['amount']}đ'}',
                  style: TextStyle(fontSize: 12.5, color: pal.muted),
                ),
              const SizedBox(height: 4),
              if (!_answered)
                TextButton(
                  onPressed: () => widget.onChoose({
                    'text': '',
                    'prefill': 'Chia đều, riêng ',
                  }),
                  child: const Text('Chia theo món…'),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
