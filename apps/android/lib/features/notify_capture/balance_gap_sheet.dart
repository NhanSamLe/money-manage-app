import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'capture_engine.dart';
import 'capture_state.dart';
import 'notify_capture_service.dart';

enum _GapAction { category, transfer, adjust }

/// Resolves a [BalanceGap]: record it as an expense / income (category, default "Khác"), as a transfer with
/// another own account, or as a balance adjustment. Nothing is posted until the owner chooses.
class BalanceGapSheet extends ConsumerStatefulWidget {
  const BalanceGapSheet({super.key, required this.gap});
  final BalanceGap gap;
  @override
  ConsumerState<BalanceGapSheet> createState() => _BalanceGapSheetState();
}

class _BalanceGapSheetState extends ConsumerState<BalanceGapSheet> {
  _GapAction _action = _GapAction.category;
  String? _categoryId;
  String? _otherId;
  String? _otherError;
  final _note = TextEditingController();
  late final FormRunner _run = FormRunner(setState);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String get _type => widget.gap.missingOutflow ? 'EXPENSE' : 'INCOME';

  Future<void> _save(List<Account> accounts, List<Category> cats) async {
    final g = widget.gap;
    if (_action == _GapAction.transfer && _otherId == null) {
      setState(() => _otherError = 'Chọn tài khoản.');
      return;
    }
    final account = accounts.where((a) => a.id == g.accountId).firstOrNull;
    final catId =
        _categoryId ??
        cats
            .where(
              (c) =>
                  c.type == _type &&
                  (c.name == 'Khác' || c.name == 'Thu nhập khác'),
            )
            .firstOrNull
            ?.id ??
        cats.where((c) => c.type == _type).firstOrNull?.id;
    final ok = await _run.run(
      () => resolveGap(
        ref.read(apiProvider),
        ref.read(notifyCapturePrefsProvider),
        g,
        action: _action.name,
        categoryId: catId,
        note: _note.text,
        otherAccountId: _otherId,
        account: account,
      ),
    );
    if (!ok || !mounted) return;
    refreshAll(ref);
    ref.invalidate(balanceGapsProvider);
    Navigator.pop(context);
    showSnack(context, 'Đã ghi khoản ${formatVnd(g.amount.abs())}');
  }

  Future<void> _dismiss() async {
    await ref.read(notifyCapturePrefsProvider).removeGap(widget.gap.id);
    ref.invalidate(balanceGapsProvider);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.gap;
    final pal = context.pal;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final cats = [
      for (final c in ref.watch(categoriesProvider).value ?? const <Category>[])
        if (c.type == _type) c,
    ];
    final others = [
      for (final a in accounts)
        if (a.id != g.accountId) a,
    ];
    final outflow = g.missingOutflow;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          outflow ? 'Khoản chi chưa ghi' : 'Khoản thu chưa ghi',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(gapText(g), style: TextStyle(color: pal.muted, height: 1.4)),
        const SizedBox(height: 4),
        Text(
          'Số dư báo về: ${formatVnd(g.reported)}',
          style: TextStyle(color: pal.muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        PillTabs<_GapAction>(
          segments: [
            ButtonSegment(
              value: _GapAction.category,
              label: Text(outflow ? 'Chi tiêu' : 'Thu nhập'),
            ),
            const ButtonSegment(
              value: _GapAction.transfer,
              label: Text('Chuyển khoản'),
            ),
            const ButtonSegment(
              value: _GapAction.adjust,
              label: Text('Điều chỉnh'),
            ),
          ],
          selected: {_action},
          onSelectionChanged: (s) => setState(() => _action = s.first),
        ),
        const SizedBox(height: 14),
        if (_action == _GapAction.category) ...[
          PickField<String>(
            key: const ValueKey('gap-category'),
            initialValue:
                _categoryId ??
                cats
                    .where((c) => c.name == 'Khác' || c.name == 'Thu nhập khác')
                    .firstOrNull
                    ?.id,
            decoration: const InputDecoration(labelText: 'Danh mục'),
            items: [
              for (final c in cats)
                DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 12),
          LabeledField(
            label: 'Ghi chú',
            hint: 'Không bắt buộc',
            controller: _note,
          ),
        ] else if (_action == _GapAction.transfer)
          PickField<String>(
            key: const ValueKey('gap-other-account'),
            initialValue: _otherId,
            decoration: InputDecoration(
              labelText: outflow
                  ? 'Đã chuyển sang tài khoản'
                  : 'Chuyển từ tài khoản',
            ),
            errorText: _otherError,
            items: [
              for (final a in others)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() {
              _otherId = v;
              _otherError = null;
            }),
          )
        else
          Text(
            'Số dư trong MoMa được chỉnh theo số ngân hàng báo, không tính vào thu chi.',
            style: TextStyle(color: pal.muted, height: 1.4),
          ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : () => _save(accounts, cats),
          child: const Text('Lưu'),
        ),
        TextButton(
          onPressed: _run.busy ? null : _dismiss,
          child: const Text('Bỏ qua khoản này'),
        ),
      ],
    );
  }
}

/// "Cập nhật số dư MoMo": the owner types the wallet's current balance; a difference becomes a balance gap.
class UpdateBalanceSheet extends ConsumerStatefulWidget {
  const UpdateBalanceSheet({super.key, required this.account});
  final Account account;
  @override
  ConsumerState<UpdateBalanceSheet> createState() => _UpdateBalanceSheetState();
}

class _UpdateBalanceSheetState extends ConsumerState<UpdateBalanceSheet> {
  final _amount = TextEditingController();
  String? _error;
  late final FormRunner _run = FormRunner(setState);

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = parseVndInput(_amount.text);
    if (v == null) {
      setState(() => _error = 'Nhập số dư.');
      return;
    }
    BalanceGap? gap;
    final ok = await _run.run(() async {
      gap = await reportBalance(
        account: widget.account,
        reported: v,
        ledger: ApiCaptureLedger(ref.read(apiProvider)),
        prefs: ref.read(notifyCapturePrefsProvider),
      );
    });
    if (!ok || !mounted) return;
    refreshAll(ref);
    ref
      ..invalidate(balanceGapsProvider)
      ..invalidate(walletsToUpdateProvider);
    Navigator.pop(context);
    showSnack(
      context,
      gap == null ? 'Số dư ${widget.account.name} đã khớp' : gapText(gap!),
    );
  }

  Future<void> _turnOff() async {
    await ref.read(notifyCapturePrefsProvider).setWalletReminder(false);
    ref.invalidate(walletsToUpdateProvider);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Cập nhật số dư ${a.name}',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'Mở ${a.name}, xem số dư hiện tại rồi nhập vào đây. Phần chênh lệch sẽ thành khoản chưa ghi để bạn phân loại.',
          style: TextStyle(color: context.pal.muted, height: 1.4),
        ),
        const SizedBox(height: 14),
        MoneyField(
          controller: _amount,
          hint: 'Số dư hiện tại',
          autofocus: true,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _run.busy ? null : _save,
          icon: const Icon(Symbols.check_rounded),
          label: const Text('Lưu'),
        ),
        TextButton(
          onPressed: _run.busy ? null : _turnOff,
          child: const Text('Tắt nhắc hằng tuần'),
        ),
      ],
    );
  }
}
