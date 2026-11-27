import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/outbox.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../../core/ui/moma_switch.dart';
import '../../app/theme/palette.dart';

enum _Kind { expense, income, transfer }

/// Manual quick entry. Intent only: the server decides the journal (no ledger logic here).
class QuickEntryPage extends ConsumerStatefulWidget {
  const QuickEntryPage({super.key});
  @override
  ConsumerState<QuickEntryPage> createState() => _QuickEntryPageState();
}

class _QuickEntryPageState extends ConsumerState<QuickEntryPage> {
  _Kind _kind = _Kind.expense;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _accountId;
  String? _toAccountId;
  String? _categoryId;
  DateTime _when = DateTime.now();
  bool _datePicked = false;
  DateTime get _shownDate => _datePicked ? _when : DateTime.now();
  bool _busy = false;
  String? _error;

  /// One id per form instance: a retry after a lost response replays instead of double-posting.
  final String _commandId = ApiClient.newId();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _quick.dispose();
    super.dispose();
  }

  String? _validateSelection() {
    if (_accountId == null) {
      return 'Chọn tài khoản.';
    }
    if (_kind != _Kind.transfer && _categoryId == null) {
      return 'Chọn danh mục.';
    }
    final badTarget = _toAccountId == null || _toAccountId == _accountId;
    if (_kind == _Kind.transfer && badTarget) {
      return 'Chọn tài khoản nhận khác tài khoản gửi.';
    }
    return null;
  }

  Future<void> _save() async {
    final amount = parseVndInput(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Nhập số tiền hợp lệ.');
      return;
    }
    final problem = _validateSelection();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final payload = <String, dynamic>{
      'kind': switch (_kind) {
        _Kind.expense => 'EXPENSE',
        _Kind.income => 'INCOME',
        _Kind.transfer => 'TRANSFER',
      },
      'account_id': _accountId,
      'amount': amount.toString(),
      'effective_at': (_datePicked ? _when : DateTime.now())
          .toUtc()
          .toIso8601String(),
      if (_kind != _Kind.transfer) 'category_id': _categoryId,
      if (_kind == _Kind.transfer) 'to_account_id': _toAccountId,
      if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
    };
    try {
      await ref
          .read(apiProvider)
          .command('TX_CREATE', payload, commandId: _commandId);
      refreshAll(ref);
      if (mounted) {
        showSnack(context, 'Đã lưu giao dịch.');
        context.pop();
      }
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') {
        // Keep the exact command (same id) so it can be sent later without any risk of duplicates.
        final queued = await ref
            .read(outboxProvider.notifier)
            .add('TX_CREATE', payload, _commandId);
        if (mounted) {
          if (queued) {
            showSnack(
              context,
              'Đang offline: đã lưu, sẽ tự đồng bộ khi có mạng.',
            );
            context.pop();
          } else {
            await showErrorDialog(
              context,
              'Hàng đợi offline đã đầy. Hãy đồng bộ trước.',
            );
          }
        }
      } else if (mounted) {
        await showErrorDialog(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  final _quick = TextEditingController();

  /// Fills the form from free text such as "ăn trưa 65k". Suggestion only: the user still confirms and saves.
  void _applyQuick(String text) {
    final q = parseQuickText(text);
    final cats = ref.read(categoriesProvider).value ?? <Category>[];
    final type = q.income ? 'INCOME' : 'EXPENSE';
    setState(() {
      _kind = q.income ? _Kind.income : _Kind.expense;
      if (q.amount != null) {
        _amount.text = formatVnd(q.amount!).replaceAll(' ₫', '');
      }
      _categoryId = cats
          .where((c) => c.name == q.categoryName && c.type == type)
          .firstOrNull
          ?.id;
      if (q.note.isNotEmpty) _note.text = q.note;
      _error = q.amount == null
          ? 'Chưa thấy số tiền rõ ràng (vd 65k, 1,5tr). Hãy nhập số tiền bên dưới.'
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);
    final categories = ref.watch(categoriesProvider);
    final type = _kind == _Kind.income ? 'INCOME' : 'EXPENSE';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thêm giao dịch'),
        leading: IconButton(
          icon: const Icon(Symbols.close_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (accs) {
          if (accs.isEmpty) {
            return const EmptyState(
              icon: Symbols.account_balance_wallet_rounded,
              title: 'Chưa có tài khoản',
              hint: 'Hãy thêm một tài khoản ở tab Tài khoản trước khi nhập giao dịch.',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              LabeledField(
                label: 'Mô tả nhanh',
                hint: 'Nhập khoản thu chi bằng lời thường',
                controller: _quick,
                onSubmitted: _applyQuick,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 16),
              PillTabs<_Kind>(
                segments: const [
                  ButtonSegment(value: _Kind.expense, label: Text('Chi tiêu')),
                  ButtonSegment(value: _Kind.income, label: Text('Thu nhập')),
                  ButtonSegment(value: _Kind.transfer, label: Text('Chuyển')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _categoryId = null;
                }),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  ThousandsFormatter(),
                ],
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: context.pal.accentInk,
                ),
                decoration: const InputDecoration(
                  hintText: '0 ₫',
                  suffixText: '₫',
                ),
              ),
              const SizedBox(height: 16),
              PickField<String>(
                isExpanded: true,
                initialValue: _accountId,
                decoration: InputDecoration(
                  labelText: _kind == _Kind.transfer
                      ? 'Từ tài khoản'
                      : 'Tài khoản',
                ),
                items: [
                  for (final a in accs)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text('${a.name} · ${accountKindLabel(a.kind)}'),
                    ),
                ],
                onChanged: (v) => setState(() => _accountId = v),
              ),
              if (_kind == _Kind.transfer) ...[
                const SizedBox(height: 12),
                PickField<String>(
                  isExpanded: true,
                  initialValue: _toAccountId,
                  decoration: const InputDecoration(labelText: 'Đến tài khoản'),
                  items: [
                    for (final a in accs)
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => _toAccountId = v),
                ),
              ] else ...[
                const SizedBox(height: 16),
                Text(
                  'Danh mục',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                categories.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text(
                    e is ApiException ? e.message : 'Không tải được danh mục.',
                  ),
                  data: (cats) => Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in cats.where((c) => c.type == type))
                        ChoiceChip(
                          avatar: Icon(categoryIcon(c.icon), size: 18),
                          label: Text(c.name),
                          selected: _categoryId == c.id,
                          onSelected: (_) => setState(() => _categoryId = c.id),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              LabeledField(
                label: 'Ghi chú',
                hint: 'Nhập ghi chú',
                controller: _note,
              ),
              const SizedBox(height: 12),
              DateField(
                label: 'Ngày giao dịch',
                value: _shownDate,
                required: true,
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 1)),
                onChanged: (d) {
                  if (d == null) return;
                  final now = DateTime.now();
                  setState(() {
                    _datePicked = true;
                    _when = DateTime(
                      d.year,
                      d.month,
                      d.day,
                      now.hour,
                      now.minute,
                    );
                  });
                },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: MomaColors.expense),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Lưu giao dịch'),
              ),
            ],
          );
        },
      ),
    );
  }
}
