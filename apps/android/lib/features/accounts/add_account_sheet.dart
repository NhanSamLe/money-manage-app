import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/account_presets.dart';
import '../../core/icons.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';

/// Opens the add-account form, optionally pre-filled from a [AccountPreset] (setup wizard and account list).
/// Returns true when an account was created.
Future<bool?> showAddAccountSheet(
  BuildContext context, {
  AccountPreset? preset,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (ctx) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
    child: AddAccountSheet(preset: preset),
  ),
);

class AddAccountSheet extends ConsumerStatefulWidget {
  const AddAccountSheet({super.key, this.preset});
  final AccountPreset? preset;
  @override
  ConsumerState<AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends ConsumerState<AddAccountSheet> {
  final _form = GlobalKey<FormState>();
  late String _kind = widget.preset?.kind ?? 'BANK';
  late final _institution = TextEditingController(
    text: widget.preset?.institution ?? '',
  );
  late final _name = TextEditingController(text: widget.preset?.name ?? '');
  final _opening = TextEditingController();
  final _commandId = ApiClient.newId();
  bool _busy = false;
  late String? _pickedInst = widget.preset?.institution;
  bool _autoName = false;
  String? _instError;
  static const _other = '__other';

  List<String> _instOptions() => {
    for (final p in accountPresets)
      if (p.kind == _kind) p.institution,
  }.toList();

  static const _kinds = ['CASH', 'BANK', 'WALLET', 'SAVINGS', 'CREDIT_CARD'];

  @override
  void dispose() {
    _institution.dispose();
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final formOk = _form.currentState?.validate() ?? false;
    final instOk = _kind == 'CASH' || (_pickedInst != null && _institution.text.trim().isNotEmpty);
    if (!instOk) setState(() => _instError = 'Chọn nơi mở tài khoản.');
    if (_busy || !formOk || !instOk) return;
    final opening = _opening.text.trim().isEmpty
        ? null
        : parseVndInput(_opening.text);
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).command('ACCOUNT_CREATE', {
        'kind': _kind,
        'institution': _institution.text.trim(),
        'name': _name.text.trim(),
        if (opening != null) 'opening_amount': opening.toString(),
        if (opening != null)
          'baseline_at': DateTime.now().toUtc().toIso8601String(),
      }, commandId: _commandId);
      refreshAll(ref);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final p = widget.preset;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (p != null) ...[
                  AccountBadge(
                    institution: p.institution,
                    kind: p.kind,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    p == null ? 'Thêm tài khoản' : 'Thêm ${p.name}',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            PickField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Loại tài khoản'),
              icon: accountIcon(_kind),
              items: [
                for (final k in _kinds)
                  DropdownMenuItem(value: k, child: Text(accountKindLabel(k))),
              ],
              onChanged: (v) => setState(() {
                _kind = v ?? _kind;
                _pickedInst = null;
                _institution.text = _kind == 'CASH' ? 'Tiền mặt' : '';
                if (_kind == 'CASH') _name.text = 'Tiền mặt';
              }),
            ),
            if (_kind == 'BANK') ...[
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(context, false);
                  context.push('/banks');
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: pal.tint,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(Symbols.sync_alt_rounded, color: MomaColors.emerald),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Muốn tiền vào, ra tự ghi? Kết nối tài khoản ngân hàng thật thay vì nhập tay.',
                          style: TextStyle(fontSize: 13, height: 1.35, color: pal.ink),
                        ),
                      ),
                      const Icon(Symbols.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ],
            if (_kind != 'CASH') ...[
              const SizedBox(height: 16),
              PickField<String>(
                key: ValueKey('inst-$_kind'),
                initialValue: _pickedInst,
                decoration: const InputDecoration(labelText: 'Ngân hàng hoặc nơi mở'),
                icon: Symbols.account_balance_rounded,
                errorText: _pickedInst == null ? _instError : null,
                items: [
                  for (final n in _instOptions())
                    DropdownMenuItem(value: n, child: Text(n)),
                  const DropdownMenuItem(value: _other, child: Text('Khác')),
                ],
                onChanged: (v) => setState(() {
                  _pickedInst = v;
                  if (v != null && v != _other) {
                    _institution.text = v;
                    if (_name.text.isEmpty || _autoName) {
                      _name.text = v;
                      _autoName = true;
                    }
                  } else {
                    _institution.text = '';
                  }
                }),
              ),
              if (_pickedInst == _other) ...[
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Tên nơi mở',
                  hint: 'Nhập tên',
                  controller: _institution,
                  icon: Symbols.edit_rounded,
                  required: true,
                  validator: V.all([V.required('nơi mở tài khoản'), V.maxLength(60, 'Tên')]),
                ),
              ],
            ],
            const SizedBox(height: 16),
            LabeledField(
              label: 'Tên tài khoản',
              hint: 'Nhập tên gợi nhớ',
              controller: _name,
              icon: Symbols.edit_rounded,
              required: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _autoName = false,
              validator: V.all([
                V.required('tên tài khoản'),
                V.maxLength(60, 'Tên'),
              ]),
            ),
            const SizedBox(height: 16),
            MoneyField(
              controller: _opening,
              hint: 'Số dư hiện tại',
              optional: true,
            ),
            const SizedBox(height: 20),
            ActionButtons(
              primaryLabel: 'Lưu tài khoản',
              onPrimary: _save,
              secondaryLabel: 'Hủy',
              onSecondary: () => Navigator.pop(context, false),
              busy: _busy,
            ),
          ],
        ),
      ),
    );
  }
}
