import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';
import 'split_api.dart';
import 'split_models.dart';
import 'split_sheet.dart';

/// After a picture is added to a transaction: read it on the phone, let the server update category / merchant /
/// items note (undo in the snackbar), flag a total that differs, and propose a split for a group bill.
/// Silent when nothing readable or offline (the picture itself is already saved).
Future<void> runBillAnalysis(
  BuildContext context,
  WidgetRef ref,
  MomaTx tx,
  Uint8List bytes,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final String text;
  try {
    text = await ref.read(billTextReaderProvider)(bytes);
  } catch (_) {
    return;
  }
  if (text.trim().length < 8) return;
  final BillAnalysis a;
  try {
    a = await ref.read(splitApiProvider).analyzeBill(tx.id, text);
  } on ApiException {
    return;
  } catch (_) {
    return;
  }
  ref.read(billAnalysisProvider.notifier).set(tx.id, a);
  refreshAll(ref);
  ref.invalidate(txSplitsProvider(tx.id));
  ref.invalidate(pendingSplitsProvider);
  final upd = a.updated;
  if (upd != null && messenger != null) {
    List<Category> cats;
    try {
      cats = await ref.read(categoriesProvider.future);
    } catch (_) {
      cats = const <Category>[];
    }
    final catName = cats
        .where((c) => c.id == upd['category_id'])
        .map((c) => c.name)
        .firstOrNull;
    final parts = [
      ?catName,
      if (upd['merchant'] is String) upd['merchant'] as String,
      if (upd['note'] is String) upd['note'] as String,
    ];
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Đã cập nhật: ${parts.join(' · ')}'),
          action: SnackBarAction(
            label: 'Hoàn tác',
            onPressed: () => _undoBillUpdate(ref, tx.id, upd),
          ),
        ),
      );
  }
}

/// Puts back what the bill reading replaced (category when there was one, the previous note).
Future<void> _undoBillUpdate(
  WidgetRef ref,
  String txId,
  Map<String, dynamic> upd,
) async {
  final prev = (upd['previous'] as Map?)?.cast<String, dynamic>() ?? const {};
  try {
    final list = await ref.read(transactionsProvider.future);
    final cur = list.items.where((t) => t.id == txId).firstOrNull;
    if (cur == null) return;
    await ref.read(apiProvider).command('TX_ANNOTATE', {
      'tx_id': txId,
      'expected_version': cur.version,
      if (upd['category_id'] != null && prev['category_id'] is String)
        'category_id': prev['category_id'],
      if (upd['note'] != null) 'note': '${prev['note'] ?? ''}',
      if (upd['merchant'] != null && prev['merchant'] is String)
        'merchant': prev['merchant'],
    }, commandId: ApiClient.newId());
    refreshAll(ref);
  } catch (_) {}
}

/// Bill reading results + the split of this expense, under "Ảnh chứng từ" on the detail page.
class TxSplitCard extends ConsumerWidget {
  const TxSplitCard({super.key, required this.tx});
  final MomaTx tx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tx.isVoid) return const SizedBox.shrink();
    final analysis = ref.watch(billAnalysisProvider)[tx.id];
    final splits = tx.isExpense
        ? ref.watch(txSplitsProvider(tx.id)).value ?? const <SplitApplication>[]
        : const <SplitApplication>[];
    final live = splits.where((s) => s.applied || s.proposed).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (analysis?.suggestion != null)
          _BillSuggestionCard(tx: tx, suggestion: analysis!.suggestion!),
        if (analysis?.mismatch == true)
          _MismatchCard(tx: tx, billTotal: analysis!.billTotal!),
        if (live != null && live.applied)
          _AppliedCard(split: live)
        else if (live != null && live.proposed)
          ProposalCard(split: live, tx: tx)
        else if (tx.isExpense)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextButton.icon(
                onPressed: () => showFormSheet<void>(
                  context,
                  (_) => SplitSheet(txId: tx.id, total: tx.amount),
                ),
                icon: const Icon(Symbols.call_split_rounded),
                label: const Text('Chia tiền với người khác'),
              ),
            ),
          ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    required this.icon,
    required this.title,
    required this.children,
    this.tint,
  });
  final IconData icon;
  final String title;
  final List<Widget> children;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: tint ?? pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: pal.accentInk, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: pal.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}

Widget _muted(BuildContext context, String text) => Text(
  text,
  style: TextStyle(fontSize: 13.5, height: 1.4, color: context.pal.muted),
);

class _BillSuggestionCard extends ConsumerStatefulWidget {
  const _BillSuggestionCard({required this.tx, required this.suggestion});
  final MomaTx tx;
  final Map<String, dynamic> suggestion;
  @override
  ConsumerState<_BillSuggestionCard> createState() =>
      _BillSuggestionCardState();
}

class _BillSuggestionCardState extends ConsumerState<_BillSuggestionCard> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    final s = widget.suggestion;
    try {
      await ref.read(apiProvider).command('TX_ANNOTATE', {
        'tx_id': widget.tx.id,
        'expected_version': widget.tx.version,
        'category_id': ?(s['category_id'] as String?),
        'merchant': ?(s['merchant'] as String?),
        'note': ?(s['note'] as String?),
      }, commandId: ApiClient.newId());
      ref.read(billAnalysisProvider.notifier).clear(widget.tx.id);
      refreshAll(ref);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final s = widget.suggestion;
    final cat = cats
        .where((c) => c.id == s['category_id'])
        .map((c) => c.name)
        .firstOrNull;
    final parts = [?cat, ?(s['merchant'] as String?), ?(s['note'] as String?)];
    return _Box(
      icon: Symbols.receipt_long_rounded,
      title: 'Theo hóa đơn: ${parts.join(' · ')}',
      children: [
        _muted(context, 'Đúng thì chạm "Cập nhật", MoMa sẽ nhớ cho lần sau.'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : _accept,
              child: const Text('Cập nhật'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => ref
                        .read(billAnalysisProvider.notifier)
                        .clear(widget.tx.id),
              child: const Text('Bỏ qua'),
            ),
          ],
        ),
      ],
    );
  }
}

class _MismatchCard extends ConsumerStatefulWidget {
  const _MismatchCard({required this.tx, required this.billTotal});
  final MomaTx tx;
  final int billTotal;
  @override
  ConsumerState<_MismatchCard> createState() => _MismatchCardState();
}

class _MismatchCardState extends ConsumerState<_MismatchCard> {
  bool _busy = false;

  /// One tap: the bill's total becomes the amount (same correction as "Chỉnh sửa", history kept).
  Future<void> _fix() async {
    final t = widget.tx;
    if (t.accountId == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).command('TX_CORRECT', {
        'tx_id': t.id,
        'reason': 'Sửa theo hóa đơn',
        'expected_version': t.version,
        'replacement': {
          'kind': t.kind,
          'account_id': t.accountId,
          'amount': '${widget.billTotal}',
          'effective_at': t.rawEffectiveAt,
          'category_id': ?t.categoryId,
          'to_account_id': ?t.toAccountId,
          if ((t.note ?? '').isNotEmpty) 'note': t.note,
          if ((t.merchant ?? '').isNotEmpty) 'merchant': t.merchant,
          if (t.fee > 0) 'fee': '${t.fee}',
        },
      }, commandId: ApiClient.newId());
      ref.read(billAnalysisProvider.notifier).clear(t.id);
      refreshPlanning(ref);
      if (mounted) showSnack(context, 'Đã sửa số tiền theo hóa đơn.');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Box(
      icon: Symbols.error_rounded,
      tint: context.pal.warnBg,
      title: 'Hóa đơn ghi ${formatVnd(widget.billTotal)}',
      children: [
        _muted(
          context,
          'Giao dịch đang ghi ${formatVnd(widget.tx.amount)}. MoMa không tự đổi số tiền.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : _fix,
              child: Text('Sửa thành ${formatVnd(widget.billTotal)}'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => ref
                        .read(billAnalysisProvider.notifier)
                        .clear(widget.tx.id),
              child: const Text('Giữ nguyên'),
            ),
          ],
        ),
      ],
    );
  }
}

class _AppliedCard extends ConsumerStatefulWidget {
  const _AppliedCard({required this.split});
  final SplitApplication split;
  @override
  ConsumerState<_AppliedCard> createState() => _AppliedCardState();
}

class _AppliedCardState extends ConsumerState<_AppliedCard> {
  bool _busy = false;

  Future<void> _undo() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hoàn tác chia tiền?'),
        content: const Text(
          'Các khoản nợ của lần chia này sẽ bị xóa (lịch sử vẫn giữ).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Giữ lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            style: TextButton.styleFrom(foregroundColor: MomaColors.expense),
            child: const Text('Hoàn tác'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(splitApiProvider).undo(widget.split.id);
      refreshSplits(ref, widget.split.txId);
      if (mounted) showSnack(context, 'Đã hoàn tác chia tiền.');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.split;
    final title = s.recurringName != null
        ? 'Đã khớp ${s.recurringName}'
        : 'Đã chia tiền';
    return _Box(
      icon: Symbols.call_split_rounded,
      title: title,
      children: [
        if (s.shares.isNotEmpty)
          _muted(
            context,
            [
              for (final x in s.shares) '${x.name} nợ ${formatVnd(x.amount)}',
              if (s.ownerAmount > 0) 'Bạn ${formatVnd(s.ownerAmount)}',
            ].join(' · '),
          ),
        if (s.canUndo)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : _undo,
              child: const Text('Hoàn tác'),
            ),
          )
        else if (s.shares.isNotEmpty)
          _muted(
            context,
            'Đã có người trả lại, muốn hoàn tác hãy hủy lần trả đó trong Công nợ.',
          ),
      ],
    );
  }
}

/// "Chia 1.240.000đ? [Xác nhận] [Sửa] [Không chia]" — also shown in the bell. Empty proposals (a group bill without
/// names) offer the usual group and "Chọn người…".
class ProposalCard extends ConsumerStatefulWidget {
  const ProposalCard({super.key, required this.split, this.tx});
  final SplitApplication split;
  final MomaTx? tx;
  @override
  ConsumerState<ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends ConsumerState<ProposalCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      await job();
      refreshSplits(ref, widget.split.txId);
      if (mounted) showSnack(context, done);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit({List<String> people = const []}) => showFormSheet<void>(
    context,
    (_) => SplitSheet(
      txId: widget.split.txId,
      total: widget.split.total,
      applicationId: widget.split.id,
      categoryId: widget.split.categoryId,
      initial: widget.split.shares,
      preselect: people,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.split;
    final api = ref.read(splitApiProvider);
    final title = s.recurringName != null
        ? 'Có phải ${s.recurringName}? ${formatVnd(s.total)}'
        : 'Chia ${formatVnd(s.total)}?';
    final contacts = ref.watch(contactsProvider).value ?? const [];
    final group = s.shares.isEmpty
        ? usualGroup(
            ref.watch(recentSplitsProvider).value ?? const [],
            contacts,
          )
        : const [];
    return _Box(
      icon: Symbols.call_split_rounded,
      title: title,
      children: [
        if (s.shares.isNotEmpty)
          _muted(
            context,
            splitPreviewLine(
              [for (final x in s.shares) x.name],
              [for (final x in s.shares) x.amount],
              s.ownerAmount,
            ),
          )
        else
          _muted(context, 'Hóa đơn này có vẻ ăn chung. Chia cho ai?'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (s.shares.isNotEmpty) ...[
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => api.apply(txId: s.txId, applicationId: s.id),
                        'Đã chia tiền.',
                      ),
                child: const Text('Xác nhận'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _edit(),
                child: const Text('Sửa'),
              ),
            ] else ...[
              if (group.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Symbols.group_rounded, size: 18),
                  label: Text(
                    'Nhóm hay đi: ${group.map((c) => c.alias).join(', ')}',
                  ),
                  onPressed: _busy
                      ? null
                      : () => _edit(people: [for (final c in group) c.id]),
                ),
              OutlinedButton(
                onPressed: _busy ? null : () => _edit(),
                child: const Text('Chọn người…'),
              ),
            ],
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => api.dismiss(s.id), 'Đã bỏ qua.'),
              child: const Text('Không chia'),
            ),
          ],
        ),
      ],
    );
  }
}
