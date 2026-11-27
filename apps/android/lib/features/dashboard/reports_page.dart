import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/charts/bar_chart.dart';
import '../../core/ui/charts/donut_chart.dart';
import '../../core/ui/charts/sparkline.dart';
import '../../core/ui/header.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import '../reports/month_picker_sheet.dart';
import '../reports/report_data.dart';

enum _Tab { overview, expense, income }

/// "Báo cáo": month selector, overview / spending / income tabs, category share and day-by-day bars.
/// Totals come from the server summary; the daily series and income breakdown are aggregated client-side
/// from the month's transactions (no date-range report endpoint exists).
class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key});

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  _Tab _tab = _Tab.overview;
  bool _weekly = false;

  Future<void> _refresh() async {
    final month = ref.read(selectedMonthProvider);
    ref.invalidate(summaryProvider);
    ref.invalidate(monthTransactionsProvider(month));
    ref.invalidate(monthSummaryProvider(shiftMonth(month, -1)));
    ref.invalidate(categoriesProvider);
    await ref.read(summaryProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider);
    final month = ref.watch(selectedMonthProvider);
    return MomaPage(
      title: 'Báo cáo',
      subtitle: 'Phân tích thu chi theo tháng',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _MonthBar(month: month),
            const SizedBox(height: 12),
            PillTabs<_Tab>(
              segments: const [
                ButtonSegment(value: _Tab.overview, label: Text('Tổng quan')),
                ButtonSegment(value: _Tab.expense, label: Text('Chi tiêu')),
                ButtonSegment(value: _Tab.income, label: Text('Thu nhập')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(height: 12),
            summary.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SizedBox(
                height: 280,
                child: ErrorView(
                  error: e,
                  onRetry: () => ref.invalidate(summaryProvider),
                ),
              ),
              data: (s) => _Body(
                month: month,
                summary: s,
                tab: _tab,
                weekly: _weekly,
                onWeekly: (v) => setState(() => _weekly = v),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ month selector

class _MonthBar extends ConsumerWidget {
  const _MonthBar({required this.month});
  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final notifier = ref.read(selectedMonthProvider.notifier);
    final atLatest = month.compareTo(currentMonthKey()) >= 0;
    return Row(
      children: [
        _RoundButton(
          tooltip: 'Tháng trước',
          icon: Symbols.chevron_left_rounded,
          onTap: () => notifier.shift(-1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Material(
            color: pal.surface,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                final v = await showMonthPickerSheet(context, month);
                if (v != null) notifier.set(v);
              },
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: pal.line),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Symbols.calendar_month_rounded,
                      size: 18,
                      color: MomaColors.emerald,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Tháng ${monthNumber(month)}, ${monthYear(month)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    Icon(
                      Symbols.keyboard_arrow_down_rounded,
                      size: 20,
                      color: pal.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _RoundButton(
          tooltip: 'Tháng sau',
          icon: Symbols.chevron_right_rounded,
          onTap: atLatest ? null : () => notifier.shift(1),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, this.onTap});
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: pal.surface,
        shape: CircleBorder(side: BorderSide(color: pal.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 22,
              color: onTap == null ? pal.hint : pal.ink,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ body

class _Body extends ConsumerWidget {
  const _Body({
    required this.month,
    required this.summary,
    required this.tab,
    required this.weekly,
    required this.onWeekly,
  });
  final String month;
  final Summary summary;
  final _Tab tab;
  final bool weekly;
  final ValueChanged<bool> onWeekly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summary;
    final label = 'tháng ${monthNumber(month)}/${monthYear(month)}';
    if (s.income == 0 && s.expense == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: EmptyState(
          embedded: true,
          icon: Symbols.bar_chart_rounded,
          title: 'Chưa có dữ liệu',
          hint:
              'Không có khoản thu hay chi nào trong $label. Hãy chọn tháng khác hoặc thêm giao dịch.',
        ),
      );
    }

    final txs = ref.watch(monthTransactionsProvider(month));
    final prev = ref.watch(monthSummaryProvider(shiftMonth(month, -1))).value;
    final series = txs.whenData((t) => DailySeries.from(t, month));
    final income = tab == _Tab.income;
    final tabEmpty = income ? s.income == 0 : s.expense == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(
          month: month,
          summary: s,
          prev: prev,
          tab: tab,
          series: series.value,
        ),
        const SizedBox(height: 12),
        if (tabEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: EmptyState(
              embedded: true,
              icon: income ? Symbols.savings_rounded : Symbols.wallet_rounded,
              title: income ? 'Chưa có thu nhập' : 'Chưa có chi tiêu',
              hint: income
                  ? 'Không ghi nhận khoản thu nào trong $label.'
                  : 'Không ghi nhận khoản chi nào trong $label.',
            ),
          )
        else ...[
          _ShareCard(month: month, summary: s, income: income, txs: txs),
          const SizedBox(height: 12),
          _TimeCard(
            month: month,
            income: income,
            series: series,
            weekly: weekly,
            onWeekly: onWeekly,
            onRetry: () => ref.invalidate(monthTransactionsProvider(month)),
          ),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

String _pct(double v) {
  final s = v.toStringAsFixed(1).replaceAll('.', ',');
  return s.endsWith(',0') ? s.substring(0, s.length - 2) : s;
}

String _ddmm(String month, int day) =>
    '${day.toString().padLeft(2, '0')}/${monthNumber(month).toString().padLeft(2, '0')}';

/// Days of [month] that have happened so far (all of them for past months).
int _elapsedDays(String month) {
  final n = daysInMonth(month);
  final now = currentMonthKey();
  if (month.compareTo(now) > 0) return 0;
  if (month == now) return vnDate(DateTime.now()).day.clamp(1, n);
  return n;
}

List<double> _cumulative(List<int> daily, int upTo) {
  final out = <double>[];
  var acc = 0;
  for (var i = 0; i < upTo && i < daily.length; i++) {
    acc += daily[i];
    out.add(acc.toDouble());
  }
  return out;
}

// ------------------------------------------------------------------ summary

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.month,
    required this.summary,
    required this.prev,
    required this.tab,
    required this.series,
  });
  final String month;
  final Summary summary;
  final Summary? prev;
  final _Tab tab;
  final DailySeries? series;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final s = summary;
    final period = month == currentMonthKey()
        ? 'tháng này'
        : 'tháng ${monthNumber(month)}/${monthYear(month)}';
    final net = s.income - s.expense;

    final String title;
    final String amount;
    final Color amountColor;
    final Color lineColor;
    List<double> spark = const [];
    final days = _elapsedDays(month);
    final se = series;
    switch (tab) {
      case _Tab.overview:
        title = 'Chênh lệch thu chi $period';
        amount = '${net >= 0 ? '+' : '-'}${formatVnd(net.abs())}';
        amountColor = net >= 0 ? MomaColors.income : MomaColors.expense;
        lineColor = MomaColors.emerald;
        if (se != null) {
          spark = _cumulative([
            for (var i = 0; i < se.income.length; i++)
              se.income[i] - se.expense[i],
          ], days);
        }
      case _Tab.expense:
        title = 'Tổng chi tiêu $period';
        amount = formatVnd(s.expense);
        amountColor = pal.ink;
        lineColor = MomaColors.expense;
        if (se != null) spark = _cumulative(se.expense, days);
      case _Tab.income:
        title = 'Tổng thu nhập $period';
        amount = formatVnd(s.income);
        amountColor = pal.ink;
        lineColor = MomaColors.income;
        if (se != null) spark = _cumulative(se.income, days);
    }

    final p = prev;
    Widget? badge;
    if (p != null) {
      final incomeTab = tab == _Tab.income;
      final cur = incomeTab ? s.income : s.expense;
      final before = incomeTab ? p.income : p.expense;
      final prefix = tab == _Tab.overview ? 'Chi tiêu ' : '';
      if (before > 0) {
        final change = (cur - before) / before * 100;
        badge = _ChangeBadge(
          change: change,
          prefix: prefix,
          goodWhenUp: incomeTab,
        );
      }
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: pal.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        amount,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: amountColor,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (badge != null) ...[const SizedBox(height: 6), badge],
                  ],
                ),
              ),
              if (spark.length >= 2) ...[
                const SizedBox(width: 12),
                Sparkline(values: spark, color: lineColor, width: 88),
              ],
            ],
          ),
          if (tab == _Tab.overview) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MiniFlow(
                    label: 'Thu nhập',
                    value: '+${formatVnd(s.income)}',
                    color: MomaColors.income,
                    icon: Symbols.south_west_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniFlow(
                    label: 'Chi tiêu',
                    value: '-${formatVnd(s.expense)}',
                    color: MomaColors.expense,
                    icon: Symbols.north_east_rounded,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge({
    required this.change,
    required this.prefix,
    required this.goodWhenUp,
  });
  final double change;
  final String prefix;
  final bool goodWhenUp;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final flat = change.abs() < 0.05;
    final up = change > 0;
    final color = flat
        ? pal.muted
        : (up == goodWhenUp ? MomaColors.income : MomaColors.expense);
    final text = flat
        ? '${prefix}không đổi so với tháng trước'
        : '$prefix${up ? '+' : '-'}${_pct(change.abs())}% so với tháng trước';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            flat
                ? Symbols.remove_rounded
                : up
                ? Symbols.trending_up_rounded
                : Symbols.trending_down_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniFlow extends StatelessWidget {
  const _MiniFlow({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: context.pal.muted, fontSize: 12),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------ category share

const _fallbackSlice = [
  Color(0xFF21896E),
  Color(0xFFFF8A3D),
  Color(0xFF2F80ED),
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFFF2B705),
];
const _otherColor = Color(0xFF94A3B8);

class _Slice {
  _Slice(this.name, this.icon, this.amount, this.color, {this.other = false});
  final String name;
  final String? icon;
  final int amount;
  final Color color;
  final bool other;
}

List<_Slice> _slices(List<CategorySpend> items) {
  final list = items.where((c) => c.amount > 0).toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));
  final head = list.length <= 5 ? list : list.take(4).toList();
  final rest = list.length <= 5
      ? 0
      : list.skip(4).fold(0, (a, c) => a + c.amount);
  final used = <int>{};
  var fb = 0;
  final out = <_Slice>[];
  for (final c in head) {
    var color = categoryStyle(c.icon).color;
    if (color == const Color(0xFF64748B) || used.contains(color.toARGB32())) {
      while (fb < _fallbackSlice.length - 1 &&
          used.contains(_fallbackSlice[fb].toARGB32())) {
        fb++;
      }
      color = _fallbackSlice[fb % _fallbackSlice.length];
      fb++;
    }
    used.add(color.toARGB32());
    out.add(_Slice(c.name, c.icon, c.amount, color));
  }
  if (rest > 0) out.add(_Slice('Khác', null, rest, _otherColor, other: true));
  return out;
}

class _ShareCard extends ConsumerWidget {
  const _ShareCard({
    required this.month,
    required this.summary,
    required this.income,
    required this.txs,
  });
  final String month;
  final Summary summary;
  final bool income;
  final AsyncValue<List<MomaTx>> txs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final title = income
        ? 'Tỷ trọng thu nhập theo danh mục'
        : 'Tỷ trọng chi tiêu theo danh mục';

    Widget content;
    if (!income) {
      content = _shareContent(context, _slices(summary.byCategory), false);
    } else {
      final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
      content = txs.when(
        loading: () => const SizedBox(
          height: 180,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => SizedBox(
          height: 220,
          child: ErrorView(
            error: e,
            onRetry: () => ref.invalidate(monthTransactionsProvider(month)),
          ),
        ),
        data: (t) =>
            _shareContent(context, _slices(incomeByCategory(t, cats)), true),
      );
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: pal.ink,
            ),
          ),
          const SizedBox(height: 14),
          content,
        ],
      ),
    );
  }

  Widget _shareContent(BuildContext context, List<_Slice> slices, bool inc) {
    final pal = context.pal;
    final total = slices.fold<int>(0, (a, s) => a + s.amount);
    if (total <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(
          'Chưa có dữ liệu theo danh mục.',
          textAlign: TextAlign.center,
          style: TextStyle(color: pal.muted, fontSize: 13),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: DonutChart(
            values: [for (final s in slices) s.amount.toDouble()],
            colors: [for (final s in slices) s.color],
            trackColor: pal.lineSoft,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  inc ? 'Tổng thu' : 'Tổng chi',
                  style: TextStyle(color: pal.muted, fontSize: 12),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatVnd(total),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: pal.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final s in slices) _LegendRow(slice: s, total: total),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.slice, required this.total});
  final _Slice slice;
  final int total;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final share = total <= 0 ? 0.0 : slice.amount / total * 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          CategoryAvatar(
            iconKey: slice.icon,
            iconData: slice.other ? Symbols.more_horiz_rounded : null,
            color: slice.color,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              slice.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: pal.ink,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 46,
            child: Text(
              '${_pct(share)}%',
              textAlign: TextAlign.right,
              style: TextStyle(color: pal.muted, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatVnd(slice.amount),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: pal.ink,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ over time

class _TimeCard extends StatelessWidget {
  const _TimeCard({
    required this.month,
    required this.income,
    required this.series,
    required this.weekly,
    required this.onWeekly,
    required this.onRetry,
  });
  final String month;
  final bool income;
  final AsyncValue<DailySeries> series;
  final bool weekly;
  final ValueChanged<bool> onWeekly;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  income
                      ? 'Thu nhập theo thời gian'
                      : 'Chi tiêu theo thời gian',
                  maxLines: 2,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: pal.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _MiniToggle(weekly: weekly, onChanged: onWeekly),
            ],
          ),
          const SizedBox(height: 14),
          series.when(
            loading: () => const SizedBox(
              height: 190,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SizedBox(
              height: 220,
              child: ErrorView(error: e, onRetry: onRetry),
            ),
            data: (s) => _chart(context, income ? s.income : s.expense),
          ),
        ],
      ),
    );
  }

  Widget _chart(BuildContext context, List<int> daily) {
    final pal = context.pal;
    final color = income ? MomaColors.income : MomaColors.expense;
    final List<int> values;
    final List<String> labels;
    final List<String> tips;
    if (weekly) {
      final w = weeklyBuckets(daily);
      values = [for (final b in w) b.amount];
      labels = [for (final b in w) b.label];
      tips = [
        for (final b in w)
          '${_ddmm(month, b.from)}–${_ddmm(month, b.to)}: ${formatVnd(b.amount)}',
      ];
    } else {
      values = daily;
      labels = [
        for (var d = 1; d <= daily.length; d++)
          (d == 1 || d % 5 == 0) ? '$d' : '',
      ];
      tips = [
        for (var d = 1; d <= daily.length; d++)
          '${_ddmm(month, d)}: ${formatVnd(daily[d - 1])}',
      ];
    }

    final total = daily.fold<int>(0, (a, b) => a + b);
    final days = _elapsedDays(month);
    final avg = days == 0 ? 0 : (total / days).round();
    int? hi;
    int? lo;
    for (var i = 0; i < daily.length; i++) {
      if (daily[i] <= 0) continue;
      if (hi == null || daily[i] > daily[hi]) hi = i;
      if (lo == null || daily[i] < daily[lo]) lo = i;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MoneyBarChart(
          key: ValueKey('$month-$weekly-$income'),
          values: values,
          labels: labels,
          tooltips: tips,
          color: color,
          gridColor: pal.lineSoft,
          labelColor: pal.muted,
          tooltipColor: pal.ink,
          tooltipTextColor: pal.surface,
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: pal.surfaceAlt,
            borderRadius: BorderRadius.circular(14),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'TB mỗi ngày',
                    value: formatVnd(avg),
                    sub: days > 0 ? '$days ngày' : '—',
                  ),
                ),
                VerticalDivider(width: 1, color: pal.line),
                Expanded(
                  child: _Stat(
                    label: 'Cao nhất',
                    value: hi == null ? '—' : formatVnd(daily[hi]),
                    sub: hi == null ? '—' : 'ngày ${_ddmm(month, hi + 1)}',
                  ),
                ),
                VerticalDivider(width: 1, color: pal.line),
                Expanded(
                  child: _Stat(
                    label: 'Thấp nhất',
                    value: lo == null ? '—' : formatVnd(daily[lo]),
                    sub: lo == null ? '—' : 'ngày ${_ddmm(month, lo + 1)}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub});
  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pal.muted, fontSize: 11),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: pal.ink,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pal.hint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({required this.weekly, required this.onChanged});
  final bool weekly;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    Widget seg(String text, bool value) {
      final on = weekly == value;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? pal.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: on ? FontWeight.w800 : FontWeight.w600,
              color: on ? MomaColors.emerald : pal.muted,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: pal.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('Theo ngày', false), seg('Theo tuần', true)],
      ),
    );
  }
}
