import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/account_presets.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/ui/header.dart';
import '../../core/ui/motion.dart';
import '../../core/widgets.dart';
import '../../core/ui/money_pattern.dart';
import '../reminders/today_meals_card.dart';
import '../transactions/transactions_page.dart';
import '../transfers/transfer_suggestions.dart';

/// "Trang chủ" (design): green hero header, net-worth card, income / expense / savings, savings rate,
/// quick actions, accounts and the latest transactions.
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _hidden = false;
  static const _mask = '********';

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(summaryProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    // First run without any account: open the guided setup once per app session.
    final accState = ref.watch(accountsProvider);
    if (!_autoSetupShown && accState.hasValue && accounts.isEmpty) {
      _autoSetupShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.push('/onboarding');
      });
    }
    final txs =
        ref.watch(transactionsProvider).value?.items ?? const <MomaTx>[];
    final profile = ref.watch(profileProvider).value;
    final categories = {
      for (final c in ref.watch(categoriesProvider).value ?? <Category>[])
        c.id: c,
    };
    final accountById = {for (final a in accounts) a.id: a};
    return MomaPage(
      hero: true,
      title: 'Chào bạn, ${callName(profile)}',
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(summaryProvider);
          ref.invalidate(accountsProvider);
          ref.invalidate(transactionsProvider);
          ref.invalidate(profileProvider);
          await ref.read(summaryProvider.future);
        },
        child: summary.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(summaryProvider),
          ),
          data: (s) {
            final savings = (s.income - s.expense).clamp(0, 1 << 52);
            final rate = s.income <= 0
                ? 0.0
                : (savings / s.income).clamp(0.0, 1.0);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (accounts.isEmpty) ...[
                  _SetupCard(onTap: () => context.push('/onboarding')),
                  const SizedBox(height: 12),
                ],
                const TransferSuggestionsCard(),
                _NetWorthCard(
                  summary: s,
                  hidden: _hidden,
                  mask: _mask,
                  onToggle: () => setState(() => _hidden = !_hidden),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MiniStat(
                        label: 'Thu nhập',
                        value: _hidden ? _mask : formatVnd(s.income),
                        color: MomaColors.income,
                        icon: Symbols.south_rounded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        label: 'Chi tiêu',
                        value: _hidden ? _mask : formatVnd(s.expense),
                        color: MomaColors.expense,
                        icon: Symbols.north_east_rounded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        label: 'Tiết kiệm',
                        value: _hidden ? _mask : formatVnd(savings),
                        color: const Color(0xFF1B8A5A),
                        icon: Symbols.savings_rounded,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _RateCard(
                  rate: rate,
                  onTap: () => ref.read(shellTabProvider.notifier).select(3),
                ),
                const SizedBox(height: 12),
                const TodayMealsCard(),
                const SizedBox(height: 18),
                _Title('Thao tác nhanh'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Quick(
                      icon: Symbols.swap_horiz_rounded,
                      label: 'Giao dịch',
                      onTap: () =>
                          ref.read(shellTabProvider.notifier).select(1),
                    ),
                    _Quick(
                      icon: Symbols.auto_awesome_rounded,
                      label: 'Trợ lý AI',
                      onTap: () =>
                          ref.read(shellTabProvider.notifier).select(2),
                    ),
                    _Quick(
                      icon: Symbols.qr_code_2_rounded,
                      label: 'Nhận tiền',
                      onTap: () => context.push('/receive'),
                    ),
                    _Quick(
                      icon: Symbols.flag_rounded,
                      label: 'Mục tiêu',
                      onTap: () => context.push('/planning?tab=1'),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _Title(
                  'Tài khoản',
                  action: 'Xem tất cả',
                  onAction: () => context.push('/accounts'),
                ),
                const SizedBox(height: 8),
                if (accounts.isEmpty)
                  _Hint(
                    'Chưa có tài khoản. Hoàn tất thiết lập để thêm tài khoản đầu tiên.',
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: _card(context),
                    child: Column(
                      children: [
                        for (final (i, a) in accounts.take(4).indexed) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                AccountBadge(
                                  institution: a.institution,
                                  kind: a.kind,
                                  size: 40,
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
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        a.institution,
                                        style: TextStyle(
                                          color: context.pal.muted,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _hidden
                                      ? _mask
                                      : (a.balance == null
                                            ? 'Chưa biết'
                                            : formatVnd(a.balance!)),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (i < accounts.take(4).length - 1)
                            Divider(height: 1, color: context.pal.lineSoft),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                _Title(
                  'Giao dịch gần đây',
                  action: 'Xem tất cả',
                  onAction: () => ref.read(shellTabProvider.notifier).select(1),
                ),
                const SizedBox(height: 8),
                if (txs.isEmpty)
                  EmptyState(
                    embedded: true,
                    icon: Symbols.receipt_long_rounded,
                    title: 'Chưa có giao dịch',
                    hint: 'Giao dịch xuất hiện ở đây khi bạn ghi, nhờ Trợ lý AI hoặc khi ngân hàng đã kết nối có tiền vào, tiền ra.',
                    actionLabel: 'Ghi giao dịch đầu tiên',
                    onAction: () => context.push('/quick-entry'),
                    secondaryLabel: 'Nhờ Trợ lý AI',
                    onSecondary: () =>
                        ref.read(shellTabProvider.notifier).select(2),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: _card(context),
                    child: Column(
                      children: [
                        for (final (i, t) in txs.take(5).indexed) ...[
                          TxTile(
                            tx: t,
                            category: categories[t.categoryId],
                            account: accountById[t.accountId],
                          ),
                          if (i < txs.take(5).length - 1)
                            Divider(height: 1, color: context.pal.lineSoft),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

BoxDecoration _card(BuildContext context) => BoxDecoration(
  color: context.pal.surface,
  borderRadius: BorderRadius.circular(20),
);

class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard({
    required this.summary,
    required this.hidden,
    required this.mask,
    required this.onToggle,
  });
  final Summary summary;
  final bool hidden;
  final String mask;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final delta = summary.income - summary.expense;
    final up = delta >= 0;
    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14073D33),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: MoneyPattern(
        color: MomaColors.emerald,
        opacity: 0.08,
        lotus: false,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Tài sản ròng',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: pal.muted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkResponse(
                    radius: 16,
                    onTap: () => showInfoDialog(
                      context,
                      title: 'Tài sản ròng',
                      message: 'Tổng số dư các tài khoản cộng khoản phải thu trừ khoản phải trả. Tài khoản chưa biết số dư đầu kỳ chưa được tính.',
                    ),
                    child: Icon(
                      Symbols.help_rounded,
                      size: 17,
                      color: pal.muted,
                    ),
                  ),
                  const Spacer(),
                  InkResponse(
                    onTap: onToggle,
                    radius: 22,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: pal.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        hidden
                            ? Symbols.visibility_off_rounded
                            : Symbols.visibility_rounded,
                        size: 20,
                        color: pal.ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: pal.ink,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                  child: hidden
                      ? Text(mask)
                      : CountUp(value: summary.netWorth, builder: formatVnd),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: (up ? MomaColors.income : MomaColors.expense)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          up
                              ? Symbols.north_east_rounded
                              : Symbols.south_east_rounded,
                          size: 15,
                          color: up ? MomaColors.income : MomaColors.expense,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          hidden
                              ? mask
                              : '${up ? '+' : '-'}${formatVnd(delta.abs())}',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            color: up ? MomaColors.income : MomaColors.expense,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    'thu trừ chi tháng này',
                    style: TextStyle(fontSize: 12.5, color: pal.muted),
                  ),
                ],
              ),
              if (summary.unknownBaselines > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Chưa gồm ${summary.unknownBaselines} tài khoản chưa biết số dư đầu kỳ.',
                    style: TextStyle(color: pal.muted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: _card(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: color.withValues(alpha: 0.14),
                child: Icon(icon, size: 15, color: color),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: pal.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: pal.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RateCard extends StatelessWidget {
  const _RateCard({required this.rate, required this.onTap});
  final double rate;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final ok = rate >= 0.4;
    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Tỷ lệ tiết kiệm',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: pal.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkResponse(
                          radius: 16,
                          onTap: () => showInfoDialog(
                            context,
                            title: 'Tỷ lệ tiết kiệm',
                            message: 'Phần thu nhập tháng này còn lại sau khi trừ chi tiêu. Mục tiêu gợi ý là từ 40% trở lên.',
                          ),
                          child: Icon(
                            Symbols.help_rounded,
                            size: 16,
                            color: pal.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tiết kiệm trên thu nhập',
                      style: TextStyle(fontSize: 12.5, color: pal.muted),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (ok ? MomaColors.income : const Color(0xFFE0A100))
                                .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        ok ? 'Đạt kế hoạch' : 'Chưa đạt mục tiêu 40%',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: ok
                              ? MomaColors.income
                              : const Color(0xFFB07C00),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: rate),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => CircularProgressIndicator(
                          value: v,
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                          color: MomaColors.emerald,
                          backgroundColor: pal.tint,
                        ),
                      ),
                    ),
                    Text(
                      '${(rate * 100).round()}%',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: pal.ink,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Symbols.chevron_right_rounded, color: pal.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quick extends StatelessWidget {
  const _Quick({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                Container(
                  width: 58,
                  height: 52,
                  decoration: BoxDecoration(
                    color: pal.tint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: MomaColors.emerald, size: 26),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text, {this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: context.pal.ink,
          ),
        ),
      ),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
    ],
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: _card(context),
    child: Text(
      text,
      style: TextStyle(fontSize: 13.5, color: context.pal.muted),
    ),
  );
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.all(16),
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
            'Hoàn tất thiết lập',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Thêm tài khoản và làm theo hướng dẫn từng bước để MoMa sẵn sàng.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: MomaColors.forest,
              minimumSize: const Size(0, 46),
            ),
            child: const Text('Bắt đầu thiết lập'),
          ),
          SizedBox(
            height: 0,
            child: DecoratedBox(decoration: BoxDecoration(color: pal.bg)),
          ),
        ],
      ),
    );
  }
}

/// Guided setup opens at most once per app session.
bool _autoSetupShown = false;
