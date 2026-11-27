import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/header.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'bank_connect_page.dart';
import 'qr_share.dart';

/// "Nhận tiền": a VietQR for one of the owner's real, linked bank accounts. Any banking app can scan it and the
/// transfer arrives in MoMa automatically through the bank connection.
class ReceivePage extends ConsumerStatefulWidget {
  const ReceivePage({super.key});
  @override
  ConsumerState<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends ConsumerState<ReceivePage> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _externalId;
  String? _payload;
  final _qrKey = GlobalKey();
  Map<String, dynamic>? _info;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _make(String externalId) async {
    setState(() {
      _busy = true;
      _externalId = externalId;
    });
    try {
      final amount = parseVndInput(_amount.text);
      final r =
          await ref
                  .read(apiProvider)
                  .get(
                    '/banks/sepay/qr',
                    query: {
                      'external_id': externalId,
                      if (amount != null && amount > 0) 'amount': '$amount',
                      if (_note.text.trim().isNotEmpty)
                        'note': _note.text.trim(),
                    },
                  )
              as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _payload = '${r['payload']}';
          _info = r;
        });
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final banks = ref.watch(bankAccountsProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Nhận tiền',
        showBack: true,
        child: banks.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(bankAccountsProvider),
          ),
          data: (all) {
            final linked = all.where((a) => a.linked).toList();
            if (linked.isEmpty) {
              return EmptyState(
                icon: Symbols.qr_code_2_rounded,
                title: 'Chưa có tài khoản để nhận tiền',
                hint: 'Kết nối một tài khoản ngân hàng thật để tạo mã QR nhận tiền.',
                actionLabel: 'Kết nối ngân hàng',
                onAction: () => context.push('/banks'),
              );
            }
            final selected = linked.firstWhere(
              (a) => a.id == _externalId,
              orElse: () => linked.first,
            );
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (linked.length > 1) ...[
                  PickField<String>(
                    initialValue: selected.id,
                    decoration: const InputDecoration(
                      labelText: 'Tài khoản nhận',
                    ),
                    items: [
                      for (final a in linked)
                        DropdownMenuItem(
                          value: a.id,
                          child: Text('${a.bank} ${a.masked}'),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _externalId = v;
                      _payload = null;
                    }),
                  ),
                  const SizedBox(height: 16),
                ],
                MoneyField(
                  controller: _amount,
                  hint: 'Số tiền',
                  optional: true,
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Nội dung',
                  hint: 'Nhập nội dung chuyển khoản',
                  controller: _note,
                  maxLength: 50,
                ),
                const SizedBox(height: 16),
                ActionButtons(
                  primaryLabel: _payload == null
                      ? 'Tạo mã QR'
                      : 'Cập nhật mã QR',
                  onPrimary: () => _make(selected.id),
                  busy: _busy,
                ),
                if (_payload != null) ...[
                  const SizedBox(height: 20),
                  Builder(
                    builder: (context) {
                      final acc =
                          vietQrAccountNumber(_payload!) ??
                          '${_info?['number_masked']}';
                      final amount = parseVndInput(_amount.text);
                      final share =
                          '${_info?['bank']} - $acc - ${_info?['holder']}';
                      return Column(
                        children: [
                          ReceiveQrCard(
                            boundaryKey: _qrKey,
                            payload: _payload!,
                            bank: '${_info?['bank']}',
                            holder: '${_info?['holder']}',
                            accountNumber: acc,
                            amount: amount,
                            note: _note.text,
                            onTapQr: () => showQrActions(
                              context,
                              boundaryKey: _qrKey,
                              accountNumber: acc,
                              payload: _payload!,
                              shareText: share,
                            ),
                          ),
                          const SizedBox(height: 12),
                          QrActionRow(
                            onCopyAccount: () => copyText(
                              context,
                              acc,
                              'Đã sao chép số tài khoản',
                            ),
                            onSave: () => saveQrImage(context, _qrKey),
                            onShare: () =>
                                shareQrImage(context, _qrKey, text: share),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Người chuyển quét mã bằng ứng dụng ngân hàng hoặc ví bất kỳ. Tiền về tài khoản của bạn và MoMa tự ghi nhận.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: pal.muted,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
