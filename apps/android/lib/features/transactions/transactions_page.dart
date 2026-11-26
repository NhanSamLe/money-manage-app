import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

class TransactionsPage extends ConsumerWidget {
  const TransactionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        data: (list) {
          if (list.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 120),
                EmptyState(
                  icon: Icons.receipt_long_rounded,
                  title: 'Chưa có giao dịch',
                  hint: 'Bấm nút + để thêm giao dịch đầu tiên.',
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: list.length,
            itemBuilder: (_, i) =>
                _TxTile(tx: list[i], category: categories[list[i].categoryId]),
          );
        },
      ),
    );
  }
}

class _TxTile extends ConsumerWidget {
  const _TxTile({required this.tx, required this.category});
  final MomaTx tx;
  final Category? category;

  String get _title {
    if (tx.merchant != null && tx.merchant!.isNotEmpty) return tx.merchant!;
    if (category != null) return category!.name;
    switch (tx.kind) {
      case 'TRANSFER':
        return 'Chuyển khoản';
      case 'UNKNOWN_CREDIT':
        return 'Tiền vào chưa phân loại';
      case 'UNKNOWN_DEBIT':
        return 'Tiền ra chưa phân loại';
      case 'OPENING':
        return 'Số dư đầu kỳ';
      default:
        return 'Giao dịch';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = tx.isIncome
        ? MomaColors.income
        : (tx.isExpense ? MomaColors.expense : MomaColors.forest);
    final sign = tx.isIncome ? '+' : (tx.isExpense ? '-' : '');
    final d = tx.effectiveAt;
    final when =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        onTap: tx.isVoid ? null : () => _confirmReverse(context, ref),
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
        subtitle: Text(tx.isVoid ? '$when · Đã hủy' : when),
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

  Future<void> _confirmReverse(BuildContext context, WidgetRef ref) async {
    final reason = TextEditingController(text: 'Nhập nhầm');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hủy giao dịch này?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Giao dịch không bị xóa; MoMa tạo bút toán đảo để giữ lịch sử.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Lý do'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Giữ lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hủy giao dịch'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiProvider).command('TX_REVERSE', {
        'tx_id': tx.id,
        'reason': reason.text.trim(),
        'expected_version': tx.version,
      }, commandId: ApiClient.newId());
      refreshAll(ref);
      if (context.mounted) showSnack(context, 'Đã hủy giao dịch.');
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }
}
