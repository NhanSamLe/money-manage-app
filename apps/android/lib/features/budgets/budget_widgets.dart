import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/icons.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';
import 'budget_plan.dart';

/// Opens the "Ngân sách đề xuất" sheet (one tap "Áp dụng", each limit adjustable with a slider).
Future<void> showBudgetProposals(BuildContext context, ProposalSet set) =>
    showFormSheet<void>(context, (_) => BudgetProposalSheet(set: set));

class BudgetProposalSheet extends ConsumerStatefulWidget {
  const BudgetProposalSheet({super.key, required this.set});
  final ProposalSet set;
  @override
  ConsumerState<BudgetProposalSheet> createState() =>
      _BudgetProposalSheetState();
}

class _BudgetProposalSheetState extends ConsumerState<BudgetProposalSheet> {
  late final Map<String, int> _limit = {
    for (final p in widget.set.all) _key(p): p.proposed,
  };
  late final Set<String> _on = {
    for (final p in widget.set.all)
      if (p.isChange) _key(p),
  };
  bool _busy = false;
  String? _error;

  static String _key(BudgetProposal p) => p.categoryId ?? '*';

  Future<void> _apply() async {
    final items = [
      for (final p in widget.set.all)
        if (_on.contains(_key(p)))
          {'category_id': p.categoryId, 'limit': '${_limit[_key(p)]}'},
    ];
    if (items.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiProvider).post('/budgets/proposals/apply', {
        'month': widget.set.month,
        'items': items,
      });
      final n = ((r as Map)['applied'] as num?)?.toInt() ?? 0;
      refreshPlanning(ref);
      ref.invalidate(budgetProposalsProvider);
      ref.invalidate(budgetPacingProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(
        context,
        n == 0 ? 'Ngân sách đã đúng như đề xuất.' : 'Đã đặt $n ngân sách.',
      );
    } on ApiException catch (e) {
      setState(
        () => _error = e.code == 'OFFLINE'
            ? 'Cần có mạng để áp dụng ngân sách. Bạn thử lại khi online nhé.'
            : e.message,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final s = widget.set;
    final days = s.historyDays >= 90 ? '3 tháng' : '${s.historyDays} ngày';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ngân sách đề xuất tháng ${s.month.substring(5)}/${s.month.substring(0, 4)}',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'Theo $days chi tiêu thật của bạn. Đã tách khoản cố định (tiền nhà, hóa đơn định kỳ) '
          'và khoản lớn bất thường. Kéo để chỉnh nếu muốn.',
          style: TextStyle(color: pal.muted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 10),
        // showFormSheet already scrolls: plain rows here.
        for (final p in s.all)
          _ProposalRow(
            p: p,
            value: _limit[_key(p)]!,
            selected: _on.contains(_key(p)),
            onSelected: (v) =>
                setState(() => v ? _on.add(_key(p)) : _on.remove(_key(p))),
            onChanged: (v) => setState(() {
              _limit[_key(p)] = v;
              _on.add(_key(p));
            }),
          ),
        FormError(_error),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _apply,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  _on.isEmpty
                      ? 'Đóng'
                      : 'Áp dụng ${_on.length == s.all.length ? 'tất cả' : '${_on.length} ngân sách'}',
                ),
        ),
      ],
    );
  }
}

class _ProposalRow extends StatelessWidget {
  const _ProposalRow({
    required this.p,
    required this.value,
    required this.selected,
    required this.onSelected,
    required this.onChanged,
  });
  final BudgetProposal p;
  final int value;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final ValueChanged<int> onChanged;

  static const _step = 50000;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final min = ((p.proposed * 0.5) / _step).floor() * _step;
    final max = ((p.proposed * 2) / _step).ceil() * _step;
    final lo = min < _step ? _step : min;
    final hi = max <= lo ? lo + _step : max;
    final divisions = ((hi - lo) / _step).round().clamp(1, 200);
    final tone = switch (p.reason) {
      'raise' || 'realistic' => (pal.warnBg, pal.warnInk),
      'lower' => (pal.okBg, pal.accentInk),
      _ => (pal.tintSoft, pal.accentInk),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 4),
      decoration: BoxDecoration(
        color: p.categoryId == null ? pal.tintSoft : pal.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (v) => onSelected(v ?? false),
              ),
              Icon(
                p.categoryId == null
                    ? Symbols.account_balance_wallet_rounded
                    : categoryIcon(p.icon),
                color: pal.accentInk,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name,
                  style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tone.$1,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  p.reasonLabel,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: tone.$2,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatVnd(value),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: pal.ink,
                  ),
                ),
                if (p.currentLimit != null && p.currentLimit != value)
                  Text(
                    'Hiện tại ${formatVnd(p.currentLimit!)}',
                    style: TextStyle(fontSize: 12, color: pal.hint),
                  ),
                Text(
                  p.note,
                  style: TextStyle(
                    fontSize: 12,
                    color: pal.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Slider(
            value: value.clamp(lo, hi).toDouble(),
            min: lo.toDouble(),
            max: hi.toDouble(),
            divisions: divisions,
            label: shortMoney(value),
            onChanged: (v) => onChanged((v / _step).round() * _step),
          ),
        ],
      ),
    );
  }
}

/// Home card: "Hôm nay còn tiêu được ~X", the categories that run fastest with "mỗi ngày nên ~Y", or — with no
/// budgets yet — MoMa's one-tap proposal. Hidden when there is nothing useful to say.
class BudgetPacingCard extends ConsumerWidget {
  const BudgetPacingCard({super.key, this.hidden = false, this.mask = '••••'});
  final bool hidden;
  final String mask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final pace = ref.watch(budgetPacingProvider).value;
    String money(int v) => hidden ? mask : formatVnd(v);
    if (pace == null || pace.isEmpty) {
      final set = ref.watch(budgetProposalsProvider).value;
      if (set == null || set.items.isEmpty) return const SizedBox.shrink();
      return _Shell(
        child: Row(
          children: [
            Icon(Symbols.auto_awesome_rounded, color: pal.accentInk),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Để MoMa đặt ngân sách giúp bạn',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: pal.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${set.items.length} danh mục theo thói quen chi tiêu thật, tự cập nhật mỗi tháng.',
                    style: TextStyle(fontSize: 12.5, color: pal.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // The theme's buttons are full width; inside a Row it must be sized to its label.
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
              onPressed: () => showBudgetProposals(context, set),
              child: const Text('Xem'),
            ),
          ],
        ),
      );
    }
    final rows = [
      ...pace.items.where((i) => i.status != 'ok'),
      ...pace.items.where((i) => i.status == 'ok'),
    ].take(3).toList();
    return _Shell(
      onTap: () => context.push('/planning?tab=2'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.speed_rounded, color: pal.accentInk, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Hôm nay còn tiêu được',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: pal.muted,
                  ),
                ),
              ),
              Text(
                'Còn ${pace.daysLeft} ngày',
                style: TextStyle(fontSize: 12.5, color: pal.hint),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            money(pace.safeToday),
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: pace.safeToday > 0 ? pal.ink : MomaColors.expense,
            ),
          ),
          if (rows.isNotEmpty) const SizedBox(height: 8),
          for (final i in rows) _PaceRow(item: i, money: money),
        ],
      ),
    );
  }
}

class _PaceRow extends StatelessWidget {
  const _PaceRow({required this.item, required this.money});
  final PaceItem item;
  final String Function(int) money;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final color = switch (item.status) {
      'over' => MomaColors.expense,
      'fast' => const Color(0xFFE0A100),
      _ => MomaColors.emerald,
    };
    final usage = item.limit <= 0
        ? 0.0
        : (item.spent / item.limit).clamp(0.0, 1.0).toDouble();
    final hint = switch (item.status) {
      'over' => 'Đã vượt ${money(item.spent - item.limit)}',
      'fast' =>
        'Nhanh hơn ${item.aheadPct}% · mỗi ngày nên ~${money(item.dailyAllowance)}',
      _ => 'Mỗi ngày ~${money(item.dailyAllowance)}',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(categoryIcon(item.icon), size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.name,
                  style: TextStyle(fontWeight: FontWeight.w600, color: pal.ink),
                ),
              ),
              Flexible(
                child: Text(
                  hint,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: usage,
              minHeight: 5,
              backgroundColor: pal.bg,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

/// Banner on the budgets tab when MoMa has new or changed limits to suggest.
class BudgetProposalBanner extends ConsumerWidget {
  const BudgetProposalBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final set = ref.watch(budgetProposalsProvider).value;
    if (set == null || !set.hasChanges) return const SizedBox.shrink();
    final pal = context.pal;
    final n = set.all.where((p) => p.isChange).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: pal.tintSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Symbols.auto_awesome_rounded, color: pal.accentInk),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'MoMa có $n đề xuất ngân sách theo thói quen chi tiêu của bạn',
              style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
            ),
          ),
          TextButton(
            onPressed: () => showBudgetProposals(context, set),
            child: const Text('Xem'),
          ),
        ],
      ),
    );
  }
}
