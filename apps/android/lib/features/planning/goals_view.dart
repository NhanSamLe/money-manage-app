import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';

class GoalsView extends ConsumerWidget {
  const GoalsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(goalsProvider);
        await ref.read(goalsProvider.future);
      },
      child: goals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(goalsProvider)),
        data: (data) {
          final saved = data.goals.fold<int>(0, (s, g) => s + g.allocated);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Card(
                color: const Color(0xFFE9F6EE),
                child: ListTile(
                  title: const Text('Đã dành cho mục tiêu'),
                  subtitle: const Text(
                    'Chỉ là khoản dành riêng, không trừ vào số dư tài khoản.',
                  ),
                  trailing: Text(
                    formatVnd(saved),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              if (data.goals.isEmpty)
                const SizedBox(
                  height: 220,
                  child: EmptyState(
                    icon: Icons.savings_outlined,
                    title: 'Chưa có mục tiêu',
                    hint: 'Tạo mục tiêu tiết kiệm đầu tiên của bạn.',
                  ),
                ),
              for (final g in data.goals) _GoalCard(goal: g, data: data),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    showFormSheet<void>(context, (_) => const _AddGoalSheet()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Tạo mục tiêu mới'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.data});
  final Goal goal;
  final GoalsData data;

  @override
  Widget build(BuildContext context) {
    final done = goal.state == 'COMPLETED';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showFormSheet<void>(
          context,
          (_) => _GoalMoveSheet(goal: goal, accounts: data.accounts),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      goal.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (done)
                    const Chip(
                      label: Text('Hoàn thành'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: goal.progress,
                  minHeight: 8,
                  backgroundColor: MomaColors.cloud,
                  color: MomaColors.emerald,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${formatVnd(goal.allocated)} / ${formatVnd(goal.target)}  (${(goal.progress * 100).round()}%)',
                style: const TextStyle(color: MomaColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
      }, commandId: _id),
    );
    if (ok && mounted) {
      refreshPlanning(ref);
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
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.flag_outlined),
            hintText: 'Tên mục tiêu (vd: Du lịch Đà Lạt)',
          ),
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _target, hint: 'Số tiền cần đạt'),
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
      refreshPlanning(ref);
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
          style: const TextStyle(color: MomaColors.muted),
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Dành thêm')),
            ButtonSegment(value: true, label: Text('Rút lại')),
          ],
          selected: {_release},
          onSelectionChanged: (s) => setState(() => _release = s.first),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
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
