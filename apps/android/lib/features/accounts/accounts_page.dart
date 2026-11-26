import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

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
          data: (list) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(
                'Tài khoản',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MomaColors.forest,
                ),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const EmptyState(
                  icon: Icons.account_balance_wallet_rounded,
                  title: 'Chưa có tài khoản',
                  hint: 'Thêm ngân hàng, ví hoặc tiền mặt để bắt đầu.',
                ),
              for (final a in list)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: MomaColors.mint.withValues(alpha: 0.4),
                      child: Icon(
                        accountIcon(a.kind),
                        color: MomaColors.forest,
                      ),
                    ),
                    title: Text(
                      a.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${a.institution}${a.last4 == null ? '' : ' · •• ${a.last4}'}',
                    ),
                    trailing: Text(
                      a.balance == null
                          ? 'Chưa biết'
                          : formatVnd(a.isCard ? -a.balance! : a.balance!),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _addAccount(context, ref),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Thêm tài khoản'),
              ),
            ],
          ),
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
        child: const _AddAccountSheet(),
      ),
    );
  }
}

class _AddAccountSheet extends ConsumerStatefulWidget {
  const _AddAccountSheet();
  @override
  ConsumerState<_AddAccountSheet> createState() => _AddAccountSheetState();
}

class _AddAccountSheetState extends ConsumerState<_AddAccountSheet> {
  String _kind = 'BANK';
  final _institution = TextEditingController();
  final _name = TextEditingController();
  final _opening = TextEditingController();
  final _commandId = ApiClient.newId();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _institution.dispose();
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _institution.text.trim().isEmpty) {
      setState(() => _error = 'Nhập tên và nơi mở tài khoản.');
      return;
    }
    final opening = _opening.text.trim().isEmpty
        ? null
        : parseVndInput(_opening.text);
    setState(() {
      _busy = true;
      _error = null;
    });
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
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const kinds = ['BANK', 'WALLET', 'CASH', 'SAVINGS', 'CREDIT_CARD'];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Thêm tài khoản',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final k in kinds)
                ChoiceChip(
                  label: Text(accountKindLabel(k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _institution,
            decoration: const InputDecoration(
              hintText: 'Ngân hàng / nơi mở (vd: Vietcombank)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(hintText: 'Tên tài khoản'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _opening,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: _kind == 'CREDIT_CARD'
                  ? 'Dư nợ hiện tại (để trống nếu chưa biết)'
                  : 'Số dư hiện tại (để trống nếu chưa biết)',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(color: MomaColors.expense),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Lưu tài khoản'),
          ),
        ],
      ),
    );
  }
}
