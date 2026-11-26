import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(summaryProvider);
    final month = ref.watch(selectedMonthProvider);
    final email = _ownerEmail();
    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(summaryProvider);
        await ref.read(summaryProvider.future);
      },
      child: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(summaryProvider)),
        data: (s) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
          children: [
            Text(
              'Xin chào 👋',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: MomaColors.forest,
              ),
            ),
            Text(email, style: const TextStyle(color: MomaColors.muted)),
            const SizedBox(height: 16),
            _BalanceCard(summary: s),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Thu nhập',
                    value: s.income,
                    color: MomaColors.income,
                    icon: Icons.south_west_rounded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatTile(
                    label: 'Chi tiêu',
                    value: s.expense,
                    color: MomaColors.expense,
                    icon: Icons.north_east_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Chi tiêu theo danh mục',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (s.byCategory.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Chưa có chi tiêu trong tháng này.',
                    style: TextStyle(color: MomaColors.muted),
                  ),
                ),
              )
            else
              ...s.byCategory.map(
                (c) => _CategoryRow(spend: c, total: s.expense),
              ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        _MonthBar(month: month),
        Expanded(child: body),
      ],
    );
  }
}

/// Owner email for the greeting; empty if the auth client is not available (tests, signed out).
String _ownerEmail() {
  try {
    return Supabase.instance.client.auth.currentUser?.email ?? '';
  } on Object {
    return '';
  }
}

class _MonthBar extends ConsumerWidget {
  const _MonthBar({required this.month});
  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(selectedMonthProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Tháng trước',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () => notifier.shift(-1),
        ),
        Text(
          'Tháng ${month.substring(5)}/${month.substring(0, 4)}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        IconButton(
          tooltip: 'Tháng sau',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: () => notifier.shift(1),
        ),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.summary});
  final Summary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [MomaColors.forest, MomaColors.emerald],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tài sản ròng', style: TextStyle(color: MomaColors.mint)),
          const SizedBox(height: 6),
          Text(
            formatVnd(summary.netWorth),
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          if (summary.unknownBaselines > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Chưa gồm ${summary.unknownBaselines} tài khoản chưa biết số dư đầu kỳ.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: MomaColors.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatVnd(value),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.spend, required this.total});
  final CategorySpend spend;
  final int total;

  @override
  Widget build(BuildContext context) {
    final share = total <= 0 ? 0.0 : (spend.amount / total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: MomaColors.mint.withValues(alpha: 0.4),
                  child: Icon(
                    categoryIcon(spend.icon),
                    color: MomaColors.forest,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    spend.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatVnd(spend.amount),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: share,
                minHeight: 6,
                backgroundColor: MomaColors.cloud,
                color: MomaColors.emerald,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
