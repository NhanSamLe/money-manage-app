import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/widgets.dart';
import 'plans_models.dart';

IconData eventKindIcon(String kind) => switch (kind) {
  'NHAU' => Symbols.sports_bar_rounded,
  'AN_UONG' => Symbols.restaurant_rounded,
  'CAFE' => Symbols.local_cafe_rounded,
  'TIEC' => Symbols.celebration_rounded,
  'SINH_NHAT' => Symbols.cake_rounded,
  'DU_LICH' => Symbols.flight_takeoff_rounded,
  _ => Symbols.event_rounded,
};

IconData lifeKindIcon(String kind) => switch (kind) {
  'HOUSE' => Symbols.home_rounded,
  'CAR' => Symbols.directions_car_rounded,
  'TRAVEL' => Symbols.travel_explore_rounded,
  'WEDDING' => Symbols.favorite_rounded,
  'EDUCATION' => Symbols.school_rounded,
  _ => Symbols.flag_rounded,
};

String _two(int v) => v.toString().padLeft(2, '0');
const _weekday = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

/// "T7 05/12 · 19:00".
String eventWhen(DateTime d) =>
    '${_weekday[d.weekday - 1]} ${_two(d.day)}/${_two(d.month)} · ${_two(d.hour)}:${_two(d.minute)}';

/// Tab "Dự toán" in Kế hoạch: upcoming / past event plans with plan vs actual, and the big life plans.
class PlansView extends ConsumerWidget {
  const PlansView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final events = ref.watch(eventPlansProvider);
    final life = ref.watch(lifePlansProvider);
    return RefreshIndicator(
      onRefresh: () async {
        refreshPlans(ref);
        await Future.wait([
          ref.read(eventPlansProvider.future),
          ref.read(lifePlansProvider.future),
        ]);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: pal.tint,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Icon(Symbols.auto_awesome_rounded, color: pal.accentInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Nói với Trợ lý kiểu "tối thứ 7 đi nhậu với Nam, Lan" hoặc "bao giờ mua được nhà 2,5 tỷ" — '
                    'mình dự toán từ thói quen của bạn và so với thực tế sau đó.',
                    style: TextStyle(
                      color: pal.ink,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => showFormSheet<void>(
                    context,
                    (_) => const EventPlanSheet(),
                  ),
                  icon: const Icon(Symbols.calculate_rounded),
                  label: const Text('Dự toán sự kiện'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showFormSheet<void>(
                    context,
                    (_) => const LifePlanSheet(),
                  ),
                  icon: const Icon(Symbols.flag_rounded),
                  label: const Text('Kế hoạch lớn'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          events.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(eventPlansProvider),
            ),
            data: (list) {
              final up = list.where((p) => p.upcoming).toList()
                ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
              final past = list
                  .where((p) => !p.upcoming && !p.cancelled)
                  .take(10)
                  .toList();
              if (up.isEmpty && past.isEmpty) {
                return const EmptyState(
                  embedded: true,
                  icon: Symbols.event_note_rounded,
                  title: 'Chưa có sự kiện nào',
                  hint: 'Sắp đi chơi, đi nhậu hay tổ chức tiệc? Dự toán trước để biết cần chuẩn bị bao nhiêu.',
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (up.isNotEmpty) ...[
                    _SectionTitle('Sắp tới'),
                    for (final p in up) EventPlanCard(plan: p),
                  ],
                  if (past.isNotEmpty) ...[
                    _SectionTitle('Dự toán & thực tế'),
                    for (final p in past) EventPlanCard(plan: p),
                  ],
                ],
              );
            },
          ),
          life.when(
            loading: () => const SizedBox.shrink(),
            error: (e, _) => const SizedBox.shrink(),
            data: (d) => d.plans.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionTitle(
                        'Kế hoạch lớn · tích lũy ~${shortVnd(d.baseline.saving < 0 ? 0 : d.baseline.saving)}/tháng',
                      ),
                      for (final p in d.plans) LifePlanCard(plan: p),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 15,
        color: context.pal.ink,
      ),
    ),
  );
}

class EventPlanCard extends StatelessWidget {
  const EventPlanCard({super.key, required this.plan});
  final EventPlan plan;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final a = plan.actual;
    final over = a != null && a.owner > plan.estimate.owner.likely;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/plans/event/${plan.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: pal.tintSoft,
                child: Icon(eventKindIcon(plan.kind), color: pal.accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: pal.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${eventWhen(plan.startsAt)} · ${plan.headcount} người',
                      style: TextStyle(fontSize: 12.5, color: pal.muted),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '~${shortVnd(plan.estimate.owner.likely)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: pal.ink,
                    ),
                  ),
                  if (a != null)
                    Text(
                      'Thực tế ${shortVnd(a.owner)}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: over ? MomaColors.expense : MomaColors.income,
                      ),
                    )
                  else
                    Text(
                      'dự toán',
                      style: TextStyle(fontSize: 12, color: pal.hint),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LifePlanCard extends StatelessWidget {
  const LifePlanCard({super.key, required this.plan});
  final LifePlan plan;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final pr = plan.projection;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/plans/life/${plan.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: pal.tintSoft,
                child: Icon(
                  lifeKindIcon(plan.params.kind),
                  color: pal.accentInk,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.params.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: pal.ink,
                      ),
                    ),
                    Text(
                      '${shortVnd(plan.params.price)}${plan.params.downPct < 100 ? ' · trả trước ${plan.params.downPct.round()}%' : ''}',
                      style: TextStyle(fontSize: 12.5, color: pal.muted),
                    ),
                  ],
                ),
              ),
              Text(
                pr == null
                    ? ''
                    : (pr.reachable
                          ? '~${monthLabel(pr.reachMonth)}'
                          : 'Chưa đủ'),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: pr?.reachable == false
                      ? MomaColors.expense
                      : pal.accentInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Estimate card: the owner's expected share, range, breakdown with bars, assumptions.
class EstimateCard extends StatelessWidget {
  const EstimateCard({super.key, required this.estimate});
  final EventEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final e = estimate;
    final max = e.items.fold<int>(1, (m, i) => i.amount > m ? i.amount : m);
    final split =
        !e.ownerPays && e.headcount > 1 && e.owner.likely != e.total.likely;
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
            split ? 'Phần của bạn (dự kiến)' : 'Dự kiến',
            style: TextStyle(color: pal.muted, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            '~${formatVnd(e.owner.likely)}',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: pal.ink,
              letterSpacing: -0.5,
            ),
          ),
          Text(
            'khoảng ${shortVnd(e.owner.low)} – ${shortVnd(e.owner.high)}'
            '${split ? ' · cả nhóm ~${shortVnd(e.total.likely)} chia ${e.headcount}' : ''}',
            style: TextStyle(color: pal.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          for (final i in e.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          i.label,
                          style: TextStyle(color: pal.ink, fontSize: 13.5),
                        ),
                      ),
                      Text(
                        shortVnd(i.amount),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: pal.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: i.amount / max,
                      minHeight: 6,
                      backgroundColor: pal.tintSoft,
                      color: i.key == 'rides'
                          ? const Color(0xFF2F80ED)
                          : MomaColors.emerald,
                    ),
                  ),
                ],
              ),
            ),
          if (e.assumptions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              e.assumptions.join(' '),
              style: TextStyle(color: pal.hint, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

/// Quick form: one line of text + date + time + people; the estimate updates as you type (needs the network).
class EventPlanSheet extends ConsumerStatefulWidget {
  const EventPlanSheet({super.key});
  @override
  ConsumerState<EventPlanSheet> createState() => _EventPlanSheetState();
}

class _EventPlanSheetState extends ConsumerState<EventPlanSheet> {
  final _title = TextEditingController();
  final String _id = ApiClient.newId();
  DateTime _date = DateTime.now();
  String _time = '19:00';
  int _people = 2;
  bool _ownerPays = false;
  String _transport = 'GRAB';
  EventEstimate? _estimate;
  String? _error;
  bool _loading = false;
  bool _saving = false;
  Timer? _debounce;
  int _seq = 0;

  static const _times = {
    '12:00': 'Trưa',
    '15:00': 'Chiều',
    '19:00': 'Tối',
    '21:00': 'Khuya',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    super.dispose();
  }

  Map<String, dynamic> _body() => {
    'title': _title.text.trim(),
    'date': '${_date.year}-${_two(_date.month)}-${_two(_date.day)}',
    'time': _time,
    'headcount': _people,
    'owner_pays': _ownerPays,
    'transport': _transport,
  };

  void _changed() {
    _debounce?.cancel();
    if (_title.text.trim().isEmpty) {
      setState(() => _estimate = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), _estimateNow);
  }

  Future<void> _estimateNow() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(apiProvider)
          .post('/plans/events/estimate', _body());
      if (!mounted || seq != _seq) return;
      setState(
        () => _estimate = EventEstimate.fromJson(
          (r as Map).cast<String, dynamic>(),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(
        () => _error = e.code == 'OFFLINE'
            ? 'Cần mạng để dự toán từ thói quen của bạn.'
            : e.message,
      );
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Nhập tên sự kiện, vd "Nhậu với nhóm Nam".');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiProvider).post('/plans/events', {
        ..._body(),
        'id': _id,
      });
      if (!mounted) return;
      refreshPlans(ref);
      Navigator.pop(context);
      showSnack(
        context,
        'Đã lưu kế hoạch. Sau sự kiện mình sẽ so với thực tế.',
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dự toán sự kiện',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: 'Sự kiện',
          hint: 'vd Nhậu với nhóm Nam, Tiệc tốt nghiệp',
          controller: _title,
          onChanged: (_) => _changed(),
        ),
        const SizedBox(height: 12),
        DateField(
          label: 'Ngày',
          value: _date,
          firstDate: DateTime.now().subtract(const Duration(days: 2)),
          lastDate: DateTime.now().add(const Duration(days: 730)),
          onChanged: (d) {
            if (d == null) return;
            setState(() => _date = d);
            _changed();
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            for (final t in _times.entries)
              ChoiceChip(
                label: Text('${t.value} ${t.key}'),
                selected: _time == t.key,
                onSelected: (_) {
                  setState(() => _time = t.key);
                  _changed();
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                'Số người (kể cả bạn)',
                style: TextStyle(color: pal.ink),
              ),
            ),
            IconButton(
              tooltip: 'Bớt',
              onPressed: _people > 1
                  ? () {
                      setState(() => _people--);
                      _changed();
                    }
                  : null,
              icon: const Icon(Symbols.remove_circle_rounded),
            ),
            Text(
              '$_people',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: pal.ink,
              ),
            ),
            IconButton(
              tooltip: 'Thêm',
              onPressed: _people < 500
                  ? () {
                      setState(() => _people++);
                      _changed();
                    }
                  : null,
              icon: const Icon(Symbols.add_circle_rounded),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                'Bạn bao / tổ chức (không chia)',
                style: TextStyle(color: pal.ink),
              ),
            ),
            MomaSwitch(
              value: _ownerPays,
              onChanged: (v) {
                setState(() => _ownerPays = v);
                _changed();
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final t in const {
              'GRAB': 'Đi Grab',
              'OWN': 'Tự đi xe',
              'NONE': 'Không đi lại',
            }.entries)
              ChoiceChip(
                label: Text(t.value),
                selected: _transport == t.key,
                onSelected: (_) {
                  setState(() => _transport = t.key);
                  _changed();
                },
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (_loading && _estimate == null) const LinearProgressIndicator(),
        if (_estimate != null) EstimateCard(estimate: _estimate!),
        FormError(_error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Đang lưu…' : 'Lưu kế hoạch'),
        ),
      ],
    );
  }
}

/// New big plan: name + price is enough (kind, down payment and loan defaults are inferred).
class LifePlanSheet extends ConsumerStatefulWidget {
  const LifePlanSheet({super.key});
  @override
  ConsumerState<LifePlanSheet> createState() => _LifePlanSheetState();
}

class _LifePlanSheetState extends ConsumerState<LifePlanSheet> {
  final _name = TextEditingController();
  final _price = TextEditingController();
  final String _id = ApiClient.newId();
  String? _kind;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final price = parseVndInput(_price.text);
    if (_name.text.trim().isEmpty || price == null || price <= 0) {
      setState(() => _error = 'Nhập tên và giá dự kiến.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).post('/plans/life', {
        'id': _id,
        'name': _name.text.trim(),
        'price': price,
        'kind': ?_kind,
      });
      if (!mounted) return;
      refreshPlans(ref);
      Navigator.pop(context);
      context.push('/plans/life/$_id');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Kế hoạch lớn',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: 'Bạn muốn',
          hint: 'vd Mua căn hộ, Mua xe, Du lịch Nhật',
          controller: _name,
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _price, hint: 'Giá hiện tại'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final k in lifeKindLabels.entries)
              ChoiceChip(
                avatar: Icon(lifeKindIcon(k.key), size: 18),
                label: Text(k.value),
                selected: _kind == k.key,
                onSelected: (s) => setState(() => _kind = s ? k.key : null),
              ),
          ],
        ),
        FormError(_error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Đang tính…' : 'Xem bao giờ đạt được'),
        ),
      ],
    );
  }
}
