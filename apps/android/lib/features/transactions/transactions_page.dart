import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';
import 'tx_sheets.dart';

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
  bool _loadingMore = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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
      if (mounted) showSnack(context, e.message);
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
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(transactionsProvider);
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
                    matchesQuery(
                      t,
                      categories[t.categoryId]?.name,
                      _search.text,
                    ),
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Tìm giao dịch, ghi chú, danh mục...',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in const {
                    'ALL': 'Tất cả',
                    'EXPENSE': 'Chi',
                    'INCOME': 'Thu',
                    'TRANSFER': 'Chuyển',
                  }.entries)
                    ChoiceChip(
                      label: Text(e.value),
                      selected: _kind == e.key,
                      onSelected: (_) => setState(() => _kind = e.key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
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
              for (final t in shown)
                _TxTile(tx: t, category: categories[t.categoryId]),
              if (page.hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _loadingMore ? null : _loadMore,
                    child: Text(_loadingMore ? 'Đang tải...' : 'Tải thêm'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TxTile extends StatelessWidget {
  const _TxTile({required this.tx, required this.category});
  final MomaTx tx;
  final Category? category;

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
    final d = tx.effectiveAt;
    final when =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        onTap: () => showFormSheet<void>(
          context,
          (_) => TxDetailSheet(tx: tx, category: category),
        ),
        leading: CircleAvatar(
          backgroundColor: MomaColors.mint.withValues(alpha: 0.4),
          child: Icon(
            tx.kind == 'TRANSFER'
                ? Icons.swap_horiz_rounded
                : categoryIcon(category?.icon),
            color: MomaColors.forest,
          ),
        ),
        title: Text(
          _title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: tx.isVoid ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          tx.isVoid
              ? '$when · Đã hủy'
              : (tx.relatedTxId != null ? '$when · Đã sửa' : when),
        ),
        trailing: Text(
          '$sign${formatVnd(tx.amount)}',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: tx.isVoid ? MomaColors.muted : color,
          ),
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
