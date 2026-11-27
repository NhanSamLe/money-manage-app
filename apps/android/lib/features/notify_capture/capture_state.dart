import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../accounts/sync/sync_sources.dart' show bankLinksProvider, BankLink;
import '../notifications/notifications.dart' show Notice;
import 'balance_gap_sheet.dart';
import 'capture_engine.dart';
import 'notify_capture_service.dart';

/// Local capture settings (secure storage). Overridable in tests.
final notifyCapturePrefsProvider = Provider<NotifyCapturePrefs>(
  (_) => NotifyCapturePrefs(),
);

/// Open balance gaps (money that moved without a notification), newest first.
final balanceGapsProvider = FutureProvider.autoDispose<List<BalanceGap>>((
  ref,
) async {
  final list = await ref.watch(notifyCapturePrefsProvider).gaps();
  return list..sort((a, b) => b.to.compareTo(a.to));
});

/// Full account numbers read from notifications, per account (local only).
final capturedNumbersProvider = FutureProvider.autoDispose<Map<String, String>>(
  (ref) => ref.watch(notifyCapturePrefsProvider).accountNumbers(),
);

/// Wallets (not bank-linked) without any balance report for 7 days, when the weekly reminder is on.
final walletsToUpdateProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  final prefs = ref.watch(notifyCapturePrefsProvider);
  if (!await prefs.walletReminder()) return const [];
  final accounts = await ref.watch(accountsProvider.future);
  final links = await ref
      .watch(bankLinksProvider.future)
      .catchError((_) => <BankLink>[]);
  final linked = {for (final l in links) l.accountId};
  final seen = await prefs.balancesSeen();
  final weekAgo = DateTime.now().subtract(const Duration(days: 7));
  return [
    for (final a in accounts)
      if (a.kind == 'WALLET' &&
          !linked.contains(a.id) &&
          (seen[a.id]?.at.isBefore(weekAgo) ?? true))
        a,
  ];
});

String _hm(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)} ${two(l.day)}/${two(l.month)}';
}

/// "MoMo: có khoản chi 150.000 ₫ chưa ghi (giữa 08:00 27/11 và 10:00 28/11)".
String gapText(BalanceGap g) {
  final what = g.missingOutflow ? 'khoản chi' : 'khoản thu';
  final when = g.from == null
      ? 'trước ${_hm(g.to)}'
      : 'giữa ${_hm(g.from!)} và ${_hm(g.to)}';
  return '${g.accountName}: có $what ${formatVnd(g.amount.abs())} chưa ghi ($when)';
}

/// Notices for the bell: open balance gaps and the weekly wallet balance reminder.
final captureNoticesProvider = Provider.autoDispose<List<Notice>>((ref) {
  final gaps = ref.watch(balanceGapsProvider).value ?? const [];
  final wallets = ref.watch(walletsToUpdateProvider).value ?? const [];
  return [
    for (final g in gaps)
      Notice(
        id: 'gap-${g.id}',
        icon: g.missingOutflow
            ? Symbols.trending_down_rounded
            : Symbols.trending_up_rounded,
        color: g.missingOutflow ? MomaColors.expense : MomaColors.income,
        title: g.missingOutflow ? 'Khoản chi chưa ghi' : 'Khoản thu chưa ghi',
        text: gapText(g),
        route: '/accounts',
        onOpen: (context) => openBalanceGap(context, g),
      ),
    for (final a in wallets)
      Notice(
        id: 'wallet-balance-${a.id}',
        icon: Symbols.account_balance_wallet_rounded,
        color: const Color(0xFF2F80ED),
        title: 'Cập nhật số dư ${a.name}',
        text:
            'Một tuần chưa có số dư ${a.name}. Nhập số dư hiện tại để MoMa tìm khoản chi chưa ghi.',
        route: '/accounts',
        onOpen: (context) => openUpdateBalance(context, a),
      ),
  ];
});

Future<void> openBalanceGap(BuildContext context, BalanceGap gap) =>
    showFormSheet<void>(context, (_) => BalanceGapSheet(gap: gap));

Future<void> openUpdateBalance(BuildContext context, Account account) =>
    showFormSheet<void>(context, (_) => UpdateBalanceSheet(account: account));

/// Records every pending notification through the zero-tap path (see [runCapture]). Returns how many were
/// recorded. Safe to call at app start and repeatedly: each notification has a fixed command id.
Future<int> autoRecordNotifications(WidgetRef ref) async {
  const channel = NotifyCaptureChannel();
  final items = await channel.pending();
  if (items.isEmpty) return 0;
  final out = await runCapture(
    items: items,
    ledger: ApiCaptureLedger(ref.read(apiProvider)),
    prefs: ref.read(notifyCapturePrefsProvider),
  );
  await channel.ack(out.acked);
  if (out.recorded > 0 || out.created.isNotEmpty) refreshAll(ref);
  if (out.gaps.isNotEmpty || out.created.isNotEmpty) {
    ref
      ..invalidate(balanceGapsProvider)
      ..invalidate(capturedNumbersProvider);
  }
  return out.recorded;
}

/// Resolves a gap: as an expense / income, as a transfer with another own account, or as a balance adjustment.
/// Every action uses a fixed command id per gap, so a retry never posts twice.
Future<void> resolveGap(
  ApiClient api,
  NotifyCapturePrefs prefs,
  BalanceGap gap, {
  required String action,
  String? categoryId,
  String? note,
  String? otherAccountId,
  Account? account,
}) async {
  final id = const Uuid().v5(Namespace.url.value, 'moma-gap|${gap.id}|$action');
  final at = gap.to
      .subtract(const Duration(seconds: 1))
      .toUtc()
      .toIso8601String();
  final amount = gap.amount.abs().toString();
  switch (action) {
    case 'category':
      await api.command('TX_CREATE', {
        'kind': gap.missingOutflow ? 'EXPENSE' : 'INCOME',
        'account_id': gap.accountId,
        'amount': amount,
        'effective_at': at,
        'category_id': categoryId,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'source': 'MANUAL',
      }, commandId: id);
    case 'transfer':
      await api.command('TX_CREATE', {
        'kind': 'TRANSFER',
        'account_id': gap.missingOutflow ? gap.accountId : otherAccountId,
        'to_account_id': gap.missingOutflow ? otherAccountId : gap.accountId,
        'amount': amount,
        'effective_at': at,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'source': 'MANUAL',
      }, commandId: id);
    case 'adjust':
      final a = account!;
      await api.command('ACCOUNT_UPDATE', {
        'account_id': a.id,
        'expected_version': a.version,
        'balance': ((a.balance ?? 0) + gap.amount).toString(),
      }, commandId: id);
  }
  await prefs.removeGap(gap.id);
}
