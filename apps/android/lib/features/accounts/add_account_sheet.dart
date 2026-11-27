import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

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

  static const _kinds = ['CASH', 'BANK', 'WALLET', 'SAVINGS', 'CREDIT_CARD'];

  @override
  void dispose() {
    _institution.dispose();
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
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
            Text(
              'Loại tài khoản',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final k in _kinds)
                  ChoiceChip(
                    avatar: Icon(accountIcon(k), size: 18),
                    label: Text(accountKindLabel(k)),
                    selected: _kind == k,
                    showCheckmark: false,
                    selectedColor: pal.tint,
                    side: BorderSide(
                      color: _kind == k ? MomaColors.emerald : pal.line,
                    ),
                    shape: const StadiumBorder(),
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Tên tài khoản',
              hint: 'Nhập tên gợi nhớ',
              controller: _name,
              icon: Symbols.edit_rounded,
              required: true,
              textInputAction: TextInputAction.next,
              validator: V.all([
                V.required('tên tài khoản'),
                V.maxLength(60, 'Tên'),
              ]),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Ngân hàng hoặc nơi mở',
              hint: 'Nhập ngân hàng hoặc ví',
              controller: _institution,
              icon: Symbols.account_balance_rounded,
              required: true,
              textInputAction: TextInputAction.next,
              validator: V.all([
                V.required('nơi mở tài khoản'),
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
