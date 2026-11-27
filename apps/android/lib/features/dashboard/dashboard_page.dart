import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import '../transactions/transactions_page.dart';

/// "Trang chủ": net worth, shortcuts to planning, accounts and the latest transactions.
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final txs =
        ref.watch(transactionsProvider).value?.items ?? const <MomaTx>[];
    final categories = {
      for (final c in ref.watch(categoriesProvider).value ?? <Category>[])
        c.id: c,
    };
    final accountById = {for (final a in accounts) a.id: a};
    return MomaPage(
      title: 'Xin chào, ${_ownerName()}! 👋',
      subtitle: _today(),
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(summaryProvider);
          ref.invalidate(accountsProvider);
          ref.invalidate(transactionsProvider);
          await ref.read(summaryProvider.future);
        },
        child: summary.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(summaryProvider),
          ),
          data: (s) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _BalanceCard(
                summary: s,
                hidden: _hidden,
                onToggle: () => setState(() => _hidden = !_hidden),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _Shortcut(
                    icon: Icons.handshake_outlined,
                    label: 'Công nợ',
                    color: const Color(0xFF8B5CF6),
                    onTap: () => context.push('/planning?tab=0'),
                  ),
                  _Shortcut(
                    icon: Icons.savings_outlined,
                    label: 'Tiết kiệm',
                    color: const Color(0xFF1B8A5A),
                    onTap: () => context.push('/planning?tab=1'),
                  ),
                  _Shortcut(
                    icon: Icons.pie_chart_outline_rounded,
                    label: 'Ngân sách',
                    color: const Color(0xFFFF8A3D),
                    onTap: () => context.push('/planning?tab=2'),
                  ),
                  _Shortcut(
                    icon: Icons.event_repeat_rounded,
                    label: 'Định kỳ',
                    color: const Color(0xFF2F80ED),
                    onTap: () => context.push('/planning?tab=3'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _SectionTitle(
                title: 'Tài khoản',
                action: 'Xem tất cả',
                onAction: () => context.push('/accounts'),
              ),
              const SizedBox(height: 8),
              if (accounts.isEmpty)
                const _Hint('Chưa có tài khoản. Vào Xem tất cả để thêm.')
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: _cardDeco,
                  child: Column(
                    children: [
                      for (final (i, a) in accounts.take(4).indexed) ...[
                        _AccountRow(account: a),
                        if (i < accounts.take(4).length - 1)
                          const Divider(height: 1, color: Color(0xFFEEF2F0)),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              _SectionTitle(
                title: 'Giao dịch gần đây',
                action: 'Xem tất cả',
                onAction: () => ref.read(shellTabProvider.notifier).select(1),
              ),
              const SizedBox(height: 8),
              if (txs.isEmpty)
                const _Hint('Chưa có giao dịch. Bấm nút + để thêm.')
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: _cardDeco,
                  child: Column(
                    children: [
                      for (final (i, t) in txs.take(5).indexed) ...[
                        TxTile(
                          tx: t,
                          category: categories[t.categoryId],
                          account: accountById[t.accountId],
                        ),
                        if (i < txs.take(5).length - 1)
                          const Divider(height: 1, color: Color(0xFFEEF2F0)),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final _cardDeco = BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(22),
);

String _ownerName() {
  try {
    final u = Supabase.instance.client.auth.currentUser;
    final n = (u?.userMetadata?['display_name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n.split(' ').last;
    return (u?.email ?? 'bạn').split('@').first;
  } on Object {
    return 'bạn';
  }
}

String _today() {
  final n = DateTime.now();
  const wd = [
    'Thứ hai',
    'Thứ ba',
    'Thứ tư',
    'Thứ năm',
    'Thứ sáu',
    'Thứ bảy',
    'Chủ nhật',
  ];
  return '${wd[n.weekday - 1]}, ${n.day} tháng ${n.month}';
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.summary,
    required this.hidden,
    required this.onToggle,
  });
  final Summary summary;
  final bool hidden;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MomaColors.forest, MomaColors.emerald],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33073D33),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Tổng tài sản ròng',
                style: TextStyle(
                  color: MomaColors.mint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              InkResponse(
                onTap: onToggle,
                child: Icon(
                  hidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: Colors.white70,
                  semanticLabel: hidden ? 'Hiện số dư' : 'Ẩn số dư',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              hidden ? '••••••••' : formatVnd(summary.netWorth),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (summary.unknownBaselines > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Chưa gồm ${summary.unknownBaselines} tài khoản chưa biết số dư đầu kỳ.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MiniFlow(
                  label: 'Thu tháng này',
                  value: hidden ? '••••' : '+${formatVnd(summary.income)}',
                  icon: Icons.south_rounded,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MiniFlow(
                  label: 'Chi tháng này',
                  value: hidden ? '••••' : '-${formatVnd(summary.expense)}',
                  icon: Icons.north_east_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniFlow extends StatelessWidget {
  const _MiniFlow({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              CategoryAvatar(iconData: icon, color: color, size: 52),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.action,
    required this.onAction,
  });
  final String title;
  final String action;
  final VoidCallback onAction;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      TextButton(onPressed: onAction, child: Text(action)),
    ],
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: _cardDeco,
    child: Text(text, style: const TextStyle(color: MomaColors.muted)),
  );
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account});
  final Account account;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        CategoryAvatar(
          iconData: accountIcon(account.kind),
          color: MomaColors.emerald,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Text(
                account.institution,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: MomaColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        Text(
          account.balance == null ? 'Chưa rõ' : formatVnd(account.balance!),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}
