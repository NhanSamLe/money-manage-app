import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/header.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'insights_data.dart';
import 'staged_status.dart';

String _d2(int v) => v.toString().padLeft(2, '0');

String _range(Insight i) {
  final s = i.periodStart;
  final e = i.periodEnd;
  if (s == null) return '';
  if (e == null || i.period == InsightPeriod.day || !e.isAfter(s)) {
    return '${_d2(s.day)}/${_d2(s.month)}/${s.year}';
  }
  return '${_d2(s.day)}/${_d2(s.month)} – ${_d2(e.day)}/${_d2(e.month)}/${e.year}';
}

String _pct(double v) {
  final r = (v * 10).round() / 10;
  final txt = r == r.roundToDouble()
      ? r.abs().toStringAsFixed(0)
      : r.abs().toStringAsFixed(1).replaceAll('.', ',');
  return '${r > 0 ? '+' : (r < 0 ? '-' : '')}$txt%';
}

String _money(int? v) => v == null ? '—' : formatVnd(v);

/// "Phân tích & đề xuất": latest analysis per period, a run-now button and the history of earlier analyses.
class InsightsPage extends ConsumerStatefulWidget {
  const InsightsPage({super.key});

  @override
  ConsumerState<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends ConsumerState<InsightsPage> {
  InsightPeriod _period = InsightPeriod.month;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final res = await runInsight(ref.read(apiProvider), _period);
      if (!mounted) return;
      if (res.reused) {
        showSnack(
          context,
          'Đã có phân tích gần đây, hiển thị kết quả mới nhất',
        );
      }
      ref.invalidate(insightsProvider(_period));
      await ref
          .read(insightsProvider(_period).future)
          .catchError((_) => <Insight>[]);
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(
        context,
        isNotDeployed(e)
            ? 'Tính năng phân tích chưa sẵn sàng trên máy chủ. Bạn thử lại sau nhé.'
            : (e is ApiException
                  ? e.message
                  : 'Không phân tích được lúc này. Bạn thử lại sau ít phút nhé.'),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(insightsProvider(_period));
    return Scaffold(
      body: MomaPage(
        title: 'Phân tích & đề xuất',
        showBack: true,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(insightsProvider(_period));
            await ref
                .read(insightsProvider(_period).future)
                .catchError((_) => <Insight>[]);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              PillTabs<InsightPeriod>(
                segments: [
                  for (final p in InsightPeriod.values)
                    ButtonSegment(value: p, label: Text(p.label)),
                ],
                selected: {_period},
                onSelectionChanged: _running
                    ? (_) {}
                    : (s) => setState(() => _period = s.first),
              ),
              const SizedBox(height: 12),
              if (_running)
                const StagedStatus()
              else
                ...async.when(
                  loading: () => const [StagedStatus()],
                  error: (e, _) => [
                    if (isNotDeployed(e))
                      const EmptyState(
                        embedded: true,
                        icon: Symbols.insights_rounded,
                        title: 'Tính năng sắp có',
                        hint: 'Phân tích và đề xuất chi tiêu đang được chuẩn bị. Bạn quay lại sau nhé.',
                      )
                    else
                      ErrorView(
                        error: e,
                        onRetry: () =>
                            ref.invalidate(insightsProvider(_period)),
                      ),
                  ],
                  data: (list) => [
                    if (list.isEmpty)
                      EmptyState(
                        embedded: true,
                        icon: Symbols.insights_rounded,
                        title: 'Chưa có phân tích',
                        hint:
                            'Bấm "Phân tích ngay" để MoMa xem thu chi ${_period.label.toLowerCase()} này và gợi ý cách chi tiêu hợp lý hơn.',
                      )
                    else ...[
                      InsightView(insight: list.first),
                      if (list.length > 1) ...[
                        const SizedBox(height: 8),
                        const _SectionTitle('Các lần phân tích trước'),
                        Material(
                          color: context.pal.surface,
                          borderRadius: BorderRadius.circular(20),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (final (i, it) in list.skip(1).indexed) ...[
                                if (i > 0)
                                  Divider(
                                    height: 1,
                                    color: context.pal.lineSoft,
                                  ),
                                _HistoryRow(insight: it),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              const SizedBox(height: 16),
              _RunButton(running: _running, onRun: _run),
            ],
          ),
        ),
      ),
    );
  }
}

/// Run-now button (kept separate so the page body stays readable).
class _RunButton extends StatelessWidget {
  const _RunButton({required this.running, required this.onRun});
  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: running ? null : onRun,
    icon: const Icon(Symbols.auto_awesome_rounded, size: 20),
    label: const Text('Phân tích ngay'),
  );
}

/// Detail of one analysis (opened from history or from an "insight" push).
class InsightDetailPage extends ConsumerWidget {
  const InsightDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(insightProvider(id));
    return Scaffold(
      body: MomaPage(
        title: 'Chi tiết phân tích',
        showBack: true,
        child: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Align(alignment: Alignment.topCenter, child: StagedStatus()),
          ),
          error: (e, _) => isNotDeployed(e)
              ? const EmptyState(
                  icon: Symbols.insights_rounded,
                  title: 'Không tìm thấy phân tích',
                  hint: 'Phân tích này không còn hoặc tính năng chưa sẵn sàng.',
                )
              : ErrorView(
                  error: e,
                  onRetry: () => ref.invalidate(insightProvider(id)),
                ),
          data: (i) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [InsightView(insight: i)],
          ),
        ),
      ),
    );
  }
}

/// Full presentation of one analysis: summary card with key numbers, highlights, suggestions, category changes.
class InsightView extends StatelessWidget {
  const InsightView({super.key, required this.insight});
  final Insight insight;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final n = insight.numbers;
    final cats = [...n.byCategory]
      ..sort(
        (a, b) => (b.amount - b.prevAmount).abs().compareTo(
          (a.amount - a.prevAmount).abs(),
        ),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Symbols.auto_awesome_rounded,
                    color: MomaColors.emerald,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      insight.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: pal.ink,
                      ),
                    ),
                  ),
                ],
              ),
              if (_range(insight).isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '${insight.period.label} · ${_range(insight)}',
                  style: TextStyle(fontSize: 12.5, color: pal.muted),
                ),
              ],
              if (insight.summary.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  insight.summary,
                  style: TextStyle(fontSize: 14, height: 1.45, color: pal.ink),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _Num(
                      label: 'Thu',
                      value: _money(n.income),
                      color: MomaColors.income,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Num(
                      label: 'Chi',
                      value: _money(n.expense),
                      color: MomaColors.expense,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Num(
                      label: 'Chênh lệch',
                      value: _money(n.net),
                      color: (n.net ?? 0) < 0
                          ? MomaColors.expense
                          : MomaColors.income,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Num(
                      label: 'Chi so với kỳ trước',
                      value: n.changePct == null ? '—' : _pct(n.changePct!),
                      color: (n.changePct ?? 0) > 0
                          ? MomaColors.expense
                          : MomaColors.income,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Num(
                      label: 'Dự báo chi cả kỳ',
                      value: _money(n.forecastExpense),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Num(
                      label: 'Hạn mức đề xuất kỳ sau',
                      value: _money(n.suggestedLimit),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (insight.highlights.isNotEmpty) ...[
          const _SectionTitle('Điểm đáng chú ý'),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, h) in insight.highlights.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: MomaColors.emerald,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            h,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: pal.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (insight.suggestions.isNotEmpty) ...[
          const _SectionTitle('Đề xuất'),
          for (final s in insight.suggestions) _SuggestionCard(text: s),
        ],
        if (cats.isNotEmpty) ...[
          const _SectionTitle('Thay đổi theo danh mục'),
          _Card(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (final (i, c) in cats.indexed) ...[
                  if (i > 0) Divider(height: 1, color: pal.lineSoft),
                  _CategoryRow(change: c),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SuggestionCard extends StatefulWidget {
  const _SuggestionCard({required this.text});
  final String text;
  @override
  State<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<_SuggestionCard> {
  bool _done = false;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: pal.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _done = !_done),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _done
                      ? Symbols.check_circle_rounded
                      : Symbols.radio_button_unchecked_rounded,
                  fill: _done ? 1 : 0,
                  color: _done ? MomaColors.emerald : pal.muted,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: _done ? pal.muted : pal.ink,
                      decoration: _done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.change});
  final CategoryChange change;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final diff = change.amount - change.prevAmount;
    final up = diff > 0;
    final flat = diff == 0;
    final color = flat
        ? pal.muted
        : (up ? MomaColors.expense : MomaColors.income);
    final pct =
        change.changePct ??
        (change.prevAmount == 0 ? null : diff * 100 / change.prevAmount);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(
            flat
                ? Symbols.remove_rounded
                : (up
                      ? Symbols.arrow_upward_rounded
                      : Symbols.arrow_downward_rounded),
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  change.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
                Text(
                  'Kỳ trước ${formatVnd(change.prevAmount)}',
                  style: TextStyle(fontSize: 12.5, color: pal.muted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatVnd(change.amount),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: pal.ink,
                ),
              ),
              if (pct != null)
                Text(
                  _pct(pct),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.insight});
  final Insight insight;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return ListTile(
      onTap: () => context.push('/insights/${insight.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      title: Text(
        insight.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(_range(insight), style: const TextStyle(fontSize: 12.5)),
      trailing: Icon(Symbols.chevron_right_rounded, color: pal.muted),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: pal.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: pal.muted)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: color ?? pal.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 0, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: context.pal.ink,
      ),
    ),
  );
}
