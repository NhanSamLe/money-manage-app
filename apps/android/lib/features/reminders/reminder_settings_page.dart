import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/header.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import '../insights/insights_data.dart' show isNotDeployed;
import 'reminders_data.dart';

const _weekdays = {
  1: 'Thứ Hai',
  2: 'Thứ Ba',
  3: 'Thứ Tư',
  4: 'Thứ Năm',
  5: 'Thứ Sáu',
  6: 'Thứ Bảy',
  7: 'Chủ nhật',
};

int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;

/// "Nhắc nhở & thông báo": meal reminders, end-of-day cash check, daily/weekly/monthly reviews, budget alerts.
class ReminderSettingsPage extends ConsumerWidget {
  const ReminderSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reminderSettingsProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Nhắc nhở & thông báo',
        showBack: true,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => isNotDeployed(e)
              ? const EmptyState(
                  icon: Symbols.notifications_rounded,
                  title: 'Tính năng sắp có',
                  hint: 'Cài đặt nhắc nhở đang được chuẩn bị trên máy chủ. Bạn quay lại sau nhé.',
                )
              : ErrorView(
                  error: e,
                  onRetry: () => ref.invalidate(reminderSettingsProvider),
                ),
          data: (s) => _Form(initial: s),
        ),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.initial});
  final ReminderSettings initial;
  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  late final ReminderSettings _s = widget.initial;
  bool _busy = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Map<String, String> _errors = {};

  /// Enabled meals must be in order: breakfast before lunch before dinner.
  Map<String, String> _validate() {
    final e = <String, String>{};
    final b = _s.meals['breakfast']!;
    final l = _s.meals['lunch']!;
    final d = _s.meals['dinner']!;
    if (b.enabled && l.enabled && _minutes(l.time) <= _minutes(b.time)) {
      e['lunch'] = 'Giờ bữa trưa phải sau bữa sáng';
    }
    if (l.enabled && d.enabled && _minutes(d.time) <= _minutes(l.time)) {
      e['dinner'] = 'Giờ bữa tối phải sau bữa trưa';
    } else if (b.enabled &&
        d.enabled &&
        !l.enabled &&
        _minutes(d.time) <= _minutes(b.time)) {
      e['dinner'] = 'Giờ bữa tối phải sau bữa sáng';
    }
    return e;
  }

  void _changed(VoidCallback fn) => setState(() {
    fn();
    if (_errors.isNotEmpty) _errors = _validate();
  });

  Future<void> _save() async {
    final errors = _validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      // Meal fields are at the top: bring the first error into view.
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).put('/reminders/settings', _s.toJson());
      if (!mounted) return;
      showSnack(context, 'Đã lưu cài đặt nhắc nhở');
      if (context.canPop()) context.pop();
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(
        context,
        e is ApiException
            ? e.message
            : 'Không lưu được cài đặt. Bạn thử lại sau nhé.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _slot(
    String label,
    TimedReminder r, {
    String? errorKey,
    String? help,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LabeledSwitch(
        label: label,
        help: help,
        value: r.enabled,
        onChanged: (v) => _changed(() => r.enabled = v),
      ),
      const SizedBox(height: 6),
      TimeField(
        label: 'Giờ nhắc',
        value: r.time,
        enabled: r.enabled,
        errorText: errorKey == null ? null : _errors[errorKey],
        onChanged: (t) => _changed(() => r.time = t),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _Section('Bữa ăn'),
        _Card(
          children: [
            for (final k in mealKinds)
              _slot(mealLabels[k]!, _s.meals[k]!, errorKey: k),
          ],
        ),
        const _Section('Cuối ngày'),
        _Card(
          children: [
            _slot(
              'Kiểm tra tiền mặt',
              _s.cashCheck,
              help: 'Nhắc bạn đếm lại tiền mặt trong ví để số dư trên MoMa khớp với thực tế.',
            ),
          ],
        ),
        const _Section('Tổng kết'),
        _Card(
          children: [
            _slot('Tổng kết ngày', _s.dailyReview),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabeledSwitch(
                  label: 'Tổng kết tuần',
                  value: _s.weeklyReview.enabled,
                  onChanged: (v) => _changed(() => _s.weeklyReview.enabled = v),
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: PickField<int>(
                        decoration: const InputDecoration(labelText: 'Thứ'),
                        initialValue: _s.weeklyWeekday,
                        items: [
                          for (final e in _weekdays.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: _s.weeklyReview.enabled
                            ? (v) => _changed(
                                () => _s.weeklyWeekday = v ?? _s.weeklyWeekday,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TimeField(
                        label: 'Giờ nhắc',
                        value: _s.weeklyReview.time,
                        enabled: _s.weeklyReview.enabled,
                        onChanged: (t) =>
                            _changed(() => _s.weeklyReview.time = t),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _slot(
              'Tổng kết tháng',
              _s.monthlyReview,
              help: 'Gửi vào ngày cuối cùng của mỗi tháng.',
            ),
          ],
        ),
        const _Section('Cảnh báo ngân sách'),
        _Card(
          children: [
            LabeledSwitch(
              label: 'Báo khi sắp vượt ngân sách',
              help: 'Thông báo khi chi tiêu của một danh mục gần chạm hoặc vượt hạn mức bạn đặt trong Ngân sách.',
              value: _s.budgetAlerts,
              onChanged: (v) => _changed(() => _s.budgetAlerts = v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ActionButtons(
          primaryLabel: 'Lưu cài đặt',
          onPrimary: _save,
          busy: _busy,
        ),
      ],
    );
  }
}

/// Time field in the same style as [DateField]: label above, rounded box, clock picker on tap.
class TimeField extends StatelessWidget {
  const TimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.errorText,
  });
  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(label),
        const SizedBox(height: 6),
        Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Material(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: !enabled
                  ? null
                  : () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: value,
                        builder: (ctx, child) => MediaQuery(
                          data: MediaQuery.of(ctx)
                              .copyWith(alwaysUse24HourFormat: true),
                          child: child ?? const SizedBox.shrink(),
                        ),
                      );
                      if (t != null) onChanged(t);
                    },
              child: Container(
                constraints: const BoxConstraints(minHeight: 54),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: hasError ? MomaColors.expense : pal.line,
                    width: hasError ? 1.4 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Symbols.schedule_rounded, color: pal.muted, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        formatHm(value),
                        style: TextStyle(fontSize: 15, color: pal.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 0, 0),
            child: Text(
              errorText!,
              style: const TextStyle(color: MomaColors.expense, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 0, 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: context.pal.muted,
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: context.pal.lineSoft),
            const SizedBox(height: 4),
          ],
          c,
        ],
      ],
    ),
  );
}
