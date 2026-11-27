import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/widgets.dart';
import 'transfers_data.dart';

/// Shown in the transaction detail of a transfer the server created by pairing: "Tự ghép từ 2 giao dịch" with a
/// "Tách ra" action (confirm, then undo). Renders nothing for transfers entered by hand, while loading or on error.
class TransferPairSection extends ConsumerStatefulWidget {
  const TransferPairSection({super.key, required this.txId});
  final String txId;

  @override
  ConsumerState<TransferPairSection> createState() =>
      _TransferPairSectionState();
}

class _TransferPairSectionState extends ConsumerState<TransferPairSection> {
  bool _busy = false;

  Future<void> _split(TransferPair p) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Tách ra?',
      message: p.oneLeg
          ? 'Chuyển tiền này sẽ được hủy và giao dịch gốc được ghi lại như trước. '
                'MoMa sẽ không tự ghép giao dịch này nữa.'
          : 'Chuyển tiền này sẽ được hủy và hai giao dịch gốc (tiền ra, tiền vào) được ghi lại như trước. '
                'MoMa sẽ không tự ghép hai giao dịch này nữa.',
      confirmLabel: 'Tách ra',
      cancelLabel: 'Không',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await undoTransferPair(ref, p.id);
      if (!mounted) return;
      showSnack(context, 'Đã tách thành giao dịch gốc.');
      Navigator.maybePop(context);
    } catch (e) {
      if (mounted) await showErrorDialog(context, transferErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(transferPairForTxProvider(widget.txId)).value;
    if (p == null || !p.isPaired) return const SizedBox.shrink();
    final pal = context.pal;
    final title = p.oneLeg
        ? 'Tự ghép từ 1 giao dịch'
        : 'Tự ghép từ 2 giao dịch';
    final detail = p.oneLeg
        ? 'Nội dung cho thấy tiền ${p.inLeg == null ? 'chuyển đến' : 'đến từ'} '
              '${p.synthAccountName ?? 'tài khoản khác của bạn'}, nơi không gửi thông báo cho chiều này.'
        : 'Tiền ra ở ${p.out!.accountName} và tiền vào ở ${p.inLeg!.accountName} '
              'được ghi thành một lần chuyển tiền.';
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF2F80ED).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Symbols.call_merge_rounded,
              color: Color(0xFF2F80ED),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: pal.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: pal.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (p.canUndo)
            TextButton(
              onPressed: _busy ? null : () => _split(p),
              child: const Text('Tách ra'),
            ),
        ],
      ),
    );
  }
}
