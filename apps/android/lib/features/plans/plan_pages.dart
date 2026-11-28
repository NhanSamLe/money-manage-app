import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import 'plans_models.dart';
import 'plans_view.dart';

/// One event plan: estimate, then "Thực tế vs Dự toán" once money was spent (route /plans/event/:id).
class EventPlanPage extends ConsumerStatefulWidget {
  const EventPlanPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<EventPlanPage> createState() => _EventPlanPageState();
}

class _EventPlanPageState extends ConsumerState<EventPlanPage> {
  bool _busy = false;

  Future<void> _post(String action, String done) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .post('/plans/events/${widget.id}/$action', const {});
      ref.invalidate(eventPlanProvider(widget.id));
      refreshPlans(ref);
      if (mounted) showSnack(context, done);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Hủy kế hoạch?',
      message: 'Kế hoạch sẽ không còn nhắc trước và không so với thực tế nữa.',
      confirmLabel: 'Hủy kế hoạch',
      cancelLabel: 'Giữ lại',
      destructive: true,
    );
    if (ok) await _post('cancel', 'Đã hủy kế hoạch.');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(eventPlanProvider(widget.id));
    return Scaffold(
      body: MomaPage(
        title: 'Dự toán sự kiện',
        showBack: true,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(eventPlanProvider(widget.id)),
          ),
          data: (p) => _content(context, p),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, EventPlan p) {
    final pal = context.pal;
    final started = !p.startsAt.isAfter(DateTime.now());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: pal.tintSoft,
              child: Icon(eventKindIcon(p.kind), color: pal.accentInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: pal.ink,
                    ),
                  ),
                  Text(
                    [
                      eventWhen(p.startsAt),
                      '${p.headcount} người',
                      if (p.people.isNotEmpty) p.people.join(', '),
                      if ((p.place ?? '').isNotEmpty) p.place!,
                    ].join(' · '),
                    style: TextStyle(color: pal.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (p.cancelled) ...[
          const SizedBox(height: 10),
          Text(
            'Đã hủy',
            style: TextStyle(
              color: MomaColors.expense,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 14),
        if (p.actual != null) ...[
          PlanVsActualCard(
            estimate: p.estimate,
            actual: p.actual!,
            done: p.done,
          ),
          const SizedBox(height: 14),
        ],
        EstimateCard(estimate: p.estimate),
        const SizedBox(height: 18),
        if (!p.cancelled && started)
          FilledButton.icon(
            onPressed: _busy ? null : () => _post('close', 'Đã chốt thực tế.'),
            icon: const Icon(Symbols.fact_check_rounded),
            label: Text(p.done ? 'Cập nhật thực tế' : 'Chốt thực tế ngay'),
          ),
        if (p.state == 'PLANNED') ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('Hủy kế hoạch'),
          ),
          const SizedBox(height: 8),
          Text(
            started
                ? 'Sáng hôm sau mình tự chốt thực tế (gồm cả Grab về khuya và phần đã chia).'
                : 'Mình nhắc bạn trước một ngày kèm số dự kiến, và tự so với thực tế sau sự kiện.',
            style: TextStyle(color: pal.hint, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// Two bars (Dự toán / Thực tế) + where the money went.
class PlanVsActualCard extends StatelessWidget {
  const PlanVsActualCard({
    super.key,
    required this.estimate,
    required this.actual,
    required this.done,
  });
  final EventEstimate estimate;
  final EventActual actual;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final planned = estimate.owner.likely;
    final real = actual.owner;
    final top = math.max(1, math.max(planned, real));
    final over = real > planned;
    Widget bar(String label, int v, Color c) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: pal.muted, fontSize: 13),
                ),
              ),
              Text(
                formatVnd(v),
                style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: v / top,
              minHeight: 10,
              backgroundColor: pal.tintSoft,
              color: c,
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            done ? 'Thực tế vs Dự toán' : 'Đã chi tới giờ',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: pal.ink,
            ),
          ),
          if (actual.summary != null) ...[
            const SizedBox(height: 4),
            Text(
              actual.summary!,
              style: TextStyle(
                color: over ? MomaColors.expense : pal.accentInk,
                fontSize: 13.5,
              ),
            ),
          ],
          const SizedBox(height: 12),
          bar('Dự toán (phần của bạn)', planned, pal.muted),
          bar(
            'Thực tế (phần của bạn)',
            real,
            over ? MomaColors.expense : MomaColors.income,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final (l, v) in [
                ('Ăn uống', actual.food),
                ('Grab/đi lại', actual.rides),
                ('Khác', actual.other),
              ])
                if (v > 0)
                  Text(
                    '$l ${shortVnd(v)}',
                    style: TextStyle(color: pal.muted, fontSize: 12.5),
                  ),
              Text(
                '${actual.count} giao dịch',
                style: TextStyle(color: pal.hint, fontSize: 12.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A big plan with its projection chart and what-if sliders (route /plans/life/:id). Sliders recompute locally.
class LifePlanPage extends ConsumerStatefulWidget {
  const LifePlanPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<LifePlanPage> createState() => _LifePlanPageState();
}

class _LifePlanPageState extends ConsumerState<LifePlanPage> {
  LifeParams? _p;
  bool _busy = false;

  Future<void> _save(LifeParams p) async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).post('/plans/life', {
        'id': widget.id,
        ...p.toJson(),
      });
      refreshPlans(ref);
      if (mounted) showSnack(context, 'Đã lưu kịch bản.');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Xóa kế hoạch?',
      message: 'Mục tiêu tiết kiệm liên quan (nếu có) vẫn được giữ.',
      confirmLabel: 'Xóa',
      cancelLabel: 'Giữ lại',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(apiProvider).delete('/plans/life/${widget.id}');
      refreshPlans(ref);
      if (mounted) Navigator.maybePop(context);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(lifePlansProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Kế hoạch lớn',
        showBack: true,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(lifePlansProvider),
          ),
          data: (d) {
            final plan = d.plans.where((x) => x.id == widget.id).firstOrNull;
            if (plan == null) {
              return const EmptyState(
                icon: Symbols.flag_rounded,
                title: 'Không tìm thấy kế hoạch',
                hint: 'Kế hoạch có thể đã bị xóa.',
              );
            }
            return _content(context, plan, d.baseline);
          },
        ),
      ),
    );
  }

  Widget _content(BuildContext context, LifePlan plan, PlanBaseline b) {
    final pal = context.pal;
    final p = _p ??= plan.params;
    final pr = projectLocal(p, b);
    final loanKind = p.kind == 'HOUSE' || p.kind == 'CAR';
    final years = pr.months == null ? null : pr.months! ~/ 12;
    final months = pr.months == null ? null : pr.months! % 12;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: pal.tintSoft,
              child: Icon(lifeKindIcon(p.kind), color: pal.accentInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: pal.ink,
                    ),
                  ),
                  Text(
                    'Giá hiện tại ${shortVnd(p.price)}',
                    style: TextStyle(color: pal.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dự kiến đạt',
                style: TextStyle(color: pal.muted, fontSize: 13),
              ),
              Text(
                pr.reachable
                    ? '~${monthLabel(pr.reachMonth)}'
                    : 'Chưa đạt được',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: pr.reachable ? pal.ink : MomaColors.expense,
                ),
              ),
              if (pr.reachable && pr.months! > 0)
                Text(
                  'còn ${years! > 0 ? '$years năm ' : ''}${months! > 0 ? '$months tháng' : ''}'
                      .trim(),
                  style: TextStyle(color: pal.muted, fontSize: 13),
                ),
              const SizedBox(height: 12),
              _Line(
                'Tích lũy mỗi tháng',
                '~${shortVnd(math.max(0, pr.monthlySaving))}',
              ),
              _Line('Đang có cho kế hoạch', shortVnd(pr.savedNow)),
              _Line(
                p.downPct < 100
                    ? 'Cần trả trước (${p.downPct.round()}%)'
                    : 'Cần có',
                shortVnd(pr.neededThen),
              ),
              if (pr.loanAmount > 0)
                _Line(
                  'Vay ~${shortVnd(pr.loanAmount)}',
                  'trả ~${shortVnd(pr.monthlyPayment)}/tháng',
                ),
              const SizedBox(height: 12),
              SizedBox(
                height: 160,
                child: ProjectionChart(points: pr.timeline),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _Legend(color: MomaColors.emerald, label: 'Tích lũy'),
                  const SizedBox(width: 14),
                  _Legend(color: MomaColors.expense, label: 'Cần có'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Thử thay đổi',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: pal.ink,
          ),
        ),
        _Slider(
          label: 'Tiết kiệm thêm mỗi tháng',
          value: p.extraSaving.toDouble(),
          min: 0,
          max: 10e6,
          divisions: 20,
          display: (v) => '+${shortVnd(v)}',
          onChanged: (v) =>
              setState(() => _p = p.copyWith(extraSaving: v.round())),
        ),
        _Slider(
          label: 'Thu nhập tăng mỗi năm',
          value: p.incomeGrowthPct ?? kCpiPct,
          min: 0,
          max: 15,
          divisions: 30,
          display: (v) => '${v.toStringAsFixed(1)}%',
          onChanged: (v) => setState(() => _p = p.copyWith(incomeGrowthPct: v)),
        ),
        if (loanKind)
          _Slider(
            label: 'Trả trước',
            value: p.downPct,
            min: 10,
            max: 100,
            divisions: 18,
            display: (v) => '${v.round()}%',
            onChanged: (v) => setState(() => _p = p.copyWith(downPct: v)),
          ),
        _Slider(
          label: 'Giá tăng mỗi năm',
          value: p.inflationPct ?? defaultInflation(p.kind),
          min: 0,
          max: 12,
          divisions: 24,
          display: (v) => '${v.toStringAsFixed(1)}%',
          onChanged: (v) => setState(() => _p = p.copyWith(inflationPct: v)),
        ),
        if (plan.projection?.assumptions.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(
            plan.projection!.assumptions.join(' '),
            style: TextStyle(color: pal.hint, fontSize: 12, height: 1.4),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : () => _save(p),
          child: const Text('Lưu kịch bản này'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _delete,
          child: const Text('Xóa kế hoạch'),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: context.pal.muted, fontSize: 13.5),
          ),
        ),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w700, color: context.pal.ink),
        ),
      ],
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 12, color: context.pal.muted)),
    ],
  );
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: context.pal.ink, fontSize: 13.5),
              ),
            ),
            Text(
              display(value.clamp(min, max)),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: context.pal.accentInk,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display(value.clamp(min, max)),
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

/// Saved (green) vs needed (red) over the years until the target.
class ProjectionChart extends StatelessWidget {
  const ProjectionChart({super.key, required this.points});
  final List<YearPoint> points;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    if (points.length < 2) {
      return Center(
        child: Text('Đủ ngay bây giờ', style: TextStyle(color: pal.muted)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            size: Size.infinite,
            painter: _ChartPainter(
              points,
              saved: MomaColors.emerald,
              needed: MomaColors.expense,
              grid: pal.lineSoft,
            ),
          ),
        ),
        Row(
          children: [
            Text(
              points.first.month.substring(0, 4),
              style: TextStyle(fontSize: 11, color: pal.hint),
            ),
            const Spacer(),
            Text(
              points.last.month.substring(0, 4),
              style: TextStyle(fontSize: 11, color: pal.hint),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(
    this.points, {
    required this.saved,
    required this.needed,
    required this.grid,
  });
  final List<YearPoint> points;
  final Color saved;
  final Color needed;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final top = points
        .fold<int>(1, (m, p) => math.max(m, math.max(p.saved, p.needed)))
        .toDouble();
    final g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    Path line(int Function(YearPoint) v) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final x = size.width * i / (points.length - 1);
        final y = size.height - size.height * v(points[i]) / top;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    Paint stroke(Color c) => Paint()
      ..color = c
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(line((p) => p.needed), stroke(needed));
    canvas.drawPath(line((p) => p.saved), stroke(saved));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.points != points;
}
