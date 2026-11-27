import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/sheets.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import 'tx_sheets.dart';
import '../../app/theme/palette.dart';

/// Case- and diacritic-insensitive match over merchant, note and category name.
bool matchesQuery(MomaTx t, String? categoryName, String query) {
  final q = foldVietnamese(query.trim());
  if (q.isEmpty) return true;
  final hay = foldVietnamese(
    '${t.merchant ?? ''} ${t.note ?? ''} ${categoryName ?? ''}',
  );
  return hay.contains(q);
}

class TransactionsPage extends ConsumerStatefulWidget {
  const TransactionsPage({super.key});
  @override
  ConsumerState<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends ConsumerState<TransactionsPage> {
  final _search = TextEditingController();
  String _kind = 'ALL';
  String _period = 'ALL';
  String _categoryId = '';
  bool _loadingMore = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _periodMatches(MomaTx t) {
    final d = t.effectiveAt.toLocal();
    final now = DateTime.now();
    return switch (_period) {
      'MONTH' => d.year == now.year && d.month == now.month,
      'LAST_MONTH' =>
        d.year == DateTime(now.year, now.month - 1).year &&
            d.month == DateTime(now.year, now.month - 1).month,
      '7D' => now.difference(d).inDays < 7 && !d.isAfter(now),
      _ => true,
    };
  }

  static const _kindLabels = {
    'ALL': 'Tất cả',
    'EXPENSE': 'Chi tiêu',
    'INCOME': 'Thu nhập',
    'TRANSFER': 'Chuyển khoản',
  };
  static const _periodLabels = {
    'ALL': 'Mọi thời gian',
    'MONTH': 'Tháng này',
    'LAST_MONTH': 'Tháng trước',
    '7D': '7 ngày qua',
  };

  Future<void> _pickKind() async {
    final v = await showChoiceSheet<String>(
      context,
      title: 'Loại giao dịch',
      selected: _kind,
      options: const [
        ChoiceOption(value: 'ALL', label: 'Tất cả', icon: Icons.apps_rounded),
        ChoiceOption(
          value: 'EXPENSE',
          label: 'Chi tiêu',
          icon: Icons.north_east_rounded,
        ),
        ChoiceOption(
          value: 'INCOME',
          label: 'Thu nhập',
          icon: Icons.south_west_rounded,
        ),
        ChoiceOption(
          value: 'TRANSFER',
          label: 'Chuyển khoản',
          icon: Icons.swap_horiz_rounded,
        ),
      ],
    );
    if (v != null) setState(() => _kind = v);
  }

  Future<void> _pickPeriod() async {
    final v = await showChoiceSheet<String>(
      context,
      title: 'Thời gian',
      selected: _period,
      options: const [
        ChoiceOption(
          value: 'ALL',
          label: 'Mọi thời gian',
          icon: Icons.all_inclusive_rounded,
        ),
        ChoiceOption(
          value: 'MONTH',
          label: 'Tháng này',
          icon: Icons.calendar_month_outlined,
        ),
        ChoiceOption(
          value: 'LAST_MONTH',
          label: 'Tháng trước',
          icon: Icons.history_rounded,
        ),
        ChoiceOption(
          value: '7D',
          label: '7 ngày qua',
          icon: Icons.date_range_outlined,
        ),
      ],
      footnote: 'Lọc trong các giao dịch đã tải. Kéo xuống để tải thêm.',
    );
    if (v != null) setState(() => _period = v);
  }

  Future<void> _pickCategory(List<Category> cats) async {
    final v = await showChoiceSheet<String>(
      context,
      title: 'Danh mục',
      selected: _categoryId,
      options: [
        const ChoiceOption(
          value: '',
          label: 'Tất cả danh mục',
          icon: Icons.apps_rounded,
        ),
        for (final c in cats)
          ChoiceOption(
            value: c.id,
            label: c.name,
            leading: CategoryAvatar(iconKey: c.icon, size: 32),
          ),
      ],
    );
    if (v != null) setState(() => _categoryId = v);
  }

  bool get _filtering =>
      _kind != 'ALL' || _period != 'ALL' || _categoryId.isNotEmpty;

  bool _kindMatches(MomaTx t) => switch (_kind) {
    'EXPENSE' => t.isExpense,
    'INCOME' => t.isIncome,
    'TRANSFER' => t.kind == 'TRANSFER',
    _ => true,
  };

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      await ref.read(transactionsProvider.notifier).loadMore();
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final txs = ref.watch(transactionsProvider);
    final categories = {
      for (final c in ref.watch(categoriesProvider).value ?? <Category>[])
        c.id: c,
    };
    final accounts = {
      for (final a in ref.watch(accountsProvider).value ?? <Account>[]) a.id: a,
    };
    final summary = ref.watch(summaryProvider).value;
    return MomaPage(
      title: 'Giao dịch',
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(transactionsProvider);
          ref.invalidate(summaryProvider);
          await ref.read(transactionsProvider.future);
        },
        child: txs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(transactionsProvider),
          ),
          data: (page) {
            final shown = page.items
                .where(
                  (t) =>
                      _kindMatches(t) &&
                      _periodMatches(t) &&
                      (_categoryId.isEmpty || t.categoryId == _categoryId) &&
                      matchesQuery(
                        t,
                        categories[t.categoryId]?.name,
                        _search.text,
                      ),
                )
                .toList();
            final groups = _groupByDay(shown);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.pal.surface,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14073D33),
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText:
                              'Tìm giao dịch (ví dụ: ăn uống, chuyển khoản...)',
                        ),
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _FilterChip(
                              icon: Icons.check_rounded,
                              label: 'Tất cả',
                              active: !_filtering,
                              onTap: () => setState(() {
                                _kind = 'ALL';
                                _period = 'ALL';
                                _categoryId = '';
                              }),
                            ),
                            _FilterChip(
                              icon: Icons.swap_vert_rounded,
                              label: _kind == 'ALL'
                                  ? 'Loại'
                                  : _kindLabels[_kind]!,
                              active: _kind != 'ALL',
                              dropdown: true,
                              onTap: _pickKind,
                            ),
                            _FilterChip(
                              icon: Icons.calendar_month_outlined,
                              label: _period == 'ALL'
                                  ? 'Thời gian'
                                  : _periodLabels[_period]!,
                              active: _period != 'ALL',
                              dropdown: true,
                              onTap: _pickPeriod,
                            ),
                            _FilterChip(
                              icon: Icons.sell_outlined,
                              label: _categoryId.isEmpty
                                  ? 'Danh mục'
                                  : (categories[_categoryId]?.name ??
                                        'Danh mục'),
                              active: _categoryId.isNotEmpty,
                              dropdown: true,
                              onTap: () => _pickCategory(
                                categories.values
                                    .where((c) => c.parentId == null)
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (summary != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _SumTile(
                                label: 'Thu nhập',
                                value: '+${formatVnd(summary.income)}',
                                color: MomaColors.income,
                                icon: Icons.south_rounded,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SumTile(
                                label: 'Chi tiêu',
                                value: '-${formatVnd(summary.expense)}',
                                color: MomaColors.expense,
                                icon: Icons.north_east_rounded,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (page.items.isEmpty)
                  const SizedBox(
                    height: 260,
                    child: EmptyState(
                      icon: Icons.receipt_long_rounded,
                      title: 'Chưa có giao dịch',
                      hint: 'Bấm nút + để thêm giao dịch đầu tiên.',
                    ),
                  )
                else if (shown.isEmpty)
                  const SizedBox(
                    height: 200,
                    child: EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'Không có kết quả',
                      hint: 'Thử từ khóa khác hoặc bỏ bộ lọc.',
                    ),
                  ),
                for (final g in groups) ...[
                  _DayCard(
                    group: g,
                    categories: categories,
                    accounts: accounts,
                  ),
                  const SizedBox(height: 12),
                ],
                if (page.hasMore)
                  OutlinedButton(
                    onPressed: _loadingMore ? null : _loadMore,
                    child: Text(_loadingMore ? 'Đang tải...' : 'Tải thêm'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.dropdown = false,
  });
  final IconData icon;
  final String label;
  final bool active;
  final bool dropdown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Material(
      color: active ? context.pal.tint : Colors.white,
      shape: StadiumBorder(
        side: BorderSide(color: active ? MomaColors.emerald : context.pal.line),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: active ? MomaColors.emerald : context.pal.muted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: active ? MomaColors.forest : context.pal.ink,
                ),
              ),
              if (dropdown) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: active ? MomaColors.emerald : context.pal.muted,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _DayGroup {
  _DayGroup(this.day);
  final DateTime day;
  final items = <MomaTx>[];
  int get income => items
      .where((t) => t.isIncome && !t.isVoid)
      .fold(0, (a, t) => a + t.amount);
  int get expense => items
      .where((t) => t.isExpense && !t.isVoid)
      .fold(0, (a, t) => a + t.amount);
}

List<_DayGroup> _groupByDay(List<MomaTx> txs) {
  final out = <_DayGroup>[];
  for (final t in txs) {
    final d = t.effectiveAt.toLocal();
    final day = DateTime(d.year, d.month, d.day);
    if (out.isEmpty || out.last.day != day) out.add(_DayGroup(day));
    out.last.items.add(t);
  }
  return out;
}

String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hôm nay';
  if (diff == 1) return 'Hôm qua';
  return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}';
}

class _SumTile extends StatelessWidget {
  const _SumTile({
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: context.pal.muted, fontSize: 12),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyle(
                    color: context.pal.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    height: 1.2,
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

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.group,
    required this.categories,
    required this.accounts,
  });
  final _DayGroup group;
  final Map<String, Category> categories;
  final Map<String, Account> accounts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        color: context.pal.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _dayLabel(group.day),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
              const Spacer(),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(fontSize: 12, color: context.pal.muted),
                      children: [
                        const TextSpan(text: 'Thu: '),
                        TextSpan(
                          text: '+${formatVnd(group.income)}',
                          style: const TextStyle(
                            color: MomaColors.income,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const TextSpan(text: '  |  Chi: '),
                        TextSpan(
                          text: '-${formatVnd(group.expense)}',
                          style: const TextStyle(
                            color: MomaColors.expense,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < group.items.length; i++) ...[
            TxTile(
              tx: group.items[i],
              category: categories[group.items[i].categoryId],
              account: accounts[group.items[i].accountId],
            ),
            if (i < group.items.length - 1)
              Divider(height: 1, color: context.pal.lineSoft),
          ],
        ],
      ),
    );
  }
}

class TxTile extends StatelessWidget {
  const TxTile({
    super.key,
    required this.tx,
    required this.category,
    this.account,
  });
  final MomaTx tx;
  final Category? category;
  final Account? account;

  String get _title {
    if (tx.merchant != null && tx.merchant!.isNotEmpty) return tx.merchant!;
    if (category != null) return category!.name;
    return txKindLabel(tx.kind);
  }

  @override
  Widget build(BuildContext context) {
    final color = tx.isIncome
        ? MomaColors.income
        : (tx.isExpense ? MomaColors.expense : MomaColors.forest);
    final sign = tx.isIncome ? '+' : (tx.isExpense ? '-' : '');
    final d = tx.effectiveAt.toLocal();
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final parts = <String>[
      time,
      if (account != null) account!.name,
      if (tx.isVoid) 'Đã hủy' else if (tx.relatedTxId != null) 'Đã sửa',
    ];
    return InkWell(
      onTap: () => showFormSheet<void>(
        context,
        (_) => TxDetailSheet(tx: tx, category: category),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            tx.kind == 'TRANSFER'
                ? const CategoryAvatar(
                    iconData: Icons.swap_horiz_rounded,
                    color: Color(0xFF2F80ED),
                  )
                : CategoryAvatar(iconKey: category?.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      decoration: tx.isVoid ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    parts.join(' • '),
                    style: TextStyle(color: context.pal.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$sign${formatVnd(tx.amount)}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: tx.isVoid ? context.pal.muted : color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String txKindLabel(String kind) {
  switch (kind) {
    case 'TRANSFER':
      return 'Chuyển khoản';
    case 'UNKNOWN_CREDIT':
      return 'Tiền vào chưa phân loại';
    case 'UNKNOWN_DEBIT':
      return 'Tiền ra chưa phân loại';
    case 'OPENING':
      return 'Số dư đầu kỳ';
    case 'LOAN_GIVEN':
      return 'Cho vay';
    case 'LOAN_RECEIVED':
      return 'Đi vay';
    case 'LOAN_COLLECTED':
      return 'Thu nợ';
    case 'LOAN_REPAID':
      return 'Trả nợ';
    case 'DEBT_WRITEOFF':
      return 'Xóa nợ phải thu';
    case 'DEBT_FORGIVEN':
      return 'Được xóa nợ';
    default:
      return 'Giao dịch';
  }
}
