import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/select_field.dart';
import '../../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

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
  TxFilter _f = const TxFilter();
  bool _loadingMore = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openFilters(List<Category> cats, List<Account> accounts) async {
    final v = await showModalBottomSheet<TxFilter>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _FilterSheet(initial: _f, categories: cats, accounts: accounts),
    );
    if (v != null) setState(() => _f = v);
  }

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
    final pal = context.pal;
    final txs = ref.watch(transactionsProvider);
    final categories = {
      for (final c in ref.watch(categoriesProvider).value ?? <Category>[])
        c.id: c,
    };
    final accounts = {
      for (final a in ref.watch(accountsProvider).value ?? <Account>[]) a.id: a,
    };
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
            final base = page.items
                .where(
                  (t) =>
                      _f.copyWith(kind: 'ALL').matches(t) &&
                      matchesQuery(
                        t,
                        categories[t.categoryId]?.name,
                        _search.text,
                      ),
                )
                .toList();
            final shown = page.items
                .where(
                  (t) =>
                      _f.matches(t) &&
                      matchesQuery(
                        t,
                        categories[t.categoryId]?.name,
                        _search.text,
                      ),
                )
                .toList();
            final income = shown
                .where((t) => t.isIncome)
                .fold<int>(0, (s, t) => s + t.amount);
            final expense = shown
                .where((t) => t.isExpense)
                .fold<int>(0, (s, t) => s + t.amount);
            if (_f.oldestFirst) {
              shown.sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
            }
            final groups = _groupByDay(shown);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                // Row 1: search + one filter button (with a count badge).
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Symbols.search_rounded),
                          hintText: 'Tìm giao dịch',
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Symbols.close_rounded),
                                  onPressed: () =>
                                      setState(() => _search.clear()),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Badge(
                      isLabelVisible: _f.count > 0,
                      label: Text('${_f.count}'),
                      backgroundColor: MomaColors.emerald,
                      child: Material(
                        color: _f.count > 0 ? pal.tint : pal.surface,
                        shape: CircleBorder(
                          side: BorderSide(
                            color: _f.count > 0 ? MomaColors.emerald : pal.line,
                          ),
                        ),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _openFilters(
                            categories.values.toList(),
                            accounts.values.toList(),
                          ),
                          child: const SizedBox(
                            width: 54,
                            height: 54,
                            child: Icon(Symbols.filter_alt_rounded),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Row 2: type chips with counts (scroll sideways).
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final e in const {
                        'ALL': 'Tất cả',
                        'EXPENSE': 'Chi tiêu',
                        'INCOME': 'Thu nhập',
                        'TRANSFER': 'Chuyển khoản',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: SizedBox(
                            height: 36,
                            child: _KindChip(
                              label:
                                  '${e.value} (${base.where((t) => TxFilter(kind: e.key).matches(t)).length})',
                              active: _f.kind == e.key,
                              onTap: () =>
                                  setState(() => _f = _f.copyWith(kind: e.key)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${shown.length} giao dịch',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (_f.count > 0)
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _f = TxFilter(kind: _f.kind)),
                        icon: const Icon(
                          Symbols.filter_alt_off_rounded,
                          size: 18,
                        ),
                        label: const Text('Xóa lọc'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _TotalsCard(income: income, expense: expense),
                const SizedBox(height: 14),
                if (page.items.isEmpty)
                  const EmptyState(
                    embedded: true,
                    icon: Symbols.receipt_long_rounded,
                    title: 'Chưa có giao dịch',
                    hint: 'Bấm nút + để thêm giao dịch đầu tiên.',
                  )
                else if (shown.isEmpty)
                  const EmptyState(
                    embedded: true,
                    icon: Symbols.search_off_rounded,
                    title: 'Không có kết quả',
                    hint: 'Thử từ khóa khác hoặc bỏ bộ lọc.',
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

/// All transaction filters in one value, so the sheet can edit a copy and apply or discard it.
class TxFilter {
  const TxFilter({
    this.kind = 'ALL',
    this.period = 'ALL',
    this.from,
    this.to,
    this.categoryId = '',
    this.accountId = '',
    this.oldestFirst = false,
  });
  final bool oldestFirst;
  final String kind;
  final String period; // ALL TODAY YESTERDAY 7D 30D MONTH LAST_MONTH CUSTOM
  final DateTime? from;
  final DateTime? to;
  final String categoryId;
  final String accountId;

  static const periodLabels = {
    'ALL': 'Mọi lúc',
    'TODAY': 'Hôm nay',
    'YESTERDAY': 'Hôm qua',
    '7D': '7 ngày',
    '30D': '30 ngày',
    'MONTH': 'Tháng này',
    'LAST_MONTH': 'Tháng trước',
    'CUSTOM': 'Tùy chọn',
  };

  TxFilter copyWith({
    String? kind,
    String? period,
    DateTime? from,
    DateTime? to,
    String? categoryId,
    String? accountId,
    bool? oldestFirst,
  }) => TxFilter(
    oldestFirst: oldestFirst ?? this.oldestFirst,
    kind: kind ?? this.kind,
    period: period ?? this.period,
    from: period != null && period != 'CUSTOM' ? null : (from ?? this.from),
    to: period != null && period != 'CUSTOM' ? null : (to ?? this.to),
    categoryId: categoryId ?? this.categoryId,
    accountId: accountId ?? this.accountId,
  );

  /// Filters counted on the filter button (the type switch is visible on the page itself).
  int get count =>
      (period != 'ALL' ? 1 : 0) +
      (categoryId.isNotEmpty ? 1 : 0) +
      (accountId.isNotEmpty ? 1 : 0) +
      (oldestFirst ? 1 : 0);

  (DateTime, DateTime)? get range {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return switch (period) {
      'TODAY' => (today, today),
      'YESTERDAY' => (
        today.subtract(const Duration(days: 1)),
        today.subtract(const Duration(days: 1)),
      ),
      '7D' => (today.subtract(const Duration(days: 6)), today),
      '30D' => (today.subtract(const Duration(days: 29)), today),
      'MONTH' => (DateTime(n.year, n.month), today),
      'LAST_MONTH' => (
        DateTime(n.year, n.month - 1),
        DateTime(n.year, n.month, 0),
      ),
      'CUSTOM' when from != null && to != null => (from!, to!),
      _ => null,
    };
  }

  bool matches(MomaTx t) {
    final kindOk = switch (kind) {
      'EXPENSE' => t.isExpense,
      'INCOME' => t.isIncome,
      'TRANSFER' => t.kind == 'TRANSFER',
      _ => true,
    };
    if (!kindOk) return false;
    if (categoryId.isNotEmpty && t.categoryId != categoryId) return false;
    if (accountId.isNotEmpty && t.accountId != accountId) return false;
    final r = range;
    if (r != null) {
      final d = t.effectiveAt.toLocal();
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(r.$1) || day.isAfter(r.$2)) return false;
    }
    return true;
  }

  static String _d(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

/// One bottom sheet with every filter in clear sections; nothing applies until "Áp dụng".
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.categories,
    required this.accounts,
  });
  final TxFilter initial;
  final List<Category> categories;
  final List<Account> accounts;
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late TxFilter _f = widget.initial;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _f.from != null && _f.to != null
          ? DateTimeRange(start: _f.from!, end: _f.to!)
          : null,
    );
    if (r != null) {
      setState(
        () => _f = TxFilter(
          kind: _f.kind,
          period: 'CUSTOM',
          from: r.start,
          to: r.end,
          categoryId: _f.categoryId,
          accountId: _f.accountId,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final cats = widget.categories.where((c) => c.parentId == null).toList();
    final custom = _f.period == 'CUSTOM' && _f.from != null && _f.to != null;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: [
                const SizedBox(width: 96),
                const Expanded(
                  child: Text(
                    'Bộ lọc',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                SizedBox(
                  width: 104,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _f = TxFilter(kind: _f.kind)),
                    icon: const Icon(Symbols.filter_alt_off_rounded, size: 18),
                    label: const Text('Xóa lọc'),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: pal.lineSoft),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PickField<String>(
                    key: ValueKey('period-${_f.period}-${_f.from}'),
                    initialValue: _f.period,
                    optional: true,
                    icon: Symbols.calendar_month_rounded,
                    decoration: const InputDecoration(labelText: 'Thời gian'),
                    items: [
                      for (final e in TxFilter.periodLabels.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            e.key != 'CUSTOM'
                                ? e.value
                                : (custom
                                      ? '${TxFilter._d(_f.from!)} - ${TxFilter._d(_f.to!)}'
                                      : 'Chọn khoảng ngày'),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == 'CUSTOM') {
                        _pickRange();
                      } else if (v != null) {
                        setState(() => _f = _f.copyWith(period: v));
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: PickField<String>(
                          key: ValueKey('kind-${_f.kind}'),
                          initialValue: _f.kind,
                          optional: true,
                          decoration: const InputDecoration(labelText: 'Loại'),
                          items: const [
                            DropdownMenuItem(
                              value: 'ALL',
                              child: Text('Tất cả'),
                            ),
                            DropdownMenuItem(
                              value: 'EXPENSE',
                              child: Text('Chi tiêu'),
                            ),
                            DropdownMenuItem(
                              value: 'INCOME',
                              child: Text('Thu nhập'),
                            ),
                            DropdownMenuItem(
                              value: 'TRANSFER',
                              child: Text('Chuyển khoản'),
                            ),
                          ],
                          onChanged: (v) => setState(
                            () => _f = _f.copyWith(kind: v ?? 'ALL'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PickField<bool>(
                          key: ValueKey('sort-${_f.oldestFirst}'),
                          initialValue: _f.oldestFirst,
                          optional: true,
                          decoration: const InputDecoration(
                            labelText: 'Sắp xếp',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: false,
                              child: Text('Mới nhất'),
                            ),
                            DropdownMenuItem(
                              value: true,
                              child: Text('Cũ nhất'),
                            ),
                          ],
                          onChanged: (v) => setState(
                            () => _f = _f.copyWith(oldestFirst: v ?? false),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  PickField<String>(
                    key: ValueKey('cat-${_f.categoryId}'),
                    initialValue: _f.categoryId,
                    optional: true,
                    icon: Symbols.sell_rounded,
                    decoration: const InputDecoration(labelText: 'Danh mục'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Tất cả danh mục'),
                      ),
                      for (final c in cats)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) =>
                        setState(() => _f = _f.copyWith(categoryId: v ?? '')),
                  ),
                  const SizedBox(height: 16),
                  PickField<String>(
                    key: ValueKey('acc-${_f.accountId}'),
                    initialValue: _f.accountId,
                    optional: true,
                    icon: Symbols.account_balance_wallet_rounded,
                    decoration: const InputDecoration(labelText: 'Tài khoản'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Tất cả tài khoản'),
                      ),
                      for (final a in widget.accounts)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) =>
                        setState(() => _f = _f.copyWith(accountId: v ?? '')),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: ActionButtons(
              primaryLabel: 'Áp dụng',
              onPrimary: () => Navigator.pop(context, _f),
              secondaryLabel: 'Đóng',
              onSecondary: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: active ? MomaColors.emerald : context.pal.surface,
    shape: StadiumBorder(
      side: BorderSide(color: active ? MomaColors.emerald : context.pal.line),
    ),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : context.pal.ink,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Income, spending and the difference of the filtered list in one card.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.income, required this.expense});
  final int income;
  final int expense;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final net = income - expense;
    final sign = net >= 0 ? '+' : '-';
    Widget col(String label, String value, Color color) => Expanded(
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: pal.muted)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
    Widget sep() => Container(width: 1, height: 32, color: pal.line);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          col('Thu nhập', '+${formatVnd(income)}', MomaColors.income),
          sep(),
          col('Chi tiêu', '-${formatVnd(expense)}', MomaColors.expense),
          sep(),
          col('Chênh lệch', '$sign${formatVnd(net.abs())}', pal.ink),
        ],
      ),
    );
  }
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
      onTap: () => context.push('/tx/${tx.id}', extra: tx),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            tx.kind == 'TRANSFER'
                ? const CategoryAvatar(
                    iconData: Symbols.swap_horiz_rounded,
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
