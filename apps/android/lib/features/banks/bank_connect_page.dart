import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';

class BankAccountInfo {
  BankAccountInfo(this.j);
  final Map<String, dynamic> j;
  String get id => '${j['external_id']}';
  String get bank => '${j['bank']}';
  String get holder => '${j['holder']}';
  String get masked => '${j['number_masked']}';
  int get balance => parseVnd('${j['balance']}');
  bool get linked => j['linked'] == true;
  String get label => '${j['label'] ?? ''}';
}

/// Real bank accounts that SePay has verified with the bank. MoMa can only link accounts listed here, so a number
/// can never be typed in by hand, and the holder name shown comes from the bank.
final bankAccountsProvider = FutureProvider.autoDispose<List<BankAccountInfo>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/banks/sepay/accounts');
  return [
    for (final a in (data as List))
      BankAccountInfo(Map<String, dynamic>.from(a as Map)),
  ];
});

class BankConnectPage extends ConsumerStatefulWidget {
  const BankConnectPage({super.key});
  @override
  ConsumerState<BankConnectPage> createState() => _BankConnectPageState();
}

class _BankConnectPageState extends ConsumerState<BankConnectPage> {
  String? _busyId;
  bool _syncing = false;

  Future<void> _link(BankAccountInfo a) async {
    setState(() => _busyId = a.id);
    try {
      await ref.read(apiProvider).post('/banks/sepay/link', {
        'external_id': a.id,
      });
      refreshAll(ref);
      ref.invalidate(bankAccountsProvider);
      if (mounted) showSnack(context, 'Đã kết nối ${a.bank} ${a.masked}');
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final r =
          await ref
                  .read(apiProvider)
                  .post('/banks/sepay/sync', <String, dynamic>{})
              as Map;
      refreshAll(ref);
      if (mounted) {
        final n = r['applied'] as int? ?? 0;
        showSnack(
          context,
          n == 0
              ? 'Không có giao dịch mới'
              : 'Đã nhận $n giao dịch mới từ ngân hàng',
        );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list = ref.watch(bankAccountsProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Kết nối ngân hàng',
        showBack: true,
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(bankAccountsProvider),
          ),
          data: (accounts) {
            if (accounts.isEmpty) {
              return EmptyState(
                icon: Symbols.account_balance_rounded,
                title: 'Chưa có tài khoản ngân hàng',
                hint: 'Thêm tài khoản của bạn trong SePay (my.sepay.vn, mục Tài khoản ngân hàng) và xác minh bằng mã OTP của ngân hàng. Xong, bấm Làm mới để MoMa lấy về số dư và giao dịch tự động.',
                actionLabel: 'Làm mới',
                onAction: () => ref.invalidate(bankAccountsProvider),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: pal.tintSoft,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Symbols.verified_user_rounded,
                        color: MomaColors.emerald,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Các tài khoản dưới đây đã được ngân hàng xác minh qua SePay. Khi kết nối, MoMa lấy đúng số dư hiện tại và tự ghi mọi khoản tiền vào, tiền ra.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: pal.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                for (final a in accounts)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: pal.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: MomaColors.emerald.withValues(
                                alpha: 0.14,
                              ),
                              child: const Icon(
                                Symbols.account_balance_rounded,
                                color: MomaColors.emerald,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.bank,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                      color: pal.ink,
                                    ),
                                  ),
                                  Text(
                                    '${a.masked}  ${a.holder}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: pal.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Số dư tại ngân hàng',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: pal.muted,
                                ),
                              ),
                            ),
                            Text(
                              formatVnd(a.balance),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (a.linked)
                          Row(
                            children: [
                              const Icon(
                                Symbols.check_circle_rounded,
                                color: MomaColors.income,
                                fill: 1,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Đã kết nối với MoMa',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: pal.ink,
                                ),
                              ),
                            ],
                          )
                        else
                          ActionButtons(
                            primaryLabel: 'Kết nối với MoMa',
                            onPrimary: () => _link(a),
                            busy: _busyId == a.id,
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: _syncing ? null : _sync,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.sync_rounded),
                  label: const Text('Đồng bộ giao dịch ngay'),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => context.push('/receive'),
                    child: const Text('Nhận tiền bằng mã QR'),
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
