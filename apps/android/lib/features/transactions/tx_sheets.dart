import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import 'transactions_page.dart' show txKindLabel;
import '../../app/theme/palette.dart';

String _accountName(List<Account> accounts, String? id) {
  for (final a in accounts) {
    if (a.id == id) return a.name;
  }
  return '—';
}

class TxDetailSheet extends ConsumerStatefulWidget {
  const TxDetailSheet({super.key, required this.tx, required this.category});
  final MomaTx tx;
  final Category? category;
  @override
  ConsumerState<TxDetailSheet> createState() => _TxDetailSheetState();
}

class _TxDetailSheetState extends ConsumerState<TxDetailSheet> {
  late final FormRunner _run = FormRunner(setState);
  final _reason = TextEditingController(text: 'Nhập nhầm');
  bool _cancelling = false;
  final String _reverseId = ApiClient.newId();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _reverse() async {
    if (_reason.text.trim().isEmpty) {
      setState(() => _run.error = 'Cần nhập lý do.');
      return;
    }
    final tx = widget.tx;
    final ok = await _run.run(
      () => ref.read(apiProvider).command('TX_REVERSE', {
        'tx_id': tx.id,
        'reason': _reason.text.trim(),
        'expected_version': tx.version,
      }, commandId: _reverseId),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    final accounts = ref.watch(accountsProvider).value ?? <Account>[];
    final d = tx.effectiveAt;
    final rows = <(String, String)>[
      ('Loại', txKindLabel(tx.kind)),
      ('Tài khoản', _accountName(accounts, tx.accountId)),
      if (tx.toAccountId != null)
        ('Đến tài khoản', _accountName(accounts, tx.toAccountId)),
      if (widget.category != null) ('Danh mục', widget.category!.name),
      if (tx.fee > 0) ('Phí', formatVnd(tx.fee)),
      (
        'Thời gian',
        '${dateLabel(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}',
      ),
      if ((tx.merchant ?? '').isNotEmpty) ('Nơi chi/thu', tx.merchant!),
      if ((tx.note ?? '').isNotEmpty) ('Ghi chú', tx.note!),
      if (tx.isVoid) ('Trạng thái', 'Đã hủy (còn lưu lịch sử)'),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatVnd(tx.amount),
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800, color: MomaColors.forest),
        ),
        const SizedBox(height: 8),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(r.$1, style: TextStyle(color: context.pal.muted)),
                ),
                Expanded(child: Text(r.$2)),
              ],
            ),
          ),
        if (tx.debtLinked)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Giao dịch này thuộc một khoản công nợ nên chỉ sửa được ghi chú. '
              'Muốn sửa số tiền, hãy thao tác trong mục Công nợ.',
              style: TextStyle(color: context.pal.muted),
            ),
          ),
        if (_cancelling) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.edit_note_rounded),
              labelText: 'Lý do hủy',
            ),
          ),
        ],
        FormError(_run.error),
        const SizedBox(height: 16),
        if (!tx.isVoid && tx.kind != 'OPENING')
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _run.busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          showFormSheet<void>(
                            context,
                            (_) => TxEditSheet(tx: tx),
                          );
                        },
                  child: const Text('Sửa'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: MomaColors.expense,
                  ),
                  onPressed: _run.busy || tx.debtLinked
                      ? null
                      : (_cancelling
                            ? _reverse
                            : () => setState(() => _cancelling = true)),
                  child: Text(_cancelling ? 'Xác nhận hủy' : 'Hủy giao dịch'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class TxEditSheet extends ConsumerStatefulWidget {
  const TxEditSheet({super.key, required this.tx});
  final MomaTx tx;
  @override
  ConsumerState<TxEditSheet> createState() => _TxEditSheetState();
}

class _TxEditSheetState extends ConsumerState<TxEditSheet> {
  late final FormRunner _run = FormRunner(setState);
  late final TextEditingController _amount = TextEditingController(
    text: formatVnd(widget.tx.amount).replaceAll(' ₫', ''),
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.tx.note ?? '',
  );
  late final TextEditingController _merchant = TextEditingController(
    text: widget.tx.merchant ?? '',
  );
  final _reason = TextEditingController();
  late String? _accountId = widget.tx.accountId;
  late String? _categoryId = widget.tx.categoryId;
  late DateTime _when = widget.tx.effectiveAt;
  final String _id = ApiClient.newId();

  /// Only plain income/expense can change money fields; the rest edit text only.
  bool get _moneyEditable =>
      !widget.tx.debtLinked &&
      (widget.tx.kind == 'INCOME' || widget.tx.kind == 'EXPENSE');

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _merchant.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool _moneyChanged(int amount) =>
      _moneyEditable &&
      (amount != widget.tx.amount ||
          _accountId != widget.tx.accountId ||
          _when.toUtc().toIso8601String() !=
              widget.tx.effectiveAt.toUtc().toIso8601String());

  Future<void> _save() async {
    final tx = widget.tx;
    final amount = _moneyEditable
        ? (parseVndInput(_amount.text) ?? 0)
        : tx.amount;
    if (amount <= 0) {
      setState(() => _run.error = 'Nhập số tiền hợp lệ.');
      return;
    }
    final corrected = _moneyChanged(amount);
    if (corrected && _reason.text.trim().isEmpty) {
      setState(() => _run.error = 'Đổi số tiền/tài khoản/ngày cần nhập lý do.');
      return;
    }
    final ok = await _run.run(() async {
      final api = ref.read(apiProvider);
      if (corrected) {
        await api.command('TX_CORRECT', {
          'tx_id': tx.id,
          'reason': _reason.text.trim(),
          'expected_version': tx.version,
          'replacement': {
            'kind': tx.kind,
            'account_id': _accountId,
            'amount': amount.toString(),
            'effective_at': _when.toUtc().toIso8601String(),
            'category_id': ?_categoryId,
            if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
            if (_merchant.text.trim().isNotEmpty)
              'merchant': _merchant.text.trim(),
          },
        }, commandId: _id);
      } else {
        await api.command('TX_ANNOTATE', {
          'tx_id': tx.id,
          'expected_version': tx.version,
          'note': _note.text.trim(),
          if (_merchant.text.trim().isNotEmpty)
            'merchant': _merchant.text.trim(),
          if (_moneyEditable &&
              _categoryId != null &&
              _categoryId != tx.categoryId)
            'category_id': _categoryId,
        }, commandId: _id);
      }
    });
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tx = widget.tx;
    final accounts = ref.watch(accountsProvider).value ?? <Account>[];
    final cats = (ref.watch(categoriesProvider).value ?? <Category>[])
        .where((c) => c.type == tx.kind)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sửa giao dịch',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          _moneyEditable
              ? 'Đổi số tiền, tài khoản hoặc ngày sẽ hủy giao dịch cũ (còn lưu lịch sử) và tạo giao dịch mới.'
              : 'Loại giao dịch này chỉ sửa được ghi chú.',
          style: TextStyle(color: context.pal.muted),
        ),
        const SizedBox(height: 12),
        if (_moneyEditable) ...[
          MoneyField(controller: _amount),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: 'Tài khoản'),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in cats)
                ChoiceChip(
                  avatar: Icon(categoryIcon(c.icon), size: 18),
                  label: Text(c.name),
                  selected: _categoryId == c.id,
                  onSelected: (_) => setState(() => _categoryId = c.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            tileColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: const Icon(Icons.event_rounded),
            title: Text(dateLabel(_when)),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _when,
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 1)),
              );
              if (d != null) {
                setState(
                  () => _when = DateTime(
                    d.year,
                    d.month,
                    d.day,
                    _when.hour,
                    _when.minute,
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _merchant,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.storefront_outlined),
            hintText: 'Nơi chi/thu (tùy chọn)',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.edit_note_rounded),
            hintText: 'Ghi chú',
          ),
        ),
        if (_moneyEditable) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.help_outline_rounded),
              hintText: 'Lý do sửa (bắt buộc nếu đổi tiền/tài khoản/ngày)',
            ),
          ),
        ],
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _save,
          child: const Text('Lưu thay đổi'),
        ),
      ],
    );
  }
}
