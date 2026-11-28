import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/category_style.dart';
import '../../core/widgets.dart';

// "Chọn loại nhanh" (D-020): money the classifier could not place with confidence. The system already knows the
// account, amount, time and description; the owner only picks the category (one tap) and may add a note.

class ClassifySuggestion {
  const ClassifySuggestion({
    required this.categoryId,
    required this.name,
    required this.confidence,
    required this.reason,
  });
  factory ClassifySuggestion.fromJson(Map<String, dynamic> j) =>
      ClassifySuggestion(
        categoryId: '${j['category_id']}',
        name: '${j['name'] ?? ''}',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        reason: '${j['reason'] ?? ''}',
      );
  final String categoryId;
  final String name;
  final double confidence;
  final String reason;
}

class UnclearTx {
  const UnclearTx({
    required this.id,
    required this.kind,
    required this.amount,
    required this.at,
    required this.version,
    required this.accountName,
    required this.institution,
    required this.note,
    required this.merchant,
    required this.suggestions,
  });
  factory UnclearTx.fromJson(Map<String, dynamic> j) => UnclearTx(
    id: '${j['id']}',
    kind: '${j['kind']}',
    amount: parseVnd('${j['amount'] ?? '0'}'),
    at: DateTime.tryParse('${j['effective_at']}')?.toLocal() ?? DateTime.now(),
    version: (j['version'] as num?)?.toInt() ?? 1,
    accountName: '${j['account_name'] ?? ''}',
    institution: '${j['institution'] ?? ''}',
    note: (j['note'] as String?)?.trim(),
    merchant:
        (j['merchant'] as String?)?.trim() ??
        (j['suggested_merchant'] as String?)?.trim(),
    suggestions: [
      for (final s in (j['suggestions'] as List? ?? const []))
        ClassifySuggestion.fromJson((s as Map).cast<String, dynamic>()),
    ],
  );

  final String id;
  final String kind;
  final int amount;
  final DateTime at;
  final int version;
  final String accountName;
  final String institution;
  final String? note;
  final String? merchant;
  final List<ClassifySuggestion> suggestions;

  bool get isIncome => kind == 'UNKNOWN_CREDIT' || kind == 'INCOME';
  String get categoryType => isIncome ? 'INCOME' : 'EXPENSE';
}

class UnclearList {
  const UnclearList({this.total = 0, this.items = const []});
  final int total;
  final List<UnclearTx> items;
}

/// Unclear money waiting for a category. Never fails the screens that show it: an older server shows nothing.
final unclearProvider = FutureProvider.autoDispose<UnclearList>((ref) async {
  try {
    final r = await ref.watch(apiProvider).get('/ai/classify/pending');
    final m = (r as Map).cast<String, dynamic>();
    return UnclearList(
      total: (m['total'] as num?)?.toInt() ?? 0,
      items: [
        for (final e in (m['items'] as List? ?? const []))
          UnclearTx.fromJson((e as Map).cast<String, dynamic>()),
      ],
    );
  } catch (_) {
    return const UnclearList();
  }
});

/// Suggested category for a description while typing (quick entry). Null when nothing fits or offline.
Future<ClassifySuggestion?> suggestCategory(
  ApiClient api,
  String text, {
  required bool income,
  int? amount,
}) async {
  try {
    final r = await api.post('/ai/classify/suggest', {
      'text': text,
      'direction': income ? 'in' : 'out',
      'amount': ?amount,
    });
    if (r is! Map) return null;
    final m = r.cast<String, dynamic>();
    return ClassifySuggestion(
      categoryId: '${m['category_id']}',
      name: '',
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      reason: '${m['reason'] ?? ''}',
    );
  } catch (_) {
    return null;
  }
}

String _when(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final now = DateTime.now();
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return 'Hôm nay, $hm';
  }
  return '${two(t.day)}/${two(t.month)}, $hm';
}

/// Home / bell banner: "N khoản cần chọn loại" (hidden when nothing is waiting).
class UnclearBanner extends ConsumerWidget {
  const UnclearBanner({super.key, this.margin = EdgeInsets.zero});
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unclearProvider).value?.total ?? 0;
    if (n == 0) return const SizedBox.shrink();
    final pal = context.pal;
    return Padding(
      padding: margin,
      child: Material(
        color: pal.warnBg,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => context.push('/classify'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Icon(Symbols.help_rounded, color: pal.warnInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$n khoản cần chọn loại',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: pal.warnInk,
                        ),
                      ),
                      Text(
                        'Chỉ cần chạm chọn loại, phần còn lại MoMa đã điền.',
                        style: TextStyle(fontSize: 12.5, color: pal.warnInk),
                      ),
                    ],
                  ),
                ),
                Icon(Symbols.chevron_right_rounded, color: pal.warnInk),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One card per unclear transaction; a tap on a category saves it (TX_ANNOTATE, same transaction) and moves on.
class QuickClassifyPage extends ConsumerStatefulWidget {
  const QuickClassifyPage({super.key});
  @override
  ConsumerState<QuickClassifyPage> createState() => _QuickClassifyPageState();
}

class _QuickClassifyPageState extends ConsumerState<QuickClassifyPage> {
  final _done = <String>{};
  int _saved = 0;
  String? _busyId;
  bool _noteOpen = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick(UnclearTx t, String categoryId) async {
    if (_busyId != null) return;
    setState(() => _busyId = t.id);
    final note = _note.text.trim();
    try {
      await ref.read(apiProvider).command('TX_ANNOTATE', {
        'tx_id': t.id,
        'expected_version': t.version,
        'category_id': categoryId,
        if (note.isNotEmpty) 'note': note,
      }, commandId: ApiClient.newId());
      if (!mounted) return;
      setState(() {
        _done.add(t.id);
        _saved++;
        _noteOpen = false;
        _note.clear();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'VERSION_CONFLICT' || e.code == 'INVALID_STATE') {
        // Changed elsewhere (or already classified): skip it and reload the list.
        setState(() => _done.add(t.id));
        ref.invalidate(unclearProvider);
      } else {
        await showErrorDialog(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _other(UnclearTx t) async {
    final cats = (ref.read(categoriesProvider).value ?? const <Category>[])
        .where((c) => c.type == t.categoryType)
        .toList();
    final id = await showChoiceSheet<String>(
      context,
      title: 'Chọn loại',
      searchable: cats.length > 8,
      options: [
        for (final c in cats)
          ChoiceOption(
            value: c.id,
            label: c.name,
            leading: CategoryAvatar(iconKey: c.icon, size: 34),
          ),
      ],
    );
    if (id != null && mounted) await _pick(t, id);
  }

  void _finish() {
    refreshAll(ref);
    ref.invalidate(unclearProvider);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(unclearProvider);
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final left = (async.value?.items ?? const <UnclearTx>[])
        .where((t) => !_done.contains(t.id))
        .toList();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _saved > 0) refreshAll(ref);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chọn loại nhanh'),
          actions: [
            if (left.length > 1)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    'Còn ${left.length}',
                    style: TextStyle(color: context.pal.muted),
                  ),
                ),
              ),
          ],
        ),
        body: async.isLoading && async.value == null
            ? const Center(child: CircularProgressIndicator())
            : left.isEmpty
            ? _AllDone(saved: _saved, onClose: _finish)
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(unclearProvider);
                  await ref.read(unclearProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _Card(
                      key: ValueKey(left.first.id),
                      tx: left.first,
                      categories: cats,
                      busy: _busyId == left.first.id,
                      noteOpen: _noteOpen,
                      note: _note,
                      onToggleNote: () =>
                          setState(() => _noteOpen = !_noteOpen),
                      onPick: (id) => _pick(left.first, id),
                      onOther: () => _other(left.first),
                      onSkip: left.length > 1
                          ? () => setState(() => _done.add(left.first.id))
                          : null,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.tx,
    required this.categories,
    required this.busy,
    required this.noteOpen,
    required this.note,
    required this.onToggleNote,
    required this.onPick,
    required this.onOther,
    this.onSkip,
  });
  final UnclearTx tx;
  final List<Category> categories;
  final bool busy;
  final bool noteOpen;
  final TextEditingController note;
  final VoidCallback onToggleNote;
  final ValueChanged<String> onPick;
  final VoidCallback onOther;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final byId = {for (final c in categories) c.id: c};
    final where = tx.institution.isNotEmpty ? tx.institution : tx.accountName;
    final raw = [
      tx.merchant,
      tx.note,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${tx.isIncome ? '+' : '-'}${formatVnd(tx.amount)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: tx.isIncome ? MomaColors.income : MomaColors.expense,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$where · ${_when(tx.at)}',
            textAlign: TextAlign.center,
            style: TextStyle(color: pal.muted, fontSize: 13.5),
          ),
          if (raw.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pal.surfaceAlt,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                raw,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: pal.ink, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            tx.isIncome ? 'Khoản tiền vào này là gì?' : 'Khoản chi này là gì?',
            style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
          ),
          const SizedBox(height: 10),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.6,
              children: [
                for (final (i, s) in tx.suggestions.indexed)
                  _ChipButton(
                    label: s.name,
                    iconKey: byId[s.categoryId]?.icon,
                    highlighted: i == 0 && s.confidence > 0,
                    onTap: () => onPick(s.categoryId),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onOther,
              icon: const Icon(Symbols.more_horiz_rounded),
              label: const Text('Khác…'),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: onToggleNote,
                icon: Icon(
                  noteOpen
                      ? Symbols.expand_less_rounded
                      : Symbols.edit_note_rounded,
                ),
                label: const Text('Thêm ghi chú'),
              ),
              const Spacer(),
              if (onSkip != null)
                TextButton(onPressed: onSkip, child: const Text('Để sau')),
            ],
          ),
          if (noteOpen)
            TextField(
              controller: note,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: 'Ví dụ: tiền điện tháng 11 (không bắt buộc)',
              ),
            ),
          if (tx.suggestions.isNotEmpty &&
              tx.suggestions.first.reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Gợi ý: ${tx.suggestions.first.reason}',
                style: TextStyle(fontSize: 12, color: pal.hint),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.label,
    required this.onTap,
    this.iconKey,
    this.highlighted = false,
  });
  final String label;
  final String? iconKey;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Material(
      color: highlighted ? pal.tint : pal.surfaceAlt,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              CategoryAvatar(iconKey: iconKey, size: 30),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: highlighted ? pal.accentInk : pal.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone({required this.saved, required this.onClose});
  final int saved;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.task_alt_rounded, size: 64, color: pal.accentInk),
            const SizedBox(height: 12),
            Text(
              saved > 0
                  ? 'Đã phân loại $saved khoản'
                  : 'Không còn khoản nào cần chọn loại',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'MoMa ghi nhớ lựa chọn của bạn để lần sau tự phân loại.',
              textAlign: TextAlign.center,
              style: TextStyle(color: pal.muted),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onClose, child: const Text('Xong')),
          ],
        ),
      ),
    );
  }
}
