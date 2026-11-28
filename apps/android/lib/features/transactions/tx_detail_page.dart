import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import 'transactions_page.dart' show txKindLabel;
import 'tx_sheets.dart' show TxEditSheet;
import '../transfers/transfer_pair_section.dart';
import 'tx_attachments.dart';
import '../planning/debts_view.dart' show openDebt;

/// How a transaction entered the ledger (server column `source`, migration 009).
String txSourceLabel(MomaTx tx) => switch (tx.source) {
  'BANK' => 'Ngân hàng tự động',
  'AI' => 'Trợ lý tài chính',
  'NOTIFICATION' => 'Thông báo ngân hàng trên máy',
  'IMPORT' => 'Nhập từ file',
  'RECURRING' => 'Định kỳ',
  'SYSTEM' => 'Hệ thống',
  _ => 'Thủ công',
};

IconData _sourceIcon(String source) => switch (source) {
  'BANK' => Symbols.account_balance_rounded,
  'AI' => Symbols.auto_awesome_rounded,
  'NOTIFICATION' => Symbols.notifications_rounded,
  'IMPORT' => Symbols.upload_file_rounded,
  'RECURRING' => Symbols.event_repeat_rounded,
  'SYSTEM' => Symbols.settings_rounded,
  _ => Symbols.edit_rounded,
};

/// "Hôm nay, 12:30" / "Hôm qua, 08:05" / "05/11/2026, 21:40".
String txWhenLabel(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(n.year, n.month, n.day);
  final hm =
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hôm nay, $hm';
  if (diff == 1) return 'Hôm qua, $hm';
  return '${dateLabel(d)}, $hm';
}

/// Full-screen transaction detail (route /tx/:id, the tx object is passed as `extra` when known).
/// It follows the live list: after "Chỉnh sửa" (which voids the old row and creates a linked new one)
/// the page switches to the new version.
class TxDetailPage extends ConsumerStatefulWidget {
  const TxDetailPage({super.key, required this.txId, this.initial});
  final String txId;
  final MomaTx? initial;

  @override
  ConsumerState<TxDetailPage> createState() => _TxDetailPageState();
}

class _TxDetailPageState extends ConsumerState<TxDetailPage> {
  late String _id = widget.txId;
  bool _busy = false;

  MomaTx? _resolve(List<MomaTx> items) {
    MomaTx? current;
    for (final t in items) {
      if (t.id == _id) current = t;
    }
    if (current != null && current.isVoid) {
      for (final t in items) {
        if (t.relatedTxId == _id && !t.isVoid) {
          final next = t;
          // Follow the correction so the page shows what the user just saved.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _id = next.id);
          });
          return next;
        }
      }
    }
    if (current != null) return current;
    final init = widget.initial;
    return init != null && init.id == _id ? init : null;
  }

  Future<void> _edit(MomaTx tx) =>
      showFormSheet<void>(context, (_) => TxEditSheet(tx: tx));

  Future<void> _reverse(MomaTx tx) async {
    final reason = await _askReason();
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).command('TX_REVERSE', {
        'tx_id': tx.id,
        'reason': reason,
        'expected_version': tx.version,
      }, commandId: ApiClient.newId());
      if (!mounted) return;
      refreshPlanning(ref);
      showSnack(context, 'Đã hủy giao dịch.');
      Navigator.maybePop(context);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirm dialog with the required cancellation reason (TX_REVERSE needs one).
  Future<String?> _askReason() => showDialog<String>(
    context: context,
    builder: (_) => const _ReasonDialog(),
  );

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showSnack(context, 'Đã sao chép $label.');
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(transactionsProvider);
    final items = list.value?.items ?? const <MomaTx>[];
    final tx = _resolve(items);
    final Widget body;
    if (tx == null) {
      body = list.isLoading
          ? const Center(child: CircularProgressIndicator())
          : const EmptyState(
              icon: Symbols.receipt_long_rounded,
              title: 'Không tìm thấy giao dịch',
              hint: 'Giao dịch có thể đã bị xóa hoặc chưa được tải.',
            );
    } else {
      body = _content(context, tx);
    }
    return Scaffold(
      body: MomaPage(title: 'Chi tiết giao dịch', showBack: true, child: body),
    );
  }

  Widget _content(BuildContext context, MomaTx tx) {
    final pal = context.pal;
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    Category? category;
    for (final c in categories) {
      if (c.id == tx.categoryId) category = c;
    }
    String accountName(String? id) {
      for (final a in accounts) {
        if (a.id == id) return a.name;
      }
      return '—';
    }

    Account? account;
    for (final a in accounts) {
      if (a.id == tx.accountId) account = a;
    }

    final isTransfer = tx.kind == 'TRANSFER';
    final style = categoryStyle(category?.icon);
    final iconData = isTransfer ? Symbols.swap_horiz_rounded : style.icon;
    final tint = isTransfer ? const Color(0xFF2F80ED) : style.color;
    final amountColor = tx.isVoid
        ? pal.muted
        : tx.isIncome
        ? MomaColors.income
        : (tx.isExpense ? MomaColors.expense : pal.ink);
    final sign = tx.isIncome ? '+' : (tx.isExpense ? '-' : '');
    final title = category?.name ?? txKindLabel(tx.kind);
    final editable = !tx.isVoid && tx.kind != 'OPENING';
    final source = txSourceLabel(tx);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: [
              CategoryAvatar(iconData: iconData, color: tint, size: 72),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: pal.muted,
                ),
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$sign${formatVnd(tx.amount)}',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: amountColor,
                    letterSpacing: -0.5,
                    decoration: tx.isVoid ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                txWhenLabel(tx.effectiveAt),
                style: TextStyle(fontSize: 13.5, color: pal.muted),
              ),
              if (tx.isVoid || tx.relatedTxId != null) ...[
                const SizedBox(height: 10),
                _Badge(
                  text: tx.isVoid ? 'Đã hủy (còn lưu lịch sử)' : 'Đã sửa',
                  color: tx.isVoid ? MomaColors.expense : MomaColors.emerald,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: _withDividers(context, [
              if (!isTransfer)
                _DetailRow(
                  icon: category == null
                      ? Symbols.category_rounded
                      : style.icon,
                  color: category == null ? const Color(0xFF64748B) : tint,
                  label: 'Danh mục',
                  value: category?.name ?? 'Chưa phân loại',
                  onTap: editable ? () => _edit(tx) : null,
                ),
              _DetailRow(
                icon: account == null
                    ? Symbols.account_balance_wallet_rounded
                    : accountIcon(account.kind),
                color: const Color(0xFF2F80ED),
                label: isTransfer ? 'Từ tài khoản' : 'Tài khoản',
                value: accountName(tx.accountId),
                onTap: editable ? () => _edit(tx) : null,
              ),
              if (tx.toAccountId != null)
                _DetailRow(
                  icon: Symbols.call_received_rounded,
                  color: const Color(0xFF2F80ED),
                  label: 'Đến tài khoản',
                  value: accountName(tx.toAccountId),
                ),
              if (tx.fee > 0)
                _DetailRow(
                  icon: Symbols.receipt_rounded,
                  color: const Color(0xFFFF8A3D),
                  label: 'Phí',
                  value: formatVnd(tx.fee),
                ),
              _DetailRow(
                icon: _sourceIcon(tx.source),
                color: const Color(0xFF8B5CF6),
                label: 'Nguồn ghi nhận',
                value: source,
              ),
              _DetailRow(
                icon: Symbols.label_rounded,
                color: const Color(0xFF64748B),
                label: 'Loại',
                value: txKindLabel(tx.kind),
              ),
              if ((tx.merchant ?? '').isNotEmpty)
                _DetailRow(
                  icon: Symbols.storefront_rounded,
                  color: const Color(0xFF1B8A5A),
                  label: 'Nơi chi/thu',
                  value: tx.merchant!,
                  onCopy: () => _copy('nơi chi/thu', tx.merchant!),
                ),
              _DetailRow(
                icon: Symbols.notes_rounded,
                color: const Color(0xFF0C6A54),
                label: 'Ghi chú',
                value: (tx.note ?? '').isEmpty ? 'Không có' : tx.note!,
                onCopy: (tx.note ?? '').isEmpty
                    ? null
                    : () => _copy('ghi chú', tx.note!),
                onTap: (tx.note ?? '').isEmpty && editable
                    ? () => _edit(tx)
                    : null,
              ),
            ]),
          ),
        ),
        if (isTransfer && !tx.isVoid) TransferPairSection(txId: tx.id),
        // Receipts / transfer screenshots kept as evidence (also allowed on cancelled rows, to view old proof).
        TxAttachmentsSection(txId: tx.id, canAdd: !tx.isVoid),
        if (tx.debtLinked) ...[
          const SizedBox(height: 12),
          Text(
            'Giao dịch này thuộc một khoản công nợ nên chỉ sửa được ghi chú. '
            'Muốn sửa số tiền hoặc hủy, hãy thao tác trong mục Công nợ.',
            style: TextStyle(color: pal.muted, fontSize: 13, height: 1.45),
          ),
          if (tx.debtId != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => openDebt(context, tx.debtId!),
              icon: const Icon(Symbols.handshake_rounded),
              label: const Text('Mở khoản nợ'),
            ),
          ],
        ],
        if (editable) ...[
          const SizedBox(height: 20),
          ActionButtons(
            secondaryLabel: 'Chỉnh sửa',
            onSecondary: () => _edit(tx),
            primaryLabel: 'Hủy giao dịch',
            destructive: true,
            busy: _busy,
            onPrimary: tx.debtLinked ? null : () => _reverse(tx),
          ),
        ],
      ],
    );
  }
}

List<Widget> _withDividers(BuildContext context, List<Widget> rows) => [
  for (final (i, r) in rows.indexed) ...[
    r,
    if (i < rows.length - 1)
      Divider(height: 1, indent: 64, color: context.pal.lineSoft),
  ],
];

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.onTap,
    this.onCopy,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 12.5, color: pal.muted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: pal.ink,
                    ),
                  ),
                ],
              ),
            ),
            if (onCopy != null)
              IconButton(
                tooltip: 'Sao chép',
                onPressed: onCopy,
                icon: Icon(Symbols.content_copy_rounded, color: pal.muted),
                iconSize: 20,
              ),
            if (onTap != null)
              Icon(Symbols.chevron_right_rounded, color: pal.muted)
            else if (onCopy == null)
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// Owns its controller so it is disposed only after the dialog's exit animation.
class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _ctrl = TextEditingController(text: 'Nhập nhầm');
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: context.pal.surface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    title: const Text(
      'Hủy giao dịch?',
      style: TextStyle(fontWeight: FontWeight.w800),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Giao dịch sẽ được đánh dấu đã hủy và số dư được hoàn lại. '
          'Lịch sử vẫn được lưu để đối chiếu.',
          style: TextStyle(color: context.pal.muted, height: 1.45),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            prefixIcon: const Icon(Symbols.edit_note_rounded),
            labelText: 'Lý do hủy',
            errorText: _error,
          ),
        ),
      ],
    ),
    actions: [
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Không'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MomaColors.expense,
              ),
              onPressed: () {
                final r = _ctrl.text.trim();
                if (r.isEmpty) {
                  setState(() => _error = 'Cần nhập lý do.');
                  return;
                }
                Navigator.of(context).pop(r);
              },
              child: const Text('Hủy giao dịch'),
            ),
          ),
        ],
      ),
    ],
  );
}
