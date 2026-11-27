import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'add_account_sheet.dart';
import 'sync/account_sync_card.dart';
import 'sync/integrations_tab.dart';
import 'sync/sync_sources.dart';

enum _Tab { accounts, integrations }

/// "Tài khoản & Đồng bộ": every account with how it records transactions by itself (bank sync through SePay
/// or Android notifications), plus a tab with the state of each integration.
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});
  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage>
    with WidgetsBindingObserver {
  _Tab _tab = _Tab.accounts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the system screen where notification access is granted.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref
        ..invalidate(notifySyncStateProvider)
        ..invalidate(pushPermissionProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: PillTabs<_Tab>(
              segments: const [
                ButtonSegment(value: _Tab.accounts, label: Text('Tài khoản')),
                ButtonSegment(
                  value: _Tab.integrations,
                  label: Text('Tích hợp'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          Expanded(
            child: _tab == _Tab.accounts
                ? const _AccountsTab()
                : const IntegrationsTab(),
          ),
        ],
      ),
    );
  }
}

class _AccountsTab extends ConsumerWidget {
  const _AccountsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final links = ref.watch(bankLinksProvider);
    final notify = ref.watch(notifySyncStateProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(accountsProvider)
          ..invalidate(bankLinksProvider)
          ..invalidate(notifySyncStateProvider);
        await ref.read(accountsProvider.future);
      },
      child: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (list) {
          final linkOf = {
            for (final l in links.value ?? const <BankLink>[]) l.accountId: l,
          };
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              const _SyncBanner(),
              const SizedBox(height: 12),
              _TotalCard(list),
              const SizedBox(height: 16),
              if (list.isEmpty)
                const EmptyState(
                  embedded: true,
                  icon: Symbols.account_balance_wallet_rounded,
                  title: 'Chưa có tài khoản',
                  hint: 'Thêm ngân hàng, ví hoặc tiền mặt để bắt đầu.',
                )
              else
                for (final a in list)
                  AccountSyncCard(
                    key: ValueKey('account-${a.id}'),
                    account: a,
                    link: linkOf[a.id],
                    linksFailed: links.hasError && !links.hasValue,
                    notify: notify.value,
                    onOpen: () => showFormSheet<void>(
                      context,
                      (_) => _EditAccountSheet(account: a),
                    ),
                  ),
              const SizedBox(height: 4),
              _AddButton(onTap: () => _addAccount(context)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addAccount(BuildContext context) async {
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

class _SyncBanner extends StatelessWidget {
  const _SyncBanner();

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final body = TextStyle(fontSize: 13, height: 1.4, color: pal.ink);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: pal.tintSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Symbols.sync_rounded,
              color: MomaColors.emerald,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quản lý tài khoản và cách tự ghi',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: pal.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Đồng bộ ngân hàng: ngân hàng báo thẳng về MoMa, tự ghi cả khi điện thoại tắt.',
                  style: body,
                ),
                const SizedBox(height: 2),
                Text(
                  'Thông báo Android: đọc thông báo biến động số dư trên điện thoại.',
                  style: body,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Giải thích',
            visualDensity: VisualDensity.compact,
            onPressed: () => showInfoDialog(
              context,
              title: 'Hai cách tự ghi giao dịch',
              message: syncOverviewHelp,
            ),
            icon: Icon(Symbols.info_rounded, size: 20, color: pal.muted),
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard(this.list);
  final List<Account> list;

  @override
  Widget build(BuildContext context) {
    final known = list.where((a) => !a.isCard && a.balance != null);
    final total = known.fold<int>(0, (s, a) => s + a.balance!);
    final unknown = list.where((a) => a.balance == null).length;
    return Container(
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
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.pal.tintSoft,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: const SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Symbols.add_rounded, color: MomaColors.emerald),
              SizedBox(width: 8),
              Text(
                'Thêm tài khoản',
                style: TextStyle(
                  color: MomaColors.emerald,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
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
