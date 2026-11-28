import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/brands/brand_registry.dart';
import '../../core/brands/person_avatar.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/vietqr.dart';
import '../../core/widgets.dart';
import '../banks/bank_connect_page.dart' show bankAccountsProvider;
import '../banks/qr_share.dart' show renderReceiveCard, vietQrAccountNumber;
import '../goals/goal_insights.dart' show goalsBoardProvider;

// Debt collection + self-running goals (API migration 019, D-025): polite reminders with a QR of the exact amount,
// one-tap confirmation of repayments MoMa recognised, "Trả ngay" for what the owner owes, and goal proposals.

int _money(Object? v) => int.tryParse('${v ?? 0}') ?? 0;

class CreditorBank {
  const CreditorBank({
    required this.bank,
    required this.accountNumber,
    this.bin,
    this.holder,
  });
  factory CreditorBank.fromJson(Map<String, dynamic> j) => CreditorBank(
    bank: '${j['bank']}',
    bin: j['bin'] as String?,
    accountNumber: '${j['account_number']}',
    holder: j['holder'] as String?,
  );
  final String bank;
  final String? bin;
  final String accountNumber;
  final String? holder;
}

/// One debt's reminder as the server prepared it (message, memo code, tone, creditor bank).
class Reminder {
  const Reminder({
    required this.debtId,
    required this.direction,
    required this.alias,
    required this.contactId,
    required this.remaining,
    required this.memo,
    required this.message,
    required this.tone,
    required this.remindCount,
    this.note,
    this.dueDate,
    this.overdueDays = 0,
    this.bank,
  });
  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
    debtId: '${j['debt_id']}',
    direction: '${j['direction']}',
    alias: '${j['contact_alias']}',
    contactId: '${j['contact_id']}',
    remaining: _money(j['remaining']),
    memo: '${j['memo'] ?? ''}',
    message: '${j['message'] ?? ''}',
    tone: '${j['tone'] ?? 'first'}',
    remindCount: (j['remind_count'] as num?)?.toInt() ?? 0,
    note: j['note'] as String?,
    dueDate: j['due_date'] as String?,
    overdueDays: (j['overdue_days'] as num?)?.toInt() ?? 0,
    bank: j['contact_bank'] is Map
        ? CreditorBank.fromJson(
            (j['contact_bank'] as Map).cast<String, dynamic>(),
          )
        : null,
  );
  final String debtId;
  final String direction;
  final String alias;
  final String contactId;
  final int remaining;
  final String memo;
  final String message;
  final String tone;
  final int remindCount;
  final String? note;
  final String? dueDate;
  final int overdueDays;
  final CreditorBank? bank;
  bool get receivable => direction == 'RECEIVABLE';
}

final debtReminderProvider = FutureProvider.autoDispose
    .family<Reminder, String>((ref, id) async {
      final j = await ref.watch(apiProvider).get('/debts/$id/reminder');
      return Reminder.fromJson((j as Map).cast<String, dynamic>());
    });

/// Reminders due today (receivables to nudge, payables due soon). Never fails the screens that show it.
final dueRemindersProvider = FutureProvider.autoDispose<List<Reminder>>((
  ref,
) async {
  try {
    final j = await ref.watch(apiProvider).get('/debts/reminders');
    return [
      for (final e in (j as List))
        Reminder.fromJson((e as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    return const [];
  }
});

/// A repayment MoMa recognised in incoming / outgoing money.
class Settlement {
  const Settlement({
    required this.id,
    required this.state,
    required this.amount,
    required this.alias,
    required this.direction,
    required this.debtId,
    required this.moneyTxId,
    required this.remaining,
    this.repayTxId,
    this.accountName,
    this.moneyNote,
    this.at,
    this.canUndo = false,
  });
  factory Settlement.fromJson(Map<String, dynamic> j) {
    final d = (j['debt'] as Map).cast<String, dynamic>();
    final m = (j['money'] as Map).cast<String, dynamic>();
    return Settlement(
      id: '${j['id']}',
      state: '${j['state']}',
      amount: _money(j['amount']),
      alias: '${d['contact_alias']}',
      direction: '${d['direction']}',
      debtId: '${d['id']}',
      remaining: _money(d['remaining']),
      moneyTxId: '${m['tx_id']}',
      repayTxId: j['repay_tx_id'] as String?,
      accountName: m['account_name'] as String?,
      moneyNote: m['note'] as String?,
      at: DateTime.tryParse('${m['effective_at']}')?.toLocal(),
      canUndo: j['can_undo'] == true,
    );
  }
  final String id;
  final String state;
  final int amount;
  final String alias;
  final String direction;
  final String debtId;
  final String moneyTxId;
  final int remaining;
  final String? repayTxId;
  final String? accountName;
  final String? moneyNote;
  final DateTime? at;
  final bool canUndo;
  bool get receivable => direction == 'RECEIVABLE';
  String get question => receivable
      ? 'Có phải $alias trả nợ ${formatVnd(amount)}?'
      : 'Có phải bạn trả $alias ${formatVnd(amount)}?';
}

final collectSuggestionsProvider = FutureProvider.autoDispose<List<Settlement>>(
  (ref) async {
    try {
      final j = await ref.watch(apiProvider).get('/collect/suggestions');
      return [
        for (final e in (j as List))
          Settlement.fromJson((e as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  },
);

final txSettlementProvider = FutureProvider.autoDispose
    .family<Settlement?, String>((ref, txId) async {
      try {
        final j = await ref
            .watch(apiProvider)
            .get('/transactions/$txId/collect');
        return j is Map ? Settlement.fromJson(j.cast<String, dynamic>()) : null;
      } catch (_) {
        return null;
      }
    });

class GoalProposal {
  const GoalProposal({
    required this.id,
    required this.goalName,
    required this.amount,
    required this.reason,
    required this.accountName,
    required this.allocated,
    required this.target,
  });
  factory GoalProposal.fromJson(Map<String, dynamic> j) => GoalProposal(
    id: '${j['id']}',
    goalName: '${j['goal_name']}',
    amount: _money(j['amount']),
    reason: '${j['reason']}',
    accountName: '${j['account_name']}',
    allocated: _money(j['allocated']),
    target: _money(j['target']),
  );
  final String id;
  final String goalName;
  final int amount;
  final String reason;
  final String accountName;
  final int allocated;
  final int target;
  String get title => 'Trích ${formatVnd(amount)} vào "$goalName"?';
  String get why => reason == 'MONTH_END'
      ? 'Tháng này bạn chi ít hơn dự kiến · từ $accountName'
      : 'Tiền lớn vừa về · từ $accountName';
}

final goalProposalsProvider = FutureProvider.autoDispose<List<GoalProposal>>((
  ref,
) async {
  try {
    final j = await ref.watch(apiProvider).get('/goals/proposals');
    return [
      for (final e in (j as List))
        GoalProposal.fromJson((e as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    return const [];
  }
});

class GoalPlanItem {
  const GoalPlanItem({
    required this.id,
    required this.name,
    this.requiredMonthly,
    this.eta,
    this.onTrack,
    this.pct = 0,
  });
  factory GoalPlanItem.fromJson(Map<String, dynamic> j) => GoalPlanItem(
    id: '${j['id']}',
    name: '${j['name']}',
    requiredMonthly: j['required_monthly'] == null
        ? null
        : _money(j['required_monthly']),
    eta: DateTime.tryParse('${j['eta']}'),
    onTrack: j['on_track'] as bool?,
    pct: (j['pct'] as num?)?.toInt() ?? 0,
  );
  final String id;
  final String name;
  final int? requiredMonthly;
  final DateTime? eta;
  final bool? onTrack;
  final int pct;

  /// "Cần 2.100.000đ/tháng · Dự kiến xong 05/2027 · Đúng tiến độ".
  String get line => [
    if (requiredMonthly != null && requiredMonthly! > 0)
      'Cần ${formatVnd(requiredMonthly!)}/tháng',
    if (eta != null && pct < 100)
      'Dự kiến xong ${eta!.month.toString().padLeft(2, '0')}/${eta!.year}',
    if (onTrack == true) 'Đúng tiến độ',
    if (onTrack == false) 'Đang chậm',
  ].join(' · ');
}

final goalPlanProvider = FutureProvider.autoDispose<List<GoalPlanItem>>((
  ref,
) async {
  try {
    final j = await ref.watch(apiProvider).get('/goals/plan');
    return [
      for (final e in (j as List))
        GoalPlanItem.fromJson((e as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    return const [];
  }
});

void refreshCollect(WidgetRef ref) {
  refreshPlanning(ref);
  ref.invalidate(collectSuggestionsProvider);
  ref.invalidate(dueRemindersProvider);
  ref.invalidate(goalProposalsProvider);
  ref.invalidate(goalPlanProvider);
  ref.invalidate(goalsBoardProvider);
}

// ---------------------------------------------------------------- reminder

/// Opens the reminder (receivable: message + QR → share; payable: creditor's bank / QR → pay).
Future<void> openReminder(BuildContext context, String debtId) =>
    showFormSheet<void>(context, (_) => ReminderPanel(debtId: debtId));

/// Full-screen variant for push notifications (route /debts/remind/:id).
class ReminderPage extends StatelessWidget {
  const ReminderPage({super.key, required this.debtId});
  final String debtId;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nhắc nợ')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: ReminderPanel(debtId: debtId),
    ),
  );
}

/// The owner's receiving QR for [amount] with [memo] (online: the server's VietQR; offline: rebuilt on the phone).
Future<({String payload, String bank, String holder})?> ownerQr(
  WidgetRef ref,
  int amount,
  String memo,
) async {
  final api = ref.read(apiProvider);
  final banks = await ref
      .read(bankAccountsProvider.future)
      .catchError((_) => const <Never>[]);
  final linked = banks.where((b) => b.linked).toList();
  if (linked.isEmpty) return null;
  final a = linked.first;
  Map<String, dynamic> r;
  try {
    r = (await api.get(
      '/banks/sepay/qr',
      query: {'external_id': a.id, 'amount': '$amount', 'note': memo},
    ) as Map).cast<String, dynamic>();
  } on ApiException catch (e) {
    if (e.code != 'OFFLINE') rethrow;
    final base = (await api.get(
      '/banks/sepay/qr',
      query: {'external_id': a.id},
    ) as Map).cast<String, dynamic>();
    final p = vietQrWithAmount(
      '${base['payload']}',
      amount: amount,
      note: memo,
    );
    if (p == null) return null;
    r = {...base, 'payload': p};
  }
  return (
    payload: '${r['payload']}',
    bank: '${r['bank'] ?? a.bank}',
    holder: '${r['holder'] ?? a.holder}',
  );
}

class ReminderPanel extends ConsumerStatefulWidget {
  const ReminderPanel({super.key, required this.debtId});
  final String debtId;
  @override
  ConsumerState<ReminderPanel> createState() => _ReminderPanelState();
}

class _ReminderPanelState extends ConsumerState<ReminderPanel> {
  final _message = TextEditingController();
  String? _loadedFor;
  Future<Uint8List?>? _card;
  bool _busy = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<Uint8List?> _buildCard(Reminder r) async {
    try {
      final q = await ownerQr(ref, r.remaining, r.memo);
      if (q == null) return null;
      return await renderReceiveCard(
        payload: q.payload,
        bank: q.bank,
        holder: q.holder,
        accountNumber: vietQrAccountNumber(q.payload) ?? '',
        amount: r.remaining,
        note: r.memo,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _send(Reminder r) async {
    setState(() => _busy = true);
    try {
      final png = await _card;
      final name =
          'MoMa-nhac-no-${r.alias.replaceAll(RegExp(r'\s+'), '-')}.png';
      final res = await SharePlus.instance.share(
        ShareParams(
          text: _message.text.trim(),
          files: png == null
              ? null
              : [XFile.fromData(png, name: name, mimeType: 'image/png')],
          fileNameOverrides: png == null ? null : [name],
        ),
      );
      if (res.status == ShareResultStatus.dismissed) return;
      await ref.read(apiProvider).post('/debts/${r.debtId}/reminded', const {});
      refreshCollect(ref);
      if (mounted) {
        showSnack(context, 'Đã gửi lời nhắc. Tiền về là MoMa tự gạch nợ.');
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } catch (_) {
      if (mounted) {
        await showErrorDialog(context, 'Không mở được ứng dụng để gửi.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _snooze(Reminder r) async {
    try {
      await ref.read(apiProvider).post('/debts/${r.debtId}/snooze', const {
        'days': 3,
      });
      refreshCollect(ref);
      if (mounted) {
        Navigator.maybePop(context);
        showSnack(context, 'Mình sẽ nhắc lại sau 3 ngày.');
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(debtReminderProvider(widget.debtId));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          e is ApiException ? e.message : 'Không tải được khoản nợ.',
          style: TextStyle(color: context.pal.muted),
        ),
      ),
      data: (r) {
        if (_loadedFor != r.debtId) {
          _loadedFor = r.debtId;
          _message.text = r.message;
          if (r.receivable) _card = _buildCard(r);
        }
        return r.receivable
            ? _receivable(context, r)
            : _PayablePanel(reminder: r);
      },
    );
  }

  Widget _receivable(BuildContext context, Reminder r) {
    final pal = context.pal;
    final stage = switch (r.remindCount) {
      0 =>
        r.overdueDays > 0
            ? 'Đã quá hạn ${r.overdueDays} ngày · lần nhắc đầu'
            : 'Lần nhắc đầu',
      1 => 'Nhắc lại lần 2',
      _ => 'Nhắc lại lần ${r.remindCount + 1}',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            PersonAvatar(name: r.alias, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nhắc ${r.alias} trả ${formatVnd(r.remaining)}',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800, color: pal.ink),
                  ),
                  Text(stage, style: TextStyle(color: pal.muted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('reminder-message'),
          controller: _message,
          minLines: 3,
          maxLines: 7,
          decoration: const InputDecoration(labelText: 'Tin nhắn (sửa được)'),
        ),
        const SizedBox(height: 12),
        FutureBuilder<Uint8List?>(
          future: _card,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final png = snap.data;
            if (png == null) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: pal.warnBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Chưa có mã QR: liên kết một tài khoản ngân hàng để tin nhắn kèm mã QR đúng số tiền. Tin nhắn vẫn gửi được.',
                  style: TextStyle(color: pal.warnInk, height: 1.4),
                ),
              );
            }
            return Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(png, height: 260, fit: BoxFit.contain),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Nội dung chuyển khoản "${r.memo}" giúp MoMa tự gạch nợ khi tiền về.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: pal.muted),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('reminder-send'),
          onPressed: _busy ? null : () => _send(r),
          icon: const Icon(Symbols.send_rounded),
          label: const Text('Gửi qua Zalo / Messenger…'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _message.text.trim()),
                  );
                  if (context.mounted) {
                    showSnack(context, 'Đã sao chép tin nhắn.');
                  }
                },
                icon: const Icon(Symbols.content_copy_rounded),
                label: const Text('Sao chép'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _snooze(r),
                icon: const Icon(Symbols.snooze_rounded),
                label: const Text('Để sau 3 ngày'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the owner owes: the creditor's bank (copy / QR to scan from the bank app) or a one-time form to save it.
class _PayablePanel extends ConsumerStatefulWidget {
  const _PayablePanel({required this.reminder});
  final Reminder reminder;
  @override
  ConsumerState<_PayablePanel> createState() => _PayablePanelState();
}

class _PayablePanelState extends ConsumerState<_PayablePanel> {
  final _number = TextEditingController();
  final _holder = TextEditingController();
  String? _bin;
  bool _editing = false;
  bool _busy = false;
  String? _error;

  static final _banks = [
    for (final b in kBrands)
      if (b.bin != null && b.kind == BrandKind.bank) b,
  ];

  @override
  void dispose() {
    _number.dispose();
    _holder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final brand = _banks.where((b) => b.bin == _bin).firstOrNull;
    final num = _number.text.replaceAll(RegExp(r'\D'), '');
    if (brand == null || num.length < 4) {
      setState(() => _error = 'Chọn ngân hàng và nhập số tài khoản.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).put(
        '/contacts/${widget.reminder.contactId}/bank',
        {
          'bank': brand.shortName,
          'bin': brand.bin,
          'account_number': num,
          if (_holder.text.trim().isNotEmpty) 'holder': _holder.text.trim(),
        },
      );
      ref.invalidate(debtReminderProvider(widget.reminder.debtId));
      if (mounted) setState(() => _editing = false);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _copyRow(String label, String value) {
    final pal = context.pal;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: TextStyle(color: pal.muted, fontSize: 12.5)),
      subtitle: Text(
        value,
        style: TextStyle(
          color: pal.ink,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Sao chép $label',
        icon: const Icon(Symbols.content_copy_rounded),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          if (mounted) showSnack(context, 'Đã sao chép $label.');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final r = widget.reminder;
    final b = r.bank;
    final qr = b?.bin == null ? null : _payQr(b!, r);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Trả ${r.alias} ${formatVnd(r.remaining)}',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800, color: pal.ink),
        ),
        if (r.dueDate != null)
          Text(
            'Hạn ${r.dueDate}',
            style: TextStyle(
              color: r.overdueDays > 0 ? MomaColors.expense : pal.muted,
            ),
          ),
        const SizedBox(height: 12),
        if (b != null && !_editing) ...[
          _copyRow('Số tài khoản', b.accountNumber),
          _copyRow('Số tiền', '${r.remaining}'),
          Text(
            '${b.bank}${b.holder == null ? '' : ' · ${b.holder}'}',
            style: TextStyle(color: pal.muted),
          ),
          if (qr != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: QrImageView(
                  data: qr,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Lưu ảnh mã này rồi mở app ngân hàng → Quét QR → chọn ảnh.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: pal.muted),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Chuyển xong là MoMa tự gạch khoản nợ này.',
            textAlign: TextAlign.center,
            style: TextStyle(color: pal.muted),
          ),
          TextButton(
            onPressed: () => setState(() => _editing = true),
            child: const Text('Đổi tài khoản nhận'),
          ),
        ] else ...[
          Text(
            'Lưu tài khoản ngân hàng của ${r.alias} một lần, lần sau trả nợ chỉ cần một chạm.',
            style: TextStyle(color: pal.muted, height: 1.4),
          ),
          const SizedBox(height: 10),
          PickField<String>(
            isExpanded: true,
            initialValue: _bin,
            decoration: const InputDecoration(labelText: 'Ngân hàng'),
            items: [
              for (final x in _banks)
                DropdownMenuItem(value: x.bin, child: Text(x.shortName)),
            ],
            onChanged: (v) => setState(() => _bin = v),
          ),
          const SizedBox(height: 10),
          LabeledField(
            label: 'Số tài khoản',
            hint: 'Nhập số tài khoản',
            controller: _number,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 10),
          LabeledField(
            label: 'Tên chủ tài khoản (không bắt buộc)',
            hint: 'VD: LE VAN HUNG',
            controller: _holder,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: MomaColors.expense),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Lưu tài khoản'),
          ),
        ],
      ],
    );
  }

  String? _payQr(CreditorBank b, Reminder r) {
    try {
      return vietQrPayload(
        bin: b.bin!,
        accountNumber: b.accountNumber,
        amount: r.remaining,
        note: 'Tra no ${r.alias}',
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------- settlements

/// Transaction detail: "Đã ghi là Nam trả nợ 535.000đ · Hoàn tác".
class TxSettlementSection extends ConsumerWidget {
  const TxSettlementSection({super.key, required this.txId});
  final String txId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(txSettlementProvider(txId)).value;
    if (s == null) return const SizedBox.shrink();
    final pal = context.pal;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.tintSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Symbols.handshake_rounded, color: pal.accentInk),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.receivable
                      ? 'Đã ghi là ${s.alias} trả nợ ${formatVnd(s.amount)}'
                      : 'Đã ghi là bạn trả ${s.alias} ${formatVnd(s.amount)}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
                ),
                Text(
                  '${s.receivable ? 'Không tính là thu nhập' : 'Không tính là chi tiêu'}${s.remaining > 0 ? ' · còn nợ ${formatVnd(s.remaining)}' : ' · đã trả đủ'}',
                  style: TextStyle(color: pal.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          if (s.canUndo)
            TextButton(
              onPressed: () => undoSettlement(context, ref, s),
              child: const Text('Hoàn tác'),
            ),
        ],
      ),
    );
  }
}

Future<void> undoSettlement(
  BuildContext context,
  WidgetRef ref,
  Settlement s,
) async {
  try {
    await ref.read(apiProvider).post('/collect/${s.id}/undo', const {});
    refreshAll(ref);
    refreshCollect(ref);
    ref.invalidate(txSettlementProvider(s.moneyTxId));
    if (s.repayTxId != null) ref.invalidate(txSettlementProvider(s.repayTxId!));
    if (context.mounted) {
      showSnack(context, 'Đã hoàn tác, khoản tiền trở lại như lúc nhận.');
    }
  } on ApiException catch (e) {
    if (context.mounted) await showErrorDialog(context, e.message);
  }
}

/// Bell "Cần xử lý": repayments MoMa is not sure about, one tap each.
Future<void> showCollectSuggestionsSheet(BuildContext context) =>
    showFormSheet<void>(context, (_) => const _SuggestionsSheet());

class _SuggestionsSheet extends ConsumerStatefulWidget {
  const _SuggestionsSheet();
  @override
  ConsumerState<_SuggestionsSheet> createState() => _SuggestionsSheetState();
}

class _SuggestionsSheetState extends ConsumerState<_SuggestionsSheet> {
  String? _busy;

  Future<void> _decide(Settlement s, bool accept) async {
    setState(() => _busy = s.id);
    try {
      await ref.read(apiProvider).post('/collect/${s.id}/decide', {
        'accept': accept,
      });
      refreshAll(ref);
      refreshCollect(ref);
      if (mounted) {
        showSnack(context, accept ? 'Đã ghi ${s.alias} trả nợ.' : 'Đã bỏ qua.');
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list =
        ref.watch(collectSuggestionsProvider).value ?? const <Settlement>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Tiền trả nợ?',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800, color: pal.ink),
        ),
        const SizedBox(height: 4),
        Text(
          'MoMa thấy các khoản tiền này có thể là tiền trả nợ. Chọn đúng người là xong.',
          style: TextStyle(color: pal.muted),
        ),
        const SizedBox(height: 12),
        if (list.isEmpty)
          Text(
            'Không còn gì cần xác nhận.',
            style: TextStyle(color: pal.muted),
          ),
        for (final s in list)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.question,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: pal.ink,
                    ),
                  ),
                  Text(
                    [
                      if (s.accountName != null) s.accountName!,
                      if (s.at != null) dateLabel(s.at!),
                      if ((s.moneyNote ?? '').isNotEmpty) s.moneyNote!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pal.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy != null
                              ? null
                              : () => _decide(s, true),
                          child: Text('Đúng, ${s.alias}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy != null
                              ? null
                              : () => _decide(s, false),
                          child: const Text('Không phải'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- goals

/// "Tiết kiệm" tab: one-tap proposals ("Trích 2.100.000đ vào Laptop?") and each goal's plan.
class GoalAutoSection extends ConsumerStatefulWidget {
  const GoalAutoSection({super.key});
  @override
  ConsumerState<GoalAutoSection> createState() => _GoalAutoSectionState();
}

class _GoalAutoSectionState extends ConsumerState<GoalAutoSection> {
  String? _busy;

  Future<void> _act(GoalProposal p, bool accept) async {
    setState(() => _busy = p.id);
    try {
      await ref
          .read(apiProvider)
          .post(
            '/goals/proposals/${p.id}/${accept ? 'accept' : 'dismiss'}',
            const {},
          );
      refreshCollect(ref);
      if (mounted) {
        showSnack(
          context,
          accept
              ? 'Đã trích ${formatVnd(p.amount)} vào "${p.goalName}".'
              : 'Đã bỏ qua.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final props =
        ref.watch(goalProposalsProvider).value ?? const <GoalProposal>[];
    final plans = (ref.watch(goalPlanProvider).value ?? const <GoalPlanItem>[])
        .where((g) => g.line.isNotEmpty)
        .toList();
    if (props.isEmpty && plans.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in props)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: pal.tintSoft,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Symbols.savings_rounded, color: pal.accentInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: pal.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(p.why, style: TextStyle(color: pal.muted, fontSize: 13)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy != null ? null : () => _act(p, true),
                        child: const Text('Trích ngay'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy != null ? null : () => _act(p, false),
                        child: const Text('Bỏ qua'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (plans.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: pal.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kế hoạch tiết kiệm',
                  style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
                ),
                const SizedBox(height: 6),
                for (final g in plans)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${g.name}: ',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: pal.ink,
                            ),
                          ),
                          TextSpan(
                            text: g.line,
                            style: TextStyle(
                              color: g.onTrack == false
                                  ? MomaColors.expense
                                  : pal.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Lương về hoặc cuối tháng chi ít hơn, MoMa sẽ gợi ý trích tiền cho bạn.',
                  style: TextStyle(fontSize: 12.5, color: pal.hint),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Chat card "Nhắc Nam trả 535.000 ₫? [Soạn tin]" (assistant REMIND action).
class RemindActionCard extends StatelessWidget {
  const RemindActionCard({super.key, required this.json});
  final Map<String, dynamic> json;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final lines = [for (final l in (json['lines'] as List? ?? const [])) '$l'];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.notifications_active_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${json['title'] ?? ''}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
                ),
              ),
            ],
          ),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(l, style: TextStyle(color: pal.muted, fontSize: 13)),
            ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => openReminder(context, '${json['debt_id']}'),
            icon: const Icon(Symbols.send_rounded),
            label: const Text('Soạn tin & gửi'),
          ),
        ],
      ),
    );
  }
}
