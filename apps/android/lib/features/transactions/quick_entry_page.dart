import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

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
  bool _busy = false;
  String? _error;

  /// One id per form instance: a retry after a lost response replays instead of double-posting.
  final String _commandId = ApiClient.newId();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
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
    try {
      await ref.read(apiProvider).command('TX_CREATE', {
        'kind': switch (_kind) {
          _Kind.expense => 'EXPENSE',
          _Kind.income => 'INCOME',
          _Kind.transfer => 'TRANSFER',
        },
        'account_id': _accountId,
        'amount': amount.toString(),
        'effective_at': _when.toUtc().toIso8601String(),
        if (_kind != _Kind.transfer) 'category_id': _categoryId,
        if (_kind == _Kind.transfer) 'to_account_id': _toAccountId,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      }, commandId: _commandId);
      refreshAll(ref);
      if (mounted) {
        showSnack(context, 'Đã lưu giao dịch.');
        context.pop();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) {
      setState(() {
        _when = DateTime(d.year, d.month, d.day, _when.hour, _when.minute);
      });
    }
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
          icon: const Icon(Icons.close_rounded),
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
              icon: Icons.account_balance_wallet_rounded,
              title: 'Chưa có tài khoản',
              hint: 'Hãy thêm một tài khoản ở tab Tài khoản trước khi nhập giao dịch.',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SegmentedButton<_Kind>(
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
                  _ThousandsFormatter(),
                ],
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MomaColors.forest,
                ),
                decoration: const InputDecoration(
                  hintText: '0 ₫',
                  suffixText: '₫',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
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
                DropdownButtonFormField<String>(
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
              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.edit_note_rounded),
                  hintText: 'Ghi chú (tùy chọn)',
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                tileColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: const Icon(Icons.event_rounded),
                title: Text(
                  '${_when.day.toString().padLeft(2, '0')}/${_when.month.toString().padLeft(2, '0')}/${_when.year}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickDate,
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

class _ThousandsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final n = parseVndInput(newValue.text);
    if (n == null) return const TextEditingValue();
    final text = formatVnd(n).replaceAll(' ₫', '');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
