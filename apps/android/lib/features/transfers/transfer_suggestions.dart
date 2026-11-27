import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/account_presets.dart';
import '../../core/money/money.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';
import 'transfers_data.dart';

/// "dd/MM HH:mm" in local time.
String transferTimeLabel(DateTime d) =>
    '${dateLabel(d).substring(0, 5)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Home card: "Có N khoản có thể là chuyển tiền giữa tài khoản của bạn". Renders nothing while loading, on error
/// or when there is nothing to review, so it is safe to place on Home.
class TransferSuggestionsCard extends ConsumerWidget {
  const TransferSuggestionsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(transferSuggestionsProvider).value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => showTransferSuggestionsSheet(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2F80ED).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Symbols.swap_horiz_rounded,
                    color: Color(0xFF2F80ED),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Có ${list.length} khoản có thể là chuyển tiền giữa tài khoản của bạn',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: pal.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Xác nhận để không tính thành thu nhập và chi tiêu.',
                        style: TextStyle(fontSize: 12.5, color: pal.muted),
                      ),
                    ],
                  ),
                ),
                Icon(Symbols.chevron_right_rounded, color: pal.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showTransferSuggestionsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const TransferSuggestionsSheet(),
    );

/// Each pair: out account -> in account, amount, both times and texts, with Đúng / Không.
class TransferSuggestionsSheet extends ConsumerStatefulWidget {
  const TransferSuggestionsSheet({super.key});
  @override
  ConsumerState<TransferSuggestionsSheet> createState() =>
      _TransferSuggestionsSheetState();
}

class _TransferSuggestionsSheetState
    extends ConsumerState<TransferSuggestionsSheet> {
  final Set<String> _busy = {};

  Future<void> _decide(TransferPair p, bool accept) async {
    setState(() => _busy.add(p.id));
    try {
      await decideTransferSuggestion(ref, p.id, accept: accept);
      if (mounted) {
        showSnack(
          context,
          accept
              ? 'Đã ghi thành chuyển tiền giữa tài khoản.'
              : 'Đã giữ nguyên hai giao dịch.',
        );
      }
    } catch (e) {
      if (mounted) await showErrorDialog(context, transferErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list = ref.watch(transferSuggestionsProvider).value ?? const [];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              'Chuyển tiền giữa tài khoản?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: pal.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tiền ra ở một tài khoản và tiền vào ở tài khoản khác của bạn cùng số tiền, gần cùng lúc. '
              'Chọn Đúng để ghi thành một lần chuyển tiền.',
              style: TextStyle(fontSize: 13, color: pal.muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Không còn khoản nào cần xem.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: pal.muted),
                ),
              ),
            for (final p in list)
              _SuggestionTile(
                pair: p,
                busy: _busy.contains(p.id),
                onYes: () => _decide(p, true),
                onNo: () => _decide(p, false),
              ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.pair,
    required this.busy,
    required this.onYes,
    required this.onNo,
  });
  final TransferPair pair;
  final bool busy;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final o = pair.out!;
    final i = pair.inLeg!;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surfaceAlt,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _LegSide(leg: o, label: 'Tiền ra'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Symbols.arrow_forward_rounded,
                  color: pal.muted,
                  size: 20,
                ),
              ),
              Expanded(
                child: _LegSide(leg: i, label: 'Tiền vào'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            formatVnd(o.amount),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: pal.ink,
            ),
          ),
          if (o.content.isNotEmpty || i.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [o.content, i.content].where((s) => s.isNotEmpty).join('\n'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: pal.muted, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onNo,
                  child: const Text('Không'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onYes,
                  style: FilledButton.styleFrom(
                    backgroundColor: MomaColors.emerald,
                  ),
                  child: const Text('Đúng'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegSide extends StatelessWidget {
  const _LegSide({required this.leg, required this.label});
  final TransferLeg leg;
  final String label;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Row(
      children: [
        AccountBadge(
          institution: leg.institution,
          kind: leg.accountKind,
          size: 34,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                leg.accountName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: pal.ink,
                ),
              ),
              Text(
                '$label ${transferTimeLabel(leg.effectiveAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: pal.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
