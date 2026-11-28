import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../../core/brands/person_avatar.dart';

class DebtsView extends ConsumerStatefulWidget {
  const DebtsView({super.key});
  @override
  ConsumerState<DebtsView> createState() => _DebtsViewState();
}

class _DebtsViewState extends ConsumerState<DebtsView> {
  String _direction = 'RECEIVABLE';

  @override
  Widget build(BuildContext context) {
    final debts = ref.watch(debtsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(debtsProvider);
        await ref.read(debtsProvider.future);
      },
      child: debts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(debtsProvider)),
        data: (all) {
          final list = all.where((d) => d.direction == _direction).toList()
            ..sort((a, b) => (b.isOpen ? 1 : 0).compareTo(a.isOpen ? 1 : 0));
          final total = list
              .where((d) => d.isOpen)
              .fold<int>(0, (s, d) => s + d.remaining);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              PillTabs<String>(
                segments: const [
                  ButtonSegment(value: 'RECEIVABLE', label: Text('Phải thu')),
                  ButtonSegment(value: 'PAYABLE', label: Text('Phải trả')),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() => _direction = s.first),
              ),
              const SizedBox(height: 16),
              Card(
                margin: const EdgeInsets.only(bottom: 16),
                color: context.pal.tint,
                child: ListTile(
                  title: Text(
                    _direction == 'RECEIVABLE'
                        ? 'Tổng phải thu'
                        : 'Tổng phải trả',
                  ),
                  trailing: Text(
                    formatVnd(total),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              if (list.isEmpty)
                const EmptyState(
                  embedded: true,
                  icon: Symbols.handshake_rounded,
                  title: 'Chưa có công nợ',
                  hint: 'Bấm "Thêm công nợ" để ghi một khoản cho vay hoặc đi vay.',
                ),
              for (final d in list) _DebtCard(debt: d),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showFormSheet<void>(
                  context,
                  (_) => _AddDebtSheet(initialDirection: _direction),
                ),
                icon: const Icon(Symbols.add_rounded),
                label: const Text('Thêm công nợ'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DebtCard extends StatelessWidget {
  const _DebtCard({required this.debt});
  final Debt debt;

  @override
  Widget build(BuildContext context) {
    final settled = !debt.isOpen;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        // Every debt opens its detail: repay, edit, undo a payment or delete (also settled ones).
        onTap: () => openDebt(context, debt.id),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            PersonAvatar(name: debt.contactAlias, size: 42),
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: debt.isReceivable
                      ? MomaColors.income
                      : MomaColors.expense,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.pal.surface, width: 1.5),
                ),
                child: Icon(
                  debt.isReceivable
                      ? Symbols.south_west_rounded
                      : Symbols.north_east_rounded,
                  size: 11,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        title: Text(
          debt.contactAlias,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          settled
              ? (debt.state == 'SETTLED' ? 'Đã tất toán' : 'Đã xóa nợ')
              : [
                  'Gốc ${formatVnd(debt.principal)}',
                  if (debt.dueDate != null) 'Hạn ${debt.dueDate}',
                  if (debt.overdue) 'QUÁ HẠN',
                ].join(' · '),
          style: TextStyle(color: debt.overdue ? MomaColors.expense : null),
        ),
        trailing: Text(
          formatVnd(debt.remaining),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// Opens one debt (from the debts list, or from a debt-linked transaction: "Mở khoản nợ").
Future<void> openDebt(BuildContext context, String debtId) =>
    showFormSheet<void>(context, (_) => DebtDetailSheet(debtId: debtId));

String _stateLabel(Debt d) => switch (d.state) {
  'SETTLED' => d.isReceivable ? 'Đã thu đủ' : 'Đã trả đủ',
  'WRITTEN_OFF' => 'Đã xóa nợ',
  'PARTIAL' => d.isReceivable ? 'Đã thu một phần' : 'Đã trả một phần',
  _ => 'Chưa thu/trả',
};

String _paymentTitle(Debt d, DebtPayment p) {
  if (p.isWriteOff) return 'Xóa nợ ${formatVnd(p.principal)}';
  final verb = d.isReceivable ? 'Thu' : 'Trả';
  final interest = p.interest > 0 ? ' + lãi ${formatVnd(p.interest)}' : '';
  return '$verb ${formatVnd(p.principal)}$interest';
}

/// Debt detail: amounts, history of repayments, and the fixes the owner asked for (sửa, hoàn tác, xóa).
class DebtDetailSheet extends ConsumerStatefulWidget {
  const DebtDetailSheet({super.key, required this.debtId});
  final String debtId;
  @override
  ConsumerState<DebtDetailSheet> createState() => _DebtDetailSheetState();
}

class _DebtDetailSheetState extends ConsumerState<DebtDetailSheet> {
  late final FormRunner _run = FormRunner(setState);

  Future<void> _undo(Debt d, DebtPayment p) async {
    final yes = await showConfirmDialog(
      context,
      title:
          'Hoàn tác lần ${p.isWriteOff ? 'xóa nợ' : (d.isReceivable ? 'thu' : 'trả')}?',
      message:
          '${_paymentTitle(d, p)} sẽ bị hủy, số tiền ${p.isWriteOff ? 'được tính lại vào khoản nợ' : 'trả về tài khoản như trước'}. '
          'Lịch sử vẫn được giữ.',
      confirmLabel: 'Hoàn tác',
      destructive: true,
    );
    if (!yes || !mounted) return;
    final ok = await _run.run(
      () => ref.read(apiProvider).command('DEBT_PAYMENT_REVERSE', {
        'debt_id': d.id,
        'payment_id': p.id,
        'expected_version': d.version,
      }, commandId: ApiClient.newId()),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      showSnack(context, 'Đã hoàn tác.');
    }
  }

  Future<void> _delete(Debt d) async {
    final n = d.activePayments.length;
    final yes = await showConfirmDialog(
      context,
      title: 'Xóa khoản nợ này?',
      message: [
        'Khoản ${d.isReceivable ? 'cho' : 'vay'} ${d.contactAlias} ${formatVnd(d.principal)} sẽ biến mất khỏi danh sách và số dư.',
        if (n > 0) '$n lần thu/trả của khoản này cũng được hoàn tác.',
        'Tài khoản tiền trở lại như chưa từng ghi khoản này.',
      ].join(' '),
      confirmLabel: 'Xóa',
      destructive: true,
    );
    if (!yes || !mounted) return;
    final ok = await _run.run(
      () => ref.read(apiProvider).command('DEBT_CANCEL', {
        'debt_id': d.id,
        'expected_version': d.version,
        'reason': 'Xóa trong app',
      }, commandId: ApiClient.newId()),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
      showSnack(context, 'Đã xóa khoản nợ.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final all = ref.watch(debtsProvider).value;
    final d = all?.where((x) => x.id == widget.debtId).firstOrNull;
    if (all == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (d == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'Khoản nợ này đã được xóa.',
          style: TextStyle(color: pal.muted),
        ),
      );
    }
    final accounts = ref.watch(accountsProvider).value ?? <Account>[];
    String? accountName(String? id) =>
        accounts.where((a) => a.id == id).firstOrNull?.name;
    final color = d.isReceivable ? MomaColors.income : MomaColors.expense;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PersonAvatar(name: d.contactAlias, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.contactAlias,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800, color: pal.ink),
                  ),
                  Text(
                    '${d.isReceivable ? 'Cho vay' : 'Đi vay'} · ${_stateLabel(d)}',
                    style: TextStyle(color: pal.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: pal.tint,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Còn lại', style: TextStyle(color: pal.muted)),
              Text(
                formatVnd(d.remaining),
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: d.isOpen ? color : pal.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  'Gốc ${formatVnd(d.principal)}',
                  if (d.dueDate != null) 'Hạn ${d.dueDate}',
                  if (d.overdue) 'QUÁ HẠN',
                ].join(' · '),
                style: TextStyle(
                  color: d.overdue ? MomaColors.expense : pal.muted,
                ),
              ),
              if ((d.note ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(d.note!, style: TextStyle(color: pal.ink)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (d.isOpen) ...[
          FilledButton.icon(
            onPressed: _run.busy
                ? null
                : () => showFormSheet<void>(
                    context,
                    (_) => _DebtActionSheet(debt: d),
                  ),
            icon: Icon(
              d.isReceivable
                  ? Symbols.south_west_rounded
                  : Symbols.north_east_rounded,
            ),
            label: Text(d.isReceivable ? 'Thu nợ' : 'Trả nợ'),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _run.busy
                    ? null
                    : () => showFormSheet<void>(
                        context,
                        (_) => _EditDebtSheet(debt: d),
                      ),
                icon: const Icon(Symbols.edit_rounded),
                label: const Text('Sửa'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('debt-delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MomaColors.expense,
                ),
                onPressed: _run.busy ? null : () => _delete(d),
                icon: const Icon(Symbols.delete_rounded),
                label: const Text('Xóa'),
              ),
            ),
          ],
        ),
        FormError(_run.error),
        if (d.payments.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            d.isReceivable ? 'Lịch sử thu nợ' : 'Lịch sử trả nợ',
            style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
          ),
          const SizedBox(height: 6),
          for (final p in d.payments)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                p.isWriteOff
                    ? Symbols.money_off_rounded
                    : Symbols.payments_rounded,
                color: p.reversed ? pal.hint : color,
              ),
              title: Text(
                _paymentTitle(d, p),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: p.reversed ? pal.hint : pal.ink,
                  decoration: p.reversed ? TextDecoration.lineThrough : null,
                ),
              ),
              subtitle: Text(
                [
                  if (p.effectiveAt != null) dateLabel(p.effectiveAt!),
                  ?accountName(p.accountId),
                  if (p.reversed) 'Đã hoàn tác',
                ].join(' · '),
                style: TextStyle(color: pal.muted),
              ),
              trailing: p.reversed
                  ? null
                  : TextButton.icon(
                      onPressed: _run.busy ? null : () => _undo(d, p),
                      icon: const Icon(Symbols.undo_rounded, size: 18),
                      label: const Text('Hoàn tác'),
                    ),
            ),
        ],
      ],
    );
  }
}

/// Sửa khoản nợ: person, due date, note; the amount only while nothing was repaid / written off.
class _EditDebtSheet extends ConsumerStatefulWidget {
  const _EditDebtSheet({required this.debt});
  final Debt debt;
  @override
  ConsumerState<_EditDebtSheet> createState() => _EditDebtSheetState();
}

class _EditDebtSheetState extends ConsumerState<_EditDebtSheet> {
  late final FormRunner _run = FormRunner(setState);
  late String? _contactId = widget.debt.contactId;
  late DateTime? _due = widget.debt.dueDate == null
      ? null
      : DateTime.tryParse(widget.debt.dueDate!);
  late final _note = TextEditingController(text: widget.debt.note ?? '');
  late final _principal = TextEditingController(
    text: formatVnd(widget.debt.principal).replaceAll(' ₫', ''),
  );
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _note.dispose();
    _principal.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final d = widget.debt;
    final payload = <String, dynamic>{
      'debt_id': d.id,
      'expected_version': d.version,
    };
    if (_contactId != null && _contactId != d.contactId) {
      payload['contact_id'] = _contactId;
    }
    final dueIso = _due == null ? null : isoDate(_due!);
    if (dueIso != d.dueDate) payload['due_date'] = dueIso;
    if (_note.text.trim() != (d.note ?? '')) {
      payload['note'] = _note.text.trim();
    }
    if (d.amountEditable) {
      final p = parseVndInput(_principal.text);
      if (p == null || p <= 0) {
        setState(() => _run.error = 'Nhập số tiền hợp lệ.');
        return;
      }
      if (p != d.principal) payload['principal'] = p.toString();
    }
    if (payload.length == 2) {
      Navigator.pop(context);
      return;
    }
    final ok = await _run.run(
      () =>
          ref.read(apiProvider).command('DEBT_UPDATE', payload, commandId: _id),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
      showSnack(context, 'Đã lưu khoản nợ.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.debt;
    final pal = context.pal;
    final contacts = ref.watch(contactsProvider).value ?? <Contact>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sửa khoản nợ',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        if (contacts.isNotEmpty)
          PickField<String>(
            isExpanded: true,
            initialValue: contacts.any((c) => c.id == _contactId)
                ? _contactId
                : null,
            decoration: const InputDecoration(labelText: 'Người'),
            icon: Symbols.person_rounded,
            items: [
              for (final c in contacts)
                DropdownMenuItem(value: c.id, child: Text(c.alias)),
            ],
            onChanged: (v) => setState(() => _contactId = v),
          ),
        const SizedBox(height: 12),
        if (d.amountEditable)
          MoneyField(controller: _principal, hint: 'Số tiền gốc')
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: pal.warnBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              'Số tiền gốc ${formatVnd(d.principal)}. Khoản này đã có lần thu/trả: '
              'hoàn tác các lần đó trong lịch sử nếu muốn đổi số tiền.',
              style: TextStyle(color: pal.warnInk),
            ),
          ),
        const SizedBox(height: 12),
        DateField(
          label: 'Hạn trả',
          value: _due,
          initialDate: DateTime.now().add(const Duration(days: 30)),
          firstDate: DateTime.now().subtract(const Duration(days: 3650)),
          lastDate: DateTime.now().add(const Duration(days: 3650)),
          onChanged: (v) => setState(() => _due = v),
        ),
        const SizedBox(height: 12),
        LabeledField(label: 'Ghi chú', hint: 'Nhập ghi chú', controller: _note),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu thay đổi'),
        ),
      ],
    );
  }
}

class _DebtActionSheet extends ConsumerStatefulWidget {
  const _DebtActionSheet({required this.debt});
  final Debt debt;
  @override
  ConsumerState<_DebtActionSheet> createState() => _DebtActionSheetState();
}

class _DebtActionSheetState extends ConsumerState<_DebtActionSheet> {
  late final FormRunner _run = FormRunner(setState);
  bool _writeOff = false;
  final _amount = TextEditingController();
  final _interest = TextEditingController();
  final _reason = TextEditingController();
  String? _accountId;
  final String _id = ApiClient.newId();

  @override
  void initState() {
    super.initState();
    _amount.text = formatVnd(widget.debt.remaining).replaceAll(' ₫', '');
  }

  @override
  void dispose() {
    _amount.dispose();
    _interest.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = parseVndInput(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _run.error = 'Nhập số tiền hợp lệ.');
      return;
    }
    final d = widget.debt;
    final ok = await _run.run(() async {
      final now = DateTime.now().toUtc().toIso8601String();
      if (_writeOff) {
        if (_reason.text.trim().isEmpty) {
          throw ApiException('REASON_REQUIRED', 'Cần nhập lý do.');
        }
        await ref.read(apiProvider).command('DEBT_WRITE_OFF', {
          'debt_id': d.id,
          'amount': amount.toString(),
          'reason': _reason.text.trim(),
          'effective_at': now,
          'expected_version': d.version,
        }, commandId: _id);
      } else {
        if (_accountId == null) {
          throw ApiException('VALIDATION_FAILED', 'Chọn tài khoản.');
        }
        final interest = parseVndInput(_interest.text);
        await ref.read(apiProvider).command('DEBT_REPAY', {
          'debt_id': d.id,
          'account_id': _accountId,
          'principal': amount.toString(),
          'effective_at': now,
          'expected_version': d.version,
          if (interest != null && interest > 0) 'interest': interest.toString(),
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
    final d = widget.debt;
    final accounts = (ref.watch(accountsProvider).value ?? <Account>[])
        .where((a) => !a.isCard)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${d.contactAlias} · còn ${formatVnd(d.remaining)}',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        PillTabs<bool>(
          segments: [
            ButtonSegment(
              value: false,
              label: Text(d.isReceivable ? 'Thu nợ' : 'Trả nợ'),
            ),
            const ButtonSegment(value: true, label: Text('Xóa nợ')),
          ],
          selected: {_writeOff},
          onSelectionChanged: (s) => setState(() => _writeOff = s.first),
        ),
        const SizedBox(height: 12),
        MoneyField(
          controller: _amount,
          hint: _writeOff ? 'Số tiền xóa' : 'Số tiền gốc',
        ),
        const SizedBox(height: 12),
        if (_writeOff)
          LabeledField(
            label: 'Lý do',
            hint: 'Nhập lý do',
            controller: _reason,
            required: true,
          )
        else ...[
          PickField<String>(
            isExpanded: true,
            initialValue: _accountId,
            decoration: InputDecoration(
              labelText: d.isReceivable
                  ? 'Nhận vào tài khoản'
                  : 'Trả từ tài khoản',
            ),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
          const SizedBox(height: 12),
          MoneyField(controller: _interest, hint: 'Lãi', optional: true),
        ],
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: Text(_writeOff ? 'Xác nhận xóa nợ' : 'Ghi nhận'),
        ),
      ],
    );
  }
}

class _AddDebtSheet extends ConsumerStatefulWidget {
  const _AddDebtSheet({required this.initialDirection});
  final String initialDirection;
  @override
  ConsumerState<_AddDebtSheet> createState() => _AddDebtSheetState();
}

class _AddDebtSheetState extends ConsumerState<_AddDebtSheet> {
  late final FormRunner _run = FormRunner(setState);
  late String _direction = widget.initialDirection;
  final _alias = TextEditingController();
  final _principal = TextEditingController();
  final _note = TextEditingController();
  String? _contactId;
  bool _existing = true;
  String? _accountId;
  bool _historical = false;
  DateTime? _due;
  final String _contactCmd = ApiClient.newId();
  final String _debtCmd = ApiClient.newId();

  @override
  void dispose() {
    _alias.dispose();
    _principal.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final principal = parseVndInput(_principal.text);
    if (principal == null || principal <= 0) {
      setState(() => _run.error = 'Nhập số tiền hợp lệ.');
      return;
    }
    final hasContacts =
        (ref.read(contactsProvider).value ?? const []).isNotEmpty;
    final pickExisting = hasContacts && _existing;
    if (pickExisting ? _contactId == null : _alias.text.trim().isEmpty) {
      setState(
        () => _run.error = pickExisting ? 'Chọn người.' : 'Nhập tên người.',
      );
      return;
    }
    if (!_historical && _accountId == null) {
      setState(() => _run.error = 'Chọn tài khoản hoặc đánh dấu khoản cũ.');
      return;
    }
    final ok = await _run.run(() async {
      final api = ref.read(apiProvider);
      var contact = pickExisting ? _contactId : null;
      if (contact == null || !pickExisting) {
        // Same command id on retry replays instead of creating a second contact.
        final r = await api.command('CONTACT_CREATE', {
          'alias': _alias.text.trim(),
        }, commandId: _contactCmd);
        contact = r['contact_id'] as String;
      }
      await api.command('DEBT_CREATE', {
        'direction': _direction,
        'contact_id': contact,
        'principal': principal.toString(),
        'originated_at': DateTime.now().toUtc().toIso8601String(),
        if (!_historical) 'account_id': _accountId,
        if (_historical) 'historical': true,
        if (_due != null) 'due_date': isoDate(_due!),
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      }, commandId: _debtCmd);
    });
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider).value ?? <Contact>[];
    final accounts = (ref.watch(accountsProvider).value ?? <Account>[])
        .where((a) => !a.isCard)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Thêm công nợ',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        PillTabs<String>(
          segments: const [
            ButtonSegment(value: 'RECEIVABLE', label: Text('Cho vay')),
            ButtonSegment(value: 'PAYABLE', label: Text('Đi vay')),
          ],
          selected: {_direction},
          onSelectionChanged: (s) => setState(() => _direction = s.first),
        ),
        const SizedBox(height: 12),
        if (contacts.isNotEmpty) ...[
          PillTabs<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Người đã có')),
              ButtonSegment(value: false, label: Text('Người mới')),
            ],
            selected: {_existing},
            onSelectionChanged: (s) => setState(() {
              _existing = s.first;
              if (!_existing) _contactId = null;
            }),
          ),
          const SizedBox(height: 12),
        ],
        if (contacts.isNotEmpty && _existing)
          PickField<String>(
            key: const ValueKey('contact-existing'),
            isExpanded: true,
            initialValue: _contactId,
            decoration: const InputDecoration(labelText: 'Chọn người'),
            icon: Symbols.person_rounded,
            items: [
              for (final c in contacts)
                DropdownMenuItem(value: c.id, child: Text(c.alias)),
            ],
            onChanged: (v) => setState(() => _contactId = v),
          )
        else
          LabeledField(
            label: 'Tên người mới',
            hint: 'Nhập tên người',
            controller: _alias,
            icon: Symbols.person_add_rounded,
            required: true,
          ),
        const SizedBox(height: 12),
        MoneyField(controller: _principal, hint: 'Số tiền gốc'),
        LabeledSwitch(
          label: 'Khoản cũ',
          help: 'Bật nếu đây là khoản đã có từ trước và bạn chỉ muốn ghi nhớ. MoMa sẽ không cộng hay trừ tiền ở tài khoản nào.',
          value: _historical,
          onChanged: (v) => setState(() => _historical = v),
        ),
        if (!_historical)
          PickField<String>(
            isExpanded: true,
            initialValue: _accountId,
            decoration: InputDecoration(
              labelText: _direction == 'RECEIVABLE'
                  ? 'Tiền đi từ tài khoản'
                  : 'Tiền về tài khoản',
            ),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
        const SizedBox(height: 12),
        DateField(
          label: 'Hạn trả',
          value: _due,
          initialDate: DateTime.now().add(const Duration(days: 30)),
          firstDate: DateTime.now().subtract(const Duration(days: 365)),
          lastDate: DateTime.now().add(const Duration(days: 3650)),
          onChanged: (d) => setState(() => _due = d),
        ),
        const SizedBox(height: 12),
        LabeledField(label: 'Ghi chú', hint: 'Nhập ghi chú', controller: _note),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu công nợ'),
        ),
      ],
    );
  }
}
