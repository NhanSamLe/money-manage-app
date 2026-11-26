import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';

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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'RECEIVABLE', label: Text('Phải thu')),
                  ButtonSegment(value: 'PAYABLE', label: Text('Phải trả')),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() => _direction = s.first),
              ),
              const SizedBox(height: 12),
              Card(
                color: const Color(0xFFE9F6EE),
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
                const SizedBox(
                  height: 220,
                  child: EmptyState(
                    icon: Icons.handshake_outlined,
                    title: 'Chưa có công nợ',
                    hint: 'Bấm "Thêm công nợ" để ghi một khoản cho vay hoặc đi vay.',
                  ),
                ),
              for (final d in list) _DebtCard(debt: d),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showFormSheet<void>(
                  context,
                  (_) => _AddDebtSheet(initialDirection: _direction),
                ),
                icon: const Icon(Icons.add_rounded),
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
      child: ListTile(
        onTap: settled
            ? null
            : () => showFormSheet<void>(
                context,
                (_) => _DebtActionSheet(debt: debt),
              ),
        leading: CircleAvatar(
          backgroundColor: MomaColors.mint.withValues(alpha: 0.4),
          child: Icon(
            debt.isReceivable
                ? Icons.south_west_rounded
                : Icons.north_east_rounded,
            color: MomaColors.forest,
          ),
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
        SegmentedButton<bool>(
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
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.edit_note_rounded),
              hintText: 'Lý do (bắt buộc)',
            ),
          )
        else ...[
          DropdownButtonFormField<String>(
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
          MoneyField(controller: _interest, hint: 'Lãi (nếu có)'),
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
    if (_contactId == null && _alias.text.trim().isEmpty) {
      setState(() => _run.error = 'Chọn hoặc nhập tên người.');
      return;
    }
    if (!_historical && _accountId == null) {
      setState(() => _run.error = 'Chọn tài khoản hoặc đánh dấu khoản cũ.');
      return;
    }
    final ok = await _run.run(() async {
      final api = ref.read(apiProvider);
      var contact = _contactId;
      if (contact == null) {
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
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'RECEIVABLE', label: Text('Cho vay')),
            ButtonSegment(value: 'PAYABLE', label: Text('Đi vay')),
          ],
          selected: {_direction},
          onSelectionChanged: (s) => setState(() => _direction = s.first),
        ),
        const SizedBox(height: 12),
        if (contacts.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _contactId,
            decoration: const InputDecoration(labelText: 'Người có sẵn'),
            items: [
              for (final c in contacts)
                DropdownMenuItem(value: c.id, child: Text(c.alias)),
            ],
            onChanged: (v) => setState(() => _contactId = v),
          ),
        if (_contactId == null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _alias,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_add_alt_rounded),
              hintText: 'Hoặc nhập tên người mới',
            ),
          ),
        ],
        const SizedBox(height: 12),
        MoneyField(controller: _principal, hint: 'Số tiền gốc'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Khoản cũ (không phát sinh tiền mặt)'),
          value: _historical,
          onChanged: (v) => setState(() => _historical = v),
        ),
        if (!_historical)
          DropdownButtonFormField<String>(
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
        ListTile(
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: const Icon(Icons.event_rounded),
          title: Text(_due == null ? 'Hạn trả (tùy chọn)' : dateLabel(_due!)),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: DateTime.now().add(const Duration(days: 30)),
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (d != null) setState(() => _due = d);
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.edit_note_rounded),
            hintText: 'Ghi chú (tùy chọn)',
          ),
        ),
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
