import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
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

import 'package:material_symbols_icons/symbols.dart';

String _currentMonth() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
}

class BudgetsView extends ConsumerWidget {
  const BudgetsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgets = ref.watch(budgetsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(budgetsProvider);
        await ref.read(budgetsProvider.future);
      },
      child: budgets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(budgetsProvider)),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Text(
              'Ngân sách tháng ${_currentMonth().substring(5)}/${_currentMonth().substring(0, 4)}',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            if (list.isEmpty)
              const EmptyState(embedded: true, 
                  icon: Symbols.pie_chart_outline_rounded,
                  title: 'Chưa có ngân sách',
                  hint: 'Đặt hạn mức chi tiêu cho tháng này.',
                ),
            for (final b in list) _BudgetCard(budget: b),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  showFormSheet<void>(context, (_) => const _BudgetSheet()),
              icon: const Icon(Symbols.add_rounded),
              label: const Text('Thêm ngân sách'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({required this.budget});
  final Budget budget;

  @override
  Widget build(BuildContext context) {
    final b = budget;
    final color = b.over
        ? MomaColors.expense
        : (b.usage > 0.8 ? const Color(0xFFE0A100) : MomaColors.emerald);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            showFormSheet<void>(context, (_) => _BudgetSheet(existing: b)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(categoryIcon(b.icon), color: MomaColors.forest),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      b.categoryName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    b.over
                        ? 'Vượt ${formatVnd(-b.remaining)}'
                        : 'Còn ${formatVnd(b.remaining)}',
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: b.usage,
                  minHeight: 8,
                  backgroundColor: context.pal.bg,
                  color: color,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Đã chi ${formatVnd(b.spent)} / ${formatVnd(b.effectiveLimit)}'
                '${b.carried > 0 ? ' (gồm ${formatVnd(b.carried)} chuyển từ tháng trước)' : ''}',
                style: TextStyle(color: context.pal.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BudgetSheet extends ConsumerStatefulWidget {
  const _BudgetSheet({this.existing});
  final Budget? existing;
  @override
  ConsumerState<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends ConsumerState<_BudgetSheet> {
  late final FormRunner _run = FormRunner(setState);
  final _limit = TextEditingController();
  String? _categoryId;
  bool _carryover = false;
  final String _id = ApiClient.newId();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _limit.text = formatVnd(e.limit).replaceAll(' ₫', '');
      _categoryId = e.categoryId;
      _carryover = e.carryover;
    }
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final limit = parseVndInput(_limit.text);
    if (limit == null || limit <= 0) {
      setState(() => _run.error = 'Nhập hạn mức hợp lệ.');
      return;
    }
    final ok = await _run.run(
      () => ref.read(apiProvider).command('BUDGET_UPSERT', {
        'month': _currentMonth(),
        'limit': limit.toString(),
        'carryover': _carryover,
        'category_id': ?_categoryId,
        if (widget.existing != null)
          'expected_version': widget.existing!.version,
      }, commandId: _id),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = (ref.watch(categoriesProvider).value ?? <Category>[])
        .where((c) => c.type == 'EXPENSE')
        .toList();
    final editing = widget.existing != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          editing ? 'Sửa ngân sách' : 'Thêm ngân sách',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        PickField<String?>(
          isExpanded: true,
          initialValue: _categoryId,
          decoration: const InputDecoration(labelText: 'Danh mục'),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Tổng chi tiêu'),
            ),
            for (final c in cats)
              DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
          ],
          onChanged: editing ? null : (v) => setState(() => _categoryId = v),
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _limit, hint: 'Hạn mức'),
        LabeledSwitch(
          label: 'Chuyển phần chưa dùng sang tháng sau',
          help: 'Nếu tháng này chi ít hơn hạn mức, phần còn lại được cộng vào hạn mức tháng sau.',
          value: _carryover,
          onChanged: (v) => setState(() => _carryover = v),
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu ngân sách'),
        ),
      ],
    );
  }
}
