import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import 'transfers_data.dart';

/// One payment seen twice (server: migration 018), e.g. the VCB debit and the MoMo "thanh toán thành công" for the
/// same purchase, or a notification the app posted again. [keep] stays, [dup] is merged into it.
class SamePayment {
  SamePayment({
    required this.id,
    required this.state,
    required this.keep,
    required this.dup,
    this.score = 0,
    this.hints = const [],
    this.canUndo = false,
  });

  factory SamePayment.fromJson(Map<String, dynamic> j) => SamePayment(
    id: j['id'] as String,
    state: (j['state'] as String?) ?? 'SUGGESTED',
    score: (j['score'] as num?)?.toInt() ?? 0,
    hints: [for (final h in (j['hints'] as List? ?? const [])) '$h'],
    keep: j['keep'] is Map<String, dynamic>
        ? TransferLeg.fromJson(j['keep'] as Map<String, dynamic>)
        : null,
    dup: j['dup'] is Map<String, dynamic>
        ? TransferLeg.fromJson(j['dup'] as Map<String, dynamic>)
        : null,
    canUndo: j['can_undo'] == true,
  );

  final String id;

  /// AUTO, CONFIRMED, REJECTED or SUGGESTED.
  final String state;
  final int score;
  final List<String> hints;
  final TransferLeg? keep;
  final TransferLeg? dup;
  final bool canUndo;

  bool get isMerged => state == 'AUTO' || state == 'CONFIRMED';
  bool get sameAccount =>
      keep != null && dup != null && keep!.accountId == dup!.accountId;
  int get amount => (keep ?? dup)?.amount ?? 0;
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String legName(TransferLeg l) =>
    l.accountName.isNotEmpty ? l.accountName : l.institution;

/// "Có thể trùng: VCB -45.000đ và MoMo -45.000đ (12:03)".
String samePaymentTitle(SamePayment s) {
  final k = s.keep!, d = s.dup!;
  if (s.sameAccount) {
    return 'Có thể trùng: ${legName(k)} ${formatVnd(s.amount)} ghi 2 lần (${_hm(k.effectiveAt)})';
  }
  return 'Có thể trùng: ${legName(k)} -${formatVnd(s.amount)} và ${legName(d)} -${formatVnd(s.amount)} (${_hm(k.effectiveAt)})';
}

/// Duplicates waiting for the owner's decision. Empty on any error, so the bell never breaks because of it.
final duplicateSuggestionsProvider =
    FutureProvider.autoDispose<List<SamePayment>>((ref) async {
      try {
        final data = await ref
            .watch(apiProvider)
            .get('/duplicates/suggestions');
        return [
          for (final e in (data as List<dynamic>? ?? const []))
            if (e is Map<String, dynamic>) SamePayment.fromJson(e),
        ].where((s) => s.keep != null && s.dup != null).toList();
      } catch (_) {
        return const [];
      }
    });

/// The merge a transaction took part in, or null.
final duplicateForTxProvider = FutureProvider.autoDispose
    .family<SamePayment?, String>((ref, txId) async {
      try {
        final data = await ref
            .watch(apiProvider)
            .get('/transactions/$txId/duplicate');
        return data is Map<String, dynamic> ? SamePayment.fromJson(data) : null;
      } catch (_) {
        return null;
      }
    });

/// Gộp (accept=true) keeps one transaction; Không trùng (false) keeps both and never asks again for that pair.
Future<void> decideDuplicate(
  WidgetRef ref,
  String id, {
  required bool accept,
}) async {
  await ref.read(apiProvider).post('/duplicates/$id/decide', {
    'accept': accept,
  });
  ref.invalidate(duplicateSuggestionsProvider);
  if (accept) refreshAll(ref);
}

/// "Tách ra": the merged copy comes back as its own transaction.
Future<void> undoDuplicate(WidgetRef ref, String id) async {
  await ref.read(apiProvider).post('/duplicates/$id/undo', const {});
  ref.invalidate(duplicateSuggestionsProvider);
  ref.invalidate(duplicateForTxProvider);
  refreshAll(ref);
}

Future<void> showDuplicateSuggestionsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const DuplicateSuggestionsSheet(),
    );

/// Each possible duplicate: both copies (account, time, content) with [Gộp] / [Không trùng].
class DuplicateSuggestionsSheet extends ConsumerStatefulWidget {
  const DuplicateSuggestionsSheet({super.key});
  @override
  ConsumerState<DuplicateSuggestionsSheet> createState() =>
      _DuplicateSuggestionsSheetState();
}

class _DuplicateSuggestionsSheetState
    extends ConsumerState<DuplicateSuggestionsSheet> {
  final Set<String> _busy = {};

  Future<void> _decide(SamePayment s, bool accept) async {
    setState(() => _busy.add(s.id));
    try {
      await decideDuplicate(ref, s.id, accept: accept);
      if (mounted) {
        showSnack(
          context,
          accept ? 'Đã gộp thành một giao dịch.' : 'Đã giữ cả hai giao dịch.',
        );
      }
    } catch (e) {
      if (mounted) await showErrorDialog(context, transferErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(s.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list = ref.watch(duplicateSuggestionsProvider).value ?? const [];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              'Khoản bị ghi trùng?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Cùng số tiền, gần cùng lúc: có thể là một lần trả tiền được báo 2 lần (ví dụ ngân hàng và MoMo). '
              'Gộp để chỉ tính một lần.',
              style: TextStyle(fontSize: 13, color: pal.muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Không còn khoản nào cần xem.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: pal.muted),
                ),
              ),
            for (final s in list)
              DuplicateTile(
                item: s,
                busy: _busy.contains(s.id),
                onMerge: () => _decide(s, true),
                onKeep: () => _decide(s, false),
              ),
          ],
        ),
      ),
    );
  }
}

class DuplicateTile extends StatelessWidget {
  const DuplicateTile({
    super.key,
    required this.item,
    required this.busy,
    required this.onMerge,
    required this.onKeep,
  });
  final SamePayment item;
  final bool busy;
  final VoidCallback onMerge;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    Widget leg(TransferLeg l, String role) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.receipt_long_rounded, size: 18, color: pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$role · ${legName(l)} · ${_hm(l.effectiveAt)}${l.content.isEmpty ? '' : '\n${l.content}'}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: pal.muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            samePaymentTitle(item),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
              color: pal.ink,
            ),
          ),
          leg(item.keep!, 'Giữ'),
          leg(item.dup!, 'Gộp vào'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onKeep,
                  child: const Text('Không trùng'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onMerge,
                  child: const Text('Gộp'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Transaction detail: "Đã gộp khoản trùng từ MoMo · Tách ra" on the kept transaction, "Đã gộp vào giao dịch ở
/// VCB · Mở" on the merged-away copy. Nothing while loading, on error or when there was no merge.
class DuplicateSection extends ConsumerStatefulWidget {
  const DuplicateSection({super.key, required this.txId});
  final String txId;
  @override
  ConsumerState<DuplicateSection> createState() => _DuplicateSectionState();
}

class _DuplicateSectionState extends ConsumerState<DuplicateSection> {
  bool _busy = false;

  Future<void> _split(SamePayment s) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Tách ra?',
      message:
          'Khoản ở ${legName(s.dup!)} sẽ được ghi lại thành giao dịch riêng như trước. '
          'MoMa sẽ không tự gộp hai giao dịch này nữa.',
      confirmLabel: 'Tách ra',
      cancelLabel: 'Không',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await undoDuplicate(ref, s.id);
      if (mounted) showSnack(context, 'Đã tách thành hai giao dịch.');
    } catch (e) {
      if (mounted) await showErrorDialog(context, transferErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(duplicateForTxProvider(widget.txId)).value;
    if (s == null || !s.isMerged || s.keep == null || s.dup == null) {
      return const SizedBox.shrink();
    }
    final pal = context.pal;
    final isKeep = s.keep!.txId == widget.txId;
    final title = isKeep
        ? 'Đã gộp khoản trùng từ ${legName(s.dup!)}'
        : 'Đã gộp vào giao dịch ở ${legName(s.keep!)}';
    final detail = isKeep
        ? 'Cùng một lần trả tiền được báo 2 lần nên MoMa chỉ tính một lần.'
        : 'Khoản này là bản trùng nên không còn được tính.';
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: pal.tintSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Symbols.call_merge_rounded,
              color: pal.accentInk,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: pal.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: pal.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (isKeep && s.canUndo)
            TextButton(
              onPressed: _busy ? null : () => _split(s),
              child: const Text('Tách ra'),
            )
          else if (!isKeep)
            TextButton(
              onPressed: () => context.push('/tx/${s.keep!.txId}'),
              child: const Text('Mở'),
            ),
        ],
      ),
    );
  }
}
