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
import '../../app/theme/palette.dart';

class RecurringView extends ConsumerWidget {
  const RecurringView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recurringProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(recurringProvider);
        await ref.read(recurringProvider.future);
      },
      child: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(recurringProvider),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            const Card(
              color: Color(0xFFE9F6EE),
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'MoMa không tự ghi giao dịch định kỳ. Đến hạn, bạn xác nhận từng khoản.',
                ),
              ),
            ),
            if (list.isEmpty)
              const SizedBox(
                height: 220,
                child: EmptyState(
                  icon: Icons.event_repeat_rounded,
                  title: 'Chưa có khoản định kỳ',
                  hint:
                      'Thêm tiền nhà, hóa đơn, lương... để được nhắc đúng hạn.',
                ),
              ),
            for (final r in list) _RecurringCard(item: r),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  showFormSheet<void>(context, (_) => const _RecurringSheet()),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Thêm khoản định kỳ'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecurringCard extends ConsumerWidget {
  const _RecurringCard({required this.item});
  final RecurringItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isIncome = item.kind == 'INCOME';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  '${isIncome ? '+' : (item.kind == 'EXPENSE' ? '-' : '')}${formatVnd(item.amount)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: isIncome ? MomaColors.income : MomaColors.expense,
                  ),
                ),
              ],
            ),
            Text(
              item.intervalLabel,
              style: TextStyle(color: context.pal.muted),
            ),
            for (final o in item.expected)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.schedule_rounded),
                title: Text('Đến hạn ${o.dueDate}'),
                trailing: TextButton(
                  onPressed: () => showFormSheet<void>(
                    context,
                    (_) => _ConfirmOccurrenceSheet(item: item, occurrence: o),
                  ),
                  child: const Text('Xác nhận'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Posts the real transaction, then matches the occurrence. Both ids are fixed per sheet so a retry replays safely.
class _ConfirmOccurrenceSheet extends ConsumerStatefulWidget {
  const _ConfirmOccurrenceSheet({required this.item, required this.occurrence});
  final RecurringItem item;
  final Occurrence occurrence;
  @override
  ConsumerState<_ConfirmOccurrenceSheet> createState() =>
      _ConfirmOccurrenceSheetState();
}

class _ConfirmOccurrenceSheetState
    extends ConsumerState<_ConfirmOccurrenceSheet> {
  late final FormRunner _run = FormRunner(setState);
  final String _txCmd = ApiClient.newId();
  final String _matchCmd = ApiClient.newId();

  Future<void> _confirm() async {
    final it = widget.item;
    final ok = await _run.run(() async {
      final api = ref.read(apiProvider);
      final tx = await api.command('TX_CREATE', {
        'kind': it.kind,
        'account_id': it.accountId,
        'amount': it.amount.toString(),
        'effective_at': DateTime.now().toUtc().toIso8601String(),
        'category_id': ?(it.template['category_id'] as String?),
        'to_account_id': ?(it.template['to_account_id'] as String?),
        'merchant': it.name,
      }, commandId: _txCmd);
      await api.command('OCCURRENCE_MATCH', {
        'occurrence_id': widget.occurrence.id,
        'tx_id': tx['tx_id'],
        'expected_version': widget.occurrence.version,
      }, commandId: _matchCmd);
    });
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Xác nhận ${it.name}',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'Ghi giao dịch ${formatVnd(it.amount)} cho kỳ ${widget.occurrence.dueDate}?',
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _confirm,
          child: const Text('Ghi giao dịch'),
        ),
      ],
    );
  }
}

class _RecurringSheet extends ConsumerStatefulWidget {
  const _RecurringSheet();
  @override
  ConsumerState<_RecurringSheet> createState() => _RecurringSheetState();
}

class _RecurringSheetState extends ConsumerState<_RecurringSheet> {
  late final FormRunner _run = FormRunner(setState);
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _kind = 'EXPENSE';
  String _interval = 'MONTHLY';
  String? _accountId;
  String? _toAccountId;
  String? _categoryId;
  DateTime _next = DateTime.now().add(const Duration(days: 1));
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = parseVndInput(_amount.text);
    final needsCategory = _kind != 'TRANSFER';
    if (_name.text.trim().isEmpty ||
        amount == null ||
        amount <= 0 ||
        _accountId == null ||
        (needsCategory && _categoryId == null) ||
        (!needsCategory && _toAccountId == null)) {
      setState(
        () => _run.error = 'Điền đủ tên, số tiền, tài khoản và danh mục.',
      );
      return;
    }
    final ok = await _run.run(
      () => ref.read(apiProvider).command('RECURRING_UPSERT', {
        'name': _name.text.trim(),
        'kind': _kind,
        'account_id': _accountId,
        'amount': amount.toString(),
        'interval': _interval,
        'next_date': isoDate(_next),
        'enabled': true,
        'category_id': ?(needsCategory ? _categoryId : null),
        'to_account_id': ?(needsCategory ? null : _toAccountId),
      }, commandId: _id),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).value ?? <Account>[];
    final cats = (ref.watch(categoriesProvider).value ?? <Category>[])
        .where((c) => c.type == _kind)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Khoản định kỳ',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'EXPENSE', label: Text('Chi')),
            ButtonSegment(value: 'INCOME', label: Text('Thu')),
            ButtonSegment(value: 'TRANSFER', label: Text('Chuyển')),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() {
            _kind = s.first;
            _categoryId = null;
          }),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.label_outline_rounded),
            hintText: 'Tên (vd: Tiền nhà)',
          ),
        ),
        const SizedBox(height: 12),
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
        if (_kind == 'TRANSFER')
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _toAccountId,
            decoration: const InputDecoration(labelText: 'Đến tài khoản'),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() => _toAccountId = v),
          )
        else
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _categoryId,
            decoration: const InputDecoration(labelText: 'Danh mục'),
            items: [
              for (final c in cats)
                DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'WEEKLY', label: Text('Tuần')),
            ButtonSegment(value: 'MONTHLY', label: Text('Tháng')),
            ButtonSegment(value: 'YEARLY', label: Text('Năm')),
          ],
          selected: {_interval},
          onSelectionChanged: (s) => setState(() => _interval = s.first),
        ),
        const SizedBox(height: 12),
        ListTile(
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: const Icon(Icons.event_rounded),
          title: Text('Kỳ đầu tiên: ${dateLabel(_next)}'),
          onTap: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _next,
              firstDate: DateTime.now().subtract(const Duration(days: 31)),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (d != null) setState(() => _next = d);
          },
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}
