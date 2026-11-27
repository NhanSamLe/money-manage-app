import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import '../goals/goal_insights.dart';
import '../goals/goal_widgets.dart';
import '../../core/ui/moma_switch.dart';
import '../../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

/// "Tiết kiệm" tab: overview, status filter and one card per goal. Tapping a card opens the
/// existing save/withdraw sheet.
class GoalsView extends ConsumerStatefulWidget {
  const GoalsView({super.key});

  @override
  ConsumerState<GoalsView> createState() => _GoalsViewState();
}

enum _GoalFilter { all, active, done }

class _GoalsViewState extends ConsumerState<GoalsView> {
  _GoalFilter _filter = _GoalFilter.all;

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(goalsBoardProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(goalsProvider);
        ref.invalidate(goalsBoardProvider);
        await ref.read(goalsBoardProvider.future);
      },
      child: board.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(goalsBoardProvider),
        ),
        data: (b) {
          final now = DateTime.now();
          final active = b.items.where((i) => !i.done).toList();
          final done = b.items.where((i) => i.done).toList();
          final shown = switch (_filter) {
            _GoalFilter.all => b.items,
            _GoalFilter.active => active,
            _GoalFilter.done => done,
          };
          void create() =>
              showFormSheet<void>(context, (_) => const _AddGoalSheet());
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (b.items.isEmpty)
                EmptyState(
                  embedded: true,
                  icon: Symbols.savings_rounded,
                  title: 'Chưa có mục tiêu',
                  hint: 'Tạo mục tiêu tiết kiệm đầu tiên của bạn.',
                  actionLabel: 'Tạo mục tiêu mới',
                  onAction: create,
                )
              else ...[
                GoalsSummaryCard(board: b),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (f, label, n) in [
                        (_GoalFilter.all, 'Tất cả', b.items.length),
                        (_GoalFilter.active, 'Đang thực hiện', active.length),
                        (_GoalFilter.done, 'Đã hoàn thành', done.length),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GoalFilterChip(
                            label: '$label ($n)',
                            active: _filter == f,
                            onTap: () => setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _filter == _GoalFilter.done
                          ? 'Chưa có mục tiêu nào hoàn thành.'
                          : 'Không có mục tiêu đang thực hiện.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: context.pal.muted),
                    ),
                  ),
                for (final i in shown)
                  GoalCard(
                    item: i,
                    now: now,
                    onTap: () => showFormSheet<void>(
                      context,
                      (_) => _GoalMoveSheet(
                        goal: i.goal,
                        accounts: b.data.accounts,
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: create,
                  icon: const Icon(Symbols.add_rounded),
                  label: const Text('Tạo mục tiêu mới'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Goal commands change balances too: refresh planning read models and this tab's board.
void _refreshGoals(WidgetRef ref) {
  refreshPlanning(ref);
  ref.invalidate(goalsBoardProvider);
}

class _AddGoalSheet extends ConsumerStatefulWidget {
  const _AddGoalSheet();
  @override
  ConsumerState<_AddGoalSheet> createState() => _AddGoalSheetState();
}

class _AddGoalSheetState extends ConsumerState<_AddGoalSheet> {
  late final FormRunner _run = FormRunner(setState);
  final _name = TextEditingController();
  final _target = TextEditingController();
  DateTime? _due;
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final target = parseVndInput(_target.text);
    if (_name.text.trim().isEmpty || target == null || target <= 0) {
      setState(() => _run.error = 'Nhập tên và số tiền mục tiêu.');
      return;
    }
    final ok = await _run.run(
      () => ref.read(apiProvider).command('GOAL_CREATE', {
        'name': _name.text.trim(),
        'target': target.toString(),
        if (_due != null) 'due_date': isoDate(_due!),
      }, commandId: _id),
    );
    if (ok && mounted) {
      _refreshGoals(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mục tiêu tiết kiệm',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: 'Tên mục tiêu',
          hint: 'Nhập tên mục tiêu',
          controller: _name,
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _target, hint: 'Số tiền cần đạt'),
        const SizedBox(height: 12),
        DateField(
          label: 'Hạn hoàn thành (không bắt buộc)',
          value: _due,
          firstDate: DateTime.now(),
          onChanged: (d) => setState(() => _due = d),
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Tạo mục tiêu'),
        ),
      ],
    );
  }
}

class _GoalMoveSheet extends ConsumerStatefulWidget {
  const _GoalMoveSheet({required this.goal, required this.accounts});
  final Goal goal;
  final List<GoalAccount> accounts;
  @override
  ConsumerState<_GoalMoveSheet> createState() => _GoalMoveSheetState();
}

class _GoalMoveSheetState extends ConsumerState<_GoalMoveSheet> {
  late final FormRunner _run = FormRunner(setState);
  bool _release = false;
  final _amount = TextEditingController();
  String? _accountId;
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = parseVndInput(_amount.text);
    if (amount == null || amount <= 0 || _accountId == null) {
      setState(() => _run.error = 'Chọn tài khoản và nhập số tiền.');
      return;
    }
    final ok = await _run.run(
      () => ref.read(apiProvider).command(
        _release ? 'GOAL_RELEASE' : 'GOAL_ALLOCATE',
        {
          'goal_id': widget.goal.id,
          'account_id': _accountId,
          'amount': amount.toString(),
          'expected_version': widget.goal.version,
        },
        commandId: _id,
      ),
    );
    if (ok && mounted) {
      _refreshGoals(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.goal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          g.name,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(
          '${formatVnd(g.allocated)} / ${formatVnd(g.target)}',
          style: TextStyle(color: context.pal.muted),
        ),
        const SizedBox(height: 12),
        PillTabs<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Dành thêm')),
            ButtonSegment(value: true, label: Text('Rút lại')),
          ],
          selected: {_release},
          onSelectionChanged: (s) => setState(() => _release = s.first),
        ),
        const SizedBox(height: 12),
        PickField<String>(
          isExpanded: true,
          initialValue: _accountId,
          decoration: const InputDecoration(labelText: 'Tài khoản'),
          items: [
            for (final a in widget.accounts)
              DropdownMenuItem(
                value: a.accountId,
                child: Text(
                  _release
                      ? a.name
                      : '${a.name} · khả dụng ${formatVnd(a.available)}',
                ),
              ),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _amount, hint: 'Số tiền'),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: Text(_release ? 'Rút lại' : 'Dành thêm'),
        ),
      ],
    );
  }
}
