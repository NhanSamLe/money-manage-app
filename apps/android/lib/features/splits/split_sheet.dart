import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/planning_models.dart';
import '../../core/planning_providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'split_api.dart';
import 'split_models.dart';

class _Person {
  _Person({this.contactId, required this.name, int? amount})
    : amount = TextEditingController(
        text: amount == null
            ? ''
            : formatVnd(amount).replaceAll(' ₫', '').replaceAll('₫', '').trim(),
      );
  final String? contactId;
  final String name;
  final TextEditingController amount;
}

String roundingLabel(int r) => switch (r) {
  0 => 'Không làm tròn',
  1000 => '1.000',
  5000 => '5.000',
  _ => '10.000',
};

/// Pick people (contacts, or a new name), equal shares with rounding (live preview) or own amounts, then confirm.
/// Used for manual splits and to edit / complete a proposal. One apply call creates every debt.
class SplitSheet extends ConsumerStatefulWidget {
  const SplitSheet({
    super.key,
    required this.txId,
    required this.total,
    this.applicationId,
    this.categoryId,
    this.initial = const [],
    this.preselect = const [],
  });
  final String txId;
  final int total;
  final String? applicationId;
  final String? categoryId;
  final List<SplitShare> initial;

  /// Contact ids selected when the sheet opens ("Nhóm hay đi").
  final List<String> preselect;

  @override
  ConsumerState<SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends ConsumerState<SplitSheet> {
  late final FormRunner _run = FormRunner(setState);
  final List<_Person> _people = [];
  final _newName = TextEditingController();
  int _rounding = 5000;
  bool _ownerShare = true;

  /// Own amounts per person instead of equal shares.
  bool _custom = false;

  @override
  void initState() {
    super.initState();
    for (final s in widget.initial) {
      _people.add(
        _Person(contactId: s.contactId, name: s.name, amount: s.amount),
      );
    }
    _custom =
        widget.initial.isNotEmpty &&
        widget.initial.map((s) => s.amount).toSet().length > 1;
  }

  @override
  void dispose() {
    _newName.dispose();
    for (final p in _people) {
      p.amount.dispose();
    }
    super.dispose();
  }

  void _toggle(Contact c) => setState(() {
    final i = _people.indexWhere((p) => p.contactId == c.id);
    if (i >= 0) {
      _people.removeAt(i).amount.dispose();
    } else {
      _people.add(_Person(contactId: c.id, name: c.alias));
    }
  });

  void _addName() {
    final n = _newName.text.trim();
    if (n.isEmpty) return;
    final contacts = ref.read(contactsProvider).value ?? const <Contact>[];
    final known = contacts
        .where((c) => c.alias.toLowerCase() == n.toLowerCase())
        .firstOrNull;
    setState(() {
      if (known != null) {
        if (!_people.any((p) => p.contactId == known.id)) {
          _people.add(_Person(contactId: known.id, name: known.alias));
        }
      } else if (!_people.any((p) => p.contactId == null && p.name == n)) {
        _people.add(_Person(name: n));
      }
      _newName.clear();
    });
  }

  List<int> get _amounts {
    if (_custom) {
      return [for (final p in _people) parseVndInput(p.amount.text) ?? 0];
    }
    return computeShares(
      widget.total,
      [for (final _ in _people) (mode: 'EQUAL', value: null)],
      ownerShare: _ownerShare,
      rounding: _rounding,
    ).shares;
  }

  Future<void> _submit() async {
    final amounts = _amounts;
    final sum = amounts.fold<int>(0, (a, b) => a + b);
    if (_people.isEmpty) {
      setState(() => _run.error = 'Chọn ít nhất một người.');
      return;
    }
    if (amounts.any((a) => a <= 0)) {
      setState(() => _run.error = 'Mỗi người cần một số tiền lớn hơn 0.');
      return;
    }
    if (sum > widget.total) {
      setState(
        () => _run.error =
            'Tổng phần chia (${formatVnd(sum)}) lớn hơn số tiền của khoản chi.',
      );
      return;
    }
    final ok = await _run.run(
      () => ref
          .read(splitApiProvider)
          .apply(
            txId: widget.txId,
            applicationId: widget.applicationId,
            categoryId: widget.categoryId,
            shares: [
              for (var i = 0; i < _people.length; i++)
                SplitShare(
                  contactId: _people[i].contactId,
                  name: _people[i].name,
                  amount: amounts[i],
                ),
            ],
          ),
    );
    if (ok && mounted) {
      refreshSplits(ref, widget.txId);
      Navigator.pop(context);
      showSnack(context, 'Đã chia tiền.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final contacts = ref.watch(contactsProvider).value ?? const <Contact>[];
    if (widget.preselect.isNotEmpty && _people.isEmpty && contacts.isNotEmpty) {
      for (final id in widget.preselect) {
        final c = contacts.where((x) => x.id == id).firstOrNull;
        if (c != null) _people.add(_Person(contactId: c.id, name: c.alias));
      }
    }
    final amounts = _amounts;
    final owner = widget.total - amounts.fold<int>(0, (a, b) => a + b);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Chia ${formatVnd(widget.total)}',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'Mỗi người được chọn sẽ nợ bạn phần của họ.',
          style: TextStyle(color: pal.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (contacts.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final c in contacts)
                FilterChip(
                  label: Text(c.alias),
                  selected: _people.any((p) => p.contactId == c.id),
                  onSelected: (_) => _toggle(c),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newName,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addName(),
                decoration: const InputDecoration(
                  labelText: 'Thêm người khác',
                  hintText: 'Nhập tên',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Thêm',
              onPressed: _addName,
              icon: const Icon(Symbols.person_add_rounded),
            ),
          ],
        ),
        if (_people.isNotEmpty) ...[
          const SizedBox(height: 12),
          PillTabs<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Chia đều')),
              ButtonSegment(value: true, label: Text('Tự nhập')),
            ],
            selected: {_custom},
            onSelectionChanged: (s) => setState(() {
              final next = s.first;
              if (next && !_custom) {
                final cur = _amounts;
                for (var i = 0; i < _people.length; i++) {
                  _people[i].amount.text = formatVnd(cur[i])
                      .replaceAll(' ₫', '')
                      .replaceAll('₫', '')
                      .trim();
                }
              }
              _custom = next;
            }),
          ),
          const SizedBox(height: 10),
          if (!_custom) ...[
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
            const SizedBox(height: 6),
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
          ],
          const SizedBox(height: 6),
          for (var i = 0; i < _people.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _people[i].contactId == null
                          ? '${_people[i].name} (mới)'
                          : _people[i].name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: pal.ink,
                      ),
                    ),
                  ),
                  if (_custom)
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _people[i].amount,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.end,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          ThousandsFormatter(),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          suffixText: '₫',
                          isDense: true,
                        ),
                      ),
                    )
                  else
                    Text(
                      formatVnd(amounts[i]),
                      style: TextStyle(color: pal.ink),
                    ),
                  IconButton(
                    tooltip: 'Bỏ ${_people[i].name}',
                    onPressed: () =>
                        setState(() => _people.removeAt(i).amount.dispose()),
                    icon: const Icon(Symbols.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
          Text(
            splitPreviewLine(
              [for (final p in _people) p.name],
              amounts,
              owner < 0 ? 0 : owner,
            ),
            key: const Key('split-preview'),
            style: TextStyle(color: pal.accentInk, fontWeight: FontWeight.w700),
          ),
        ],
        FormError(_run.error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _run.busy || _people.isEmpty ? null : _submit,
          child: const Text('Xác nhận chia'),
        ),
      ],
    );
  }
}
