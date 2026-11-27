import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/sheets.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/widgets.dart';
import 'add_account_sheet.dart';
import '../../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(accountsProvider);
          await ref.read(accountsProvider.future);
        },
        child: accounts.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(accountsProvider),
          ),
          data: (list) {
            final known = list.where((a) => !a.isCard && a.balance != null);
            final total = known.fold<int>(0, (s, a) => s + a.balance!);
            final unknown = list.where((a) => a.balance == null).length;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [MomaColors.forest, MomaColors.emerald],
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tổng số dư',
                        style: TextStyle(
                          color: MomaColors.mint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatVnd(total),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (unknown > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Chưa gồm $unknown tài khoản chưa biết số dư đầu kỳ.',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  const EmptyState(embedded: true, 
                      icon: Symbols.account_balance_wallet_rounded,
                      title: 'Chưa có tài khoản',
                      hint: 'Thêm ngân hàng, ví hoặc tiền mặt để bắt đầu.',
                    )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: context.pal.surface,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      children: [
                        for (final (i, a) in list.indexed) ...[
                          InkWell(
                            onTap: () => showFormSheet<void>(
                              context,
                              (_) => _EditAccountSheet(account: a),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CategoryAvatar(
                                    iconData: accountIcon(a.kind),
                                    color: MomaColors.emerald,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          a.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${accountKindLabel(a.kind)} · ${a.institution}${a.last4 == null ? '' : ' · •• ${a.last4}'}',
                                          style: TextStyle(
                                            color: context.pal.muted,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        a.balance == null
                                            ? 'Chưa biết'
                                            : formatVnd(
                                                a.isCard
                                                    ? -a.balance!
                                                    : a.balance!,
                                              ),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      if (a.isCard)
                                        Text(
                                          'Dư nợ',
                                          style: TextStyle(
                                            color: context.pal.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (i < list.length - 1)
                            Divider(height: 1, color: context.pal.lineSoft),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _addAccount(context, ref),
                  icon: const Icon(Symbols.add_rounded),
                  label: const Text('Thêm tài khoản'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _addAccount(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: const AddAccountSheet(),
      ),
    );
  }
}

class _EditAccountSheet extends ConsumerStatefulWidget {
  const _EditAccountSheet({required this.account});
  final Account account;
  @override
  ConsumerState<_EditAccountSheet> createState() => _EditAccountSheetState();
}

class _EditAccountSheetState extends ConsumerState<_EditAccountSheet> {
  late final FormRunner _run = FormRunner(setState);
  late final TextEditingController _name = TextEditingController(
    text: widget.account.name,
  );
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit({bool archive = false}) async {
    if (_name.text.trim().isEmpty) {
      setState(() => _run.error = 'Nhập tên tài khoản.');
      return;
    }
    final ok = await _run.run(
      () => ref.read(apiProvider).command('ACCOUNT_UPDATE', {
        'account_id': widget.account.id,
        'expected_version': widget.account.version,
        'name': _name.text.trim(),
        if (archive) 'archived': true,
      }, commandId: _id),
    );
    if (ok && mounted) {
      refreshAll(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sửa tài khoản',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: 'Tên tài khoản',
          hint: 'Nhập tên tài khoản',
          controller: _name,
        ),
        Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Lưu trữ tài khoản giữ nguyên lịch sử nhưng không cho ghi giao dịch mới.',
            style: TextStyle(color: context.pal.muted),
          ),
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu'),
        ),
        TextButton(
          onPressed: _run.busy ? null : () => _submit(archive: true),
          child: const Text('Lưu trữ tài khoản'),
        ),
      ],
    );
  }
}
