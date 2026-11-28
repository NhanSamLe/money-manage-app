import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'split_api.dart';
import 'split_models.dart';
import 'split_sheet.dart' show roundingLabel;

/// First date to expect: day [start] of this month while the window is still open, else of next month.
DateTime nextWindowStart(int start, int end, [DateTime? now]) {
  final n = now ?? DateTime.now();
  DateTime at(int y, int m) {
    final last = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, start > last ? last : start);
  }

  return n.day <= end ? at(n.year, n.month) : at(n.year, n.month + 1);
}

/// "Tiền nhà 1.600.000đ, ngày 5–10, chia 3 với Nam và Lan": MoMa recognises the payment by itself (amount, days,
/// account, words in the bank content), sets the category and records who owes what. RECURRING_SPLIT_UPSERT.
class RecurringSplitSheet extends ConsumerStatefulWidget {
  const RecurringSplitSheet({super.key, this.rule, this.suggestion});
  final RecurringRule? rule;
  final RuleSuggestion? suggestion;

  @override
  ConsumerState<RecurringSplitSheet> createState() =>
      _RecurringSplitSheetState();
}

class _RecurringSplitSheetState extends ConsumerState<RecurringSplitSheet> {
  late final FormRunner _run = FormRunner(setState);
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _keywords = TextEditingController();
  String? _accountId;
  String? _categoryId;
  int _start = 5;
  int _end = 10;
  int _rounding = 5000;
  bool _ownerShare = true;
  bool _auto = true;
  final List<String> _people = [];
  final String _cmd = ApiClient.newId();

  @override
  void initState() {
    super.initState();
    final r = widget.rule;
    final s = widget.suggestion;
    if (r != null) {
      _name.text = r.item.name;
      _amount.text = _plain(r.item.amount);
      _accountId = r.item.accountId;
      _categoryId = r.categoryId;
      final sp = r.split;
      if (sp != null) {
        _start = sp.windowStart;
        _end = sp.windowEnd;
        _rounding = sp.rounding;
        _ownerShare = sp.ownerShare;
        _auto = sp.autoApply;
        _keywords.text = sp.keywords.join(', ');
        _people.addAll(sp.participants.map((p) => p.contactId));
      }
    } else if (s != null) {
      _amount.text = _plain(s.amount);
      _accountId = s.accountId;
      _categoryId = s.categoryId;
      _start = s.dayMin;
      _end = s.dayMax < s.dayMin + 2 ? (s.dayMin + 2).clamp(1, 31) : s.dayMax;
      if ((s.label ?? '').isNotEmpty) _keywords.text = s.label!;
    }
  }

  static String _plain(int v) =>
      formatVnd(v).replaceAll(' ₫', '').replaceAll('₫', '').trim();

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _keywords.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = parseVndInput(_amount.text);
    if (_name.text.trim().isEmpty ||
        amount == null ||
        amount <= 0 ||
        _accountId == null ||
        _categoryId == null) {
      setState(() => _run.error = 'Điền tên, số tiền, tài khoản và danh mục.');
      return;
    }
    if (_end < _start) {
      setState(() => _run.error = 'Ngày kết thúc phải sau ngày bắt đầu.');
      return;
    }
    final r = widget.rule;
    final next = r?.nextDate ?? nextWindowStart(_start, _end);
    final kw = _keywords.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(10)
        .toList();
    final ok = await _run.run(
      () => ref.read(apiProvider).command('RECURRING_SPLIT_UPSERT', {
        'name': _name.text.trim(),
        'account_id': _accountId,
        'amount': '$amount',
        'category_id': _categoryId,
        'next_date': isoDate(next),
        'enabled': true,
        'interval': 'MONTHLY',
        'recurring_id': ?r?.item.id,
        'expected_version': ?r?.version,
        'window_start': _start,
        'window_end': _end,
        'rounding': _rounding,
        'owner_share': _ownerShare,
        'auto_apply': _auto,
        'payee_keywords': kw,
        'participants': [
          for (final id in _people) {'contact_id': id, 'mode': 'EQUAL'},
        ],
      }, commandId: _cmd),
    );
    if (ok && mounted) {
      ref.invalidate(recurringRulesProvider);
      ref.invalidate(ruleSuggestionsProvider);
      refreshPlanning(ref);
      Navigator.pop(context);
      showSnack(context, 'Đã lưu quy tắc. MoMa sẽ tự nhận khoản này.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final cats = (ref.watch(categoriesProvider).value ?? const <Category>[])
        .where((c) => c.type == 'EXPENSE')
        .toList();
    final contacts = ref.watch(contactsProvider).value ?? const <Contact>[];
    final amount = parseVndInput(_amount.text) ?? 0;
    final chosen = [
      for (final id in _people) ...contacts.where((c) => c.id == id),
    ];
    final preview = amount > 0 && chosen.isNotEmpty
        ? computeShares(
            amount,
            [for (final _ in chosen) (mode: 'EQUAL', value: null)],
            ownerShare: _ownerShare,
            rounding: _rounding,
          )
        : null;
    final days = [for (var d = 1; d <= 31; d++) d];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.rule == null ? 'Quy tắc tự động' : 'Sửa quy tắc',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'Khi tiền ra khớp số tiền và khoảng ngày, MoMa tự ghi đúng danh mục và tự ghi nợ cho người cùng trả. Chưa chắc thì hỏi bạn một chạm.',
          style: TextStyle(color: pal.muted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: 'Tên',
          hint: 'Vd: Tiền nhà, Tiền điện',
          controller: _name,
        ),
        const SizedBox(height: 12),
        MoneyField(controller: _amount, onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        PickField<String>(
          isExpanded: true,
          initialValue: _accountId,
          decoration: const InputDecoration(
            labelText: 'Thường trả từ tài khoản',
          ),
          items: [
            for (final a in accounts)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
        const SizedBox(height: 12),
        PickField<String>(
          isExpanded: true,
          initialValue: _categoryId,
          decoration: const InputDecoration(labelText: 'Danh mục'),
          items: [
            for (final c in cats)
              DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => setState(() => _categoryId = v),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: PickField<int>(
                isExpanded: true,
                initialValue: _start,
                decoration: const InputDecoration(labelText: 'Từ ngày'),
                items: [
                  for (final d in days)
                    DropdownMenuItem(value: d, child: Text('$d')),
                ],
                onChanged: (v) => setState(() => _start = v ?? _start),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PickField<int>(
                isExpanded: true,
                initialValue: _end,
                decoration: const InputDecoration(labelText: 'Đến ngày'),
                items: [
                  for (final d in days)
                    DropdownMenuItem(value: d, child: Text('$d')),
                ],
                onChanged: (v) => setState(() => _end = v ?? _end),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Chia với', style: TextStyle(color: pal.muted, fontSize: 13)),
        const SizedBox(height: 6),
        if (contacts.isEmpty)
          Text(
            'Chưa có người quen. Thêm ở mục Công nợ.',
            style: TextStyle(color: pal.muted, fontSize: 13),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final c in contacts)
                FilterChip(
                  label: Text(c.alias),
                  selected: _people.contains(c.id),
                  onSelected: (on) => setState(
                    () => on ? _people.add(c.id) : _people.remove(c.id),
                  ),
                ),
            ],
          ),
        if (chosen.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Làm tròn lên',
            style: TextStyle(color: pal.muted, fontSize: 13),
          ),
          const SizedBox(height: 6),
          PillTabs<int>(
            segments: [
              for (final r in kRoundings)
                ButtonSegment(
                  value: r,
                  label: Text(r == 0 ? 'Không' : roundingLabel(r)),
                ),
            ],
            selected: {_rounding},
            onSelectionChanged: (s) => setState(() => _rounding = s.first),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tính cả phần của bạn',
                  style: TextStyle(color: pal.ink),
                ),
              ),
              MomaSwitch(
                value: _ownerShare,
                onChanged: (v) => setState(() => _ownerShare = v),
              ),
            ],
          ),
          if (preview != null)
            Text(
              splitPreviewLine(
                [for (final c in chosen) c.alias],
                preview.shares,
                preview.owner,
              ),
              key: const Key('rule-preview'),
              style: TextStyle(
                color: pal.accentInk,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
        const SizedBox(height: 12),
        LabeledField(
          label: 'Chữ thường có trong nội dung chuyển khoản (không bắt buộc)',
          hint: 'Vd: CO HOA, TIEN NHA',
          controller: _keywords,
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                'Tự ghi khi chắc chắn (không cần hỏi)',
                style: TextStyle(color: pal.ink),
              ),
            ),
            MomaSwitch(
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
          ],
        ),
        FormError(_run.error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu quy tắc'),
        ),
      ],
    );
  }
}
