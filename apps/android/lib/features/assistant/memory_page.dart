import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/header.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';

/// "Trợ lý đã học được gì": the assistant's explicit memory (GET/POST/DELETE /v1/ai/memory). The owner can see
/// every entry with its confidence, remove what is wrong and add notes, shorthand or preferences by hand.

class AiMemory {
  AiMemory({
    required this.id,
    required this.kind,
    required this.text,
    required this.weight,
    required this.source,
  });
  factory AiMemory.fromJson(Map<String, dynamic> j) => AiMemory(
    id: '${j['id']}',
    kind: '${j['kind']}',
    text: '${j['text'] ?? j['key'] ?? ''}',
    weight: ((j['weight'] as num?) ?? double.tryParse('${j['weight']}') ?? 0)
        .toDouble()
        .clamp(0, 1)
        .toDouble(),
    source: '${j['source'] ?? ''}',
  );
  final String id;
  final String kind;
  final String text;
  final double weight;
  final String source;
}

/// Display order and Vietnamese label of each kind.
const memoryKinds = <(String, String, IconData)>[
  ('NOTE', 'Ghi chú của bạn', Symbols.sticky_note_2_rounded),
  ('PREFERENCE', 'Ưu tiên', Symbols.tune_rounded),
  ('ALIAS', 'Từ viết tắt', Symbols.short_text_rounded),
  ('CATEGORY_RULE', 'Cách xếp danh mục', Symbols.category_rounded),
  ('HABIT', 'Thói quen chi tiêu', Symbols.insights_rounded),
  ('PERSON', 'Người quen', Symbols.person_rounded),
];

String memorySourceLabel(String s) => switch (s) {
  'user' => 'Bạn thêm',
  'correction' => 'Học từ lần bạn sửa',
  'undo' => 'Giảm tin cậy sau khi bạn hoàn tác',
  'reflection' => 'Tổng kết hằng đêm',
  _ => 'Học từ cách bạn nói',
};

final aiMemoryProvider = FutureProvider.autoDispose<List<AiMemory>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/ai/memory') as List;
  return [
    for (final m in data)
      AiMemory.fromJson(Map<String, dynamic>.from(m as Map)),
  ];
});

/// Opens the memory page on top of the current route.
Future<void> openAssistantMemory(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const AssistantMemoryPage()));

class AssistantMemoryPage extends ConsumerWidget {
  const AssistantMemoryPage({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final added = await showFormSheet<bool>(
      context,
      (_) => const _AddMemorySheet(),
    );
    if (added == true) {
      ref.invalidate(aiMemoryProvider);
      if (context.mounted) showSnack(context, 'Đã thêm ghi nhớ');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, AiMemory m) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Xóa ghi nhớ này?',
      message: 'Trợ lý sẽ không dùng điều này nữa: "${m.text}"',
      confirmLabel: 'Xóa',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(apiProvider).delete('/ai/memory/${m.id}');
      ref.invalidate(aiMemoryProvider);
      if (context.mounted) showSnack(context, 'Đã xóa ghi nhớ');
    } on ApiException catch (e) {
      if (context.mounted) await showErrorDialog(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(aiMemoryProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Trợ lý đã học được gì',
        showBack: true,
        action: IconButton(
          tooltip: 'Thêm ghi nhớ',
          onPressed: () => _add(context, ref),
          icon: const Icon(Symbols.add_rounded, color: MomaColors.emerald),
        ),
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: MomaColors.emerald),
          ),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(aiMemoryProvider),
          ),
          data: (items) => RefreshIndicator(
            onRefresh: () => ref.refresh(aiMemoryProvider.future),
            child: items.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      EmptyState(
                        embedded: true,
                        icon: Symbols.psychology_rounded,
                        title: 'Trợ lý chưa ghi nhớ điều gì',
                        hint: 'Khi bạn dùng Trợ lý, sửa giao dịch Trợ lý ghi hoặc hoàn tác, Trợ lý sẽ dần hiểu cách bạn chi tiêu. Bạn cũng có thể tự thêm ghi nhớ.',
                        actionLabel: '+ Thêm ghi nhớ',
                        onAction: () => _add(context, ref),
                      ),
                    ],
                  )
                : _MemoryList(
                    items: items,
                    onDelete: (m) => _delete(context, ref, m),
                    onAdd: () => _add(context, ref),
                  ),
          ),
        ),
      ),
    );
  }
}

class _MemoryList extends StatelessWidget {
  const _MemoryList({
    required this.items,
    required this.onDelete,
    required this.onAdd,
  });
  final List<AiMemory> items;
  final void Function(AiMemory) onDelete;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'Trợ lý dùng những điều này để hiểu nhanh hơn. Yêu cầu bạn nói rõ luôn được ưu tiên. Vuốt sang trái hoặc chạm biểu tượng thùng rác để xóa điều sai.',
          style: TextStyle(fontSize: 13, height: 1.45, color: pal.muted),
        ),
        const SizedBox(height: 12),
        for (final (kind, label, icon) in memoryKinds)
          if (items.any((m) => m.kind == kind)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: MomaColors.emerald),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: pal.ink,
                    ),
                  ),
                ],
              ),
            ),
            for (final m in items.where((m) => m.kind == kind))
              _MemoryTile(memory: m, onDelete: () => onDelete(m)),
          ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Symbols.add_rounded),
          label: const Text('Thêm ghi nhớ'),
        ),
      ],
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.memory, required this.onDelete});
  final AiMemory memory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final pct = (memory.weight * 100).round();
    return Dismissible(
      key: ValueKey(memory.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onDelete();
        return false; // the list reloads after a confirmed delete
      },
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: MomaColors.expense.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Symbols.delete_rounded, color: MomaColors.expense),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: pal.lineSoft),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    memory.text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: pal.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Semantics(
                        label: 'Độ tin cậy $pct phần trăm',
                        child: SizedBox(
                          width: 64,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: memory.weight,
                              minHeight: 5,
                              color: MomaColors.emerald,
                              backgroundColor: pal.surfaceAlt,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '$pct% · ${memorySourceLabel(memory.source)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: pal.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Xóa ghi nhớ',
              onPressed: onDelete,
              icon: Icon(Symbols.delete_rounded, color: pal.muted, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

/// "+ Thêm ghi nhớ": a note, a shorthand or a preference. Labels above fields, errors under the field.
class _AddMemorySheet extends ConsumerStatefulWidget {
  const _AddMemorySheet();
  @override
  ConsumerState<_AddMemorySheet> createState() => _AddMemorySheetState();
}

class _AddMemorySheetState extends ConsumerState<_AddMemorySheet> {
  final _form = GlobalKey<FormState>();
  final _key = TextEditingController();
  final _value = TextEditingController();
  late final _run = FormRunner(setState);
  String _kind = 'NOTE';

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final ok = await _run.run(() async {
      await ref.read(apiProvider).post('/ai/memory', {
        'kind': _kind,
        if (_kind == 'ALIAS') 'key': _key.text.trim(),
        'value': _value.text.trim(),
      });
    });
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final alias = _kind == 'ALIAS';
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Thêm ghi nhớ',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: pal.ink,
            ),
          ),
          const SizedBox(height: 16),
          PillTabs<String>(
            segments: const [
              ButtonSegment(value: 'NOTE', label: Text('Ghi chú')),
              ButtonSegment(value: 'ALIAS', label: Text('Viết tắt')),
              ButtonSegment(value: 'PREFERENCE', label: Text('Ưu tiên')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 16),
          if (alias) ...[
            LabeledField(
              key: const ValueKey('memory-key'),
              label: 'Từ viết tắt',
              hint: 'Ví dụ: nc đậu',
              controller: _key,
              required: true,
              maxLength: 40,
              textInputAction: TextInputAction.next,
              validator: V.all([
                V.required('Từ viết tắt'),
                V.maxLength(40, 'Từ viết tắt'),
              ]),
            ),
            const SizedBox(height: 14),
          ],
          LabeledField(
            key: ValueKey('memory-value-$_kind'),
            label: alias ? 'Nghĩa là' : 'Nội dung',
            hint: alias
                ? 'Ví dụ: nước đậu'
                : (_kind == 'NOTE'
                      ? 'Ví dụ: Lương về ngày 5 hằng tháng'
                      : 'Ví dụ: Cà phê luôn trả bằng MoMo'),
            controller: _value,
            required: true,
            maxLength: alias ? 80 : 160,
            maxLines: alias ? 1 : 3,
            validator: V.all([
              V.required(alias ? 'Nghĩa' : 'Nội dung'),
              if (!alias) V.minLength(2, 'Nội dung'),
              V.maxLength(alias ? 80 : 160, alias ? 'Nghĩa' : 'Nội dung'),
              if (alias)
                (v) =>
                    (v ?? '').trim().toLowerCase() ==
                        _key.text.trim().toLowerCase()
                    ? 'Nghĩa phải khác từ viết tắt.'
                    : null,
            ]),
          ),
          FormError(_run.error),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _run.busy ? null : _save,
            child: Text(_run.busy ? 'Đang lưu…' : 'Lưu ghi nhớ'),
          ),
        ],
      ),
    );
  }
}
