import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import '../../app/theme/palette.dart';
import '../splits/recurring_split_sheet.dart';
import '../splits/split_api.dart';
import '../splits/split_models.dart';

import 'package:material_symbols_icons/symbols.dart';

class RecurringView extends ConsumerWidget {
  const RecurringView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recurringProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(recurringRulesProvider);
        ref.invalidate(ruleSuggestionsProvider);
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
            Card(
              color: context.pal.tint,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'Với quy tắc tự động, MoMa tự nhận khoản tiền ra khớp số tiền và khoảng ngày, ghi đúng danh mục '
                  'và tự ghi nợ cho người cùng trả. Chưa chắc thì hỏi bạn một chạm; khoản thường thì bạn xác nhận khi đến hạn.',
                  style: TextStyle(color: context.pal.ink),
                ),
              ),
            ),
            for (final s
                in ref.watch(ruleSuggestionsProvider).value ??
                    const <RuleSuggestion>[])
              Card(
                child: ListTile(
                  leading: const Icon(Symbols.auto_awesome_rounded),
                  title: Text(s.text),
                  subtitle: (s.label ?? '').isEmpty ? null : Text(s.label!),
                  trailing: TextButton(
                    onPressed: () => showFormSheet<void>(
                      context,
                      (_) => RecurringSplitSheet(suggestion: s),
                    ),
                    child: const Text('Tạo'),
                  ),
                ),
              ),
            if (list.isEmpty)
              const EmptyState(
                embedded: true,
                icon: Symbols.event_repeat_rounded,
                title: 'Chưa có khoản định kỳ',
                hint: 'Thêm tiền nhà, hóa đơn, lương... để được nhắc đúng hạn.',
              ),
            for (final r in list) _RecurringCard(item: r),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => showFormSheet<void>(
                context,
                (_) => const RecurringSplitSheet(),
              ),
              icon: const Icon(Symbols.auto_mode_rounded),
              label: const Text('Thêm quy tắc tự động (tiền nhà, điện…)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  showFormSheet<void>(context, (_) => const _RecurringSheet()),
              icon: const Icon(Symbols.add_rounded),
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
    final rule =
        (ref.watch(recurringRulesProvider).value ?? const <RecurringRule>[])
            .where((r) => r.item.id == item.id)
            .firstOrNull;
    final split = rule?.split;
    final last = rule?.last;
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
              rule?.windowLabel ?? item.intervalLabel,
              style: TextStyle(color: context.pal.muted),
            ),
            if (split != null && split.participants.isNotEmpty)
              Text(
                'Chia với ${split.participants.map((p) => p.name).join(', ')} · '
                '${split.autoApply ? 'tự ghi nợ' : 'hỏi trước khi ghi'}',
                style: TextStyle(color: context.pal.muted, fontSize: 13),
              ),
            if (last != null)
              Text(
                last['state'] == 'PROPOSED'
                    ? 'Có khoản chờ bạn xác nhận'
                    : 'Lần khớp gần nhất: ${dateLabel(DateTime.tryParse('${last['created_at']}')?.toLocal() ?? DateTime.now())}',
                style: TextStyle(color: context.pal.accentInk, fontSize: 13),
              ),
            if (item.kind == 'EXPENSE')
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showFormSheet<void>(
                    context,
                    (_) => RecurringSplitSheet(rule: rule),
                  ),
                  icon: const Icon(Symbols.auto_mode_rounded, size: 18),
                  label: Text(
                    split == null
                        ? 'Bật tự nhận & chia tiền'
                        : 'Sửa quy tắc tự động',
                  ),
                ),
              ),
            for (final o in item.expected)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Symbols.schedule_rounded),
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
        PillTabs<String>(
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
        LabeledField(label: 'Tên', hint: 'Nhập tên', controller: _name),
        const SizedBox(height: 12),
        MoneyField(controller: _amount),
        const SizedBox(height: 12),
        PickField<String>(
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
          PickField<String>(
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
          PickField<String>(
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
        PillTabs<String>(
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
          tileColor: context.pal.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: const Icon(Symbols.event_rounded),
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
