import 'package:uuid/uuid.dart';

import '../../core/brands/brand_registry.dart';
import '../../core/models.dart';
import '../../core/network/api_client.dart';
import 'notify_capture_service.dart';
import 'parser.dart';

/// What the capture engine needs from MoMa's ledger. [ApiCaptureLedger] is the real one; tests fake it.
abstract class CaptureLedger {
  Future<List<Account>> accounts();
  Future<List<Category>> categories();

  /// MoMa accounts linked to a bank through SePay (those never take notification transactions).
  Future<Set<String>> linkedAccountIds();
  Future<String> createAccount({
    required String kind,
    required String institution,
    required String name,
    String? last4,
    int? opening,
    DateTime? baselineAt,
  });

  /// Records one notification; false when it had already been recorded (replayed command).
  Future<bool> record(
    CapturedNotification n, {
    required String accountId,
    required NotifyDirection direction,
    required int amount,
    required List<Category> categories,
  });

  /// ACCOUNT_UPDATE with [fields] (name, institution, last4, balance, balance_at).
  Future<void> updateAccount(Account a, Map<String, dynamic> fields);
}

class ApiCaptureLedger implements CaptureLedger {
  ApiCaptureLedger(this.api);
  final ApiClient api;

  static List<Map<String, dynamic>> _list(Object? data) => [
    for (final e in (data as List? ?? const []))
      Map<String, dynamic>.from(e as Map),
  ];

  @override
  Future<List<Account>> accounts() async =>
      _list(await api.get('/accounts')).map(Account.fromJson).toList();

  @override
  Future<List<Category>> categories() async =>
      _list(await api.get('/categories')).map(Category.fromJson).toList();

  @override
  Future<Set<String>> linkedAccountIds() async => {
    for (final l in _list(await api.get('/banks/links'))) '${l['account_id']}',
  };

  @override
  Future<String> createAccount({
    required String kind,
    required String institution,
    required String name,
    String? last4,
    int? opening,
    DateTime? baselineAt,
  }) async {
    final r = await api.command('ACCOUNT_CREATE', {
      'kind': kind,
      'institution': institution,
      'name': name,
      'last4': ?last4,
      if (opening != null) ...{
        'opening_amount': opening.toString(),
        'baseline_at': (baselineAt ?? DateTime.now()).toUtc().toIso8601String(),
      },
    }, commandId: ApiClient.newId());
    return '${r['account_id']}';
  }

  @override
  Future<bool> record(
    CapturedNotification n, {
    required String accountId,
    required NotifyDirection direction,
    required int amount,
    required List<Category> categories,
  }) => recordNotification(
    api,
    n,
    accountId: accountId,
    direction: direction,
    amount: amount,
    categories: categories,
  );

  @override
  Future<void> updateAccount(Account a, Map<String, dynamic> fields) =>
      api.command('ACCOUNT_UPDATE', {
        'account_id': a.id,
        'expected_version': a.version,
        ...fields,
      }, commandId: ApiClient.newId());
}

/// Kind, bank / wallet name and account name MoMa gives an account it creates for a bank / wallet app.
({String kind, String institution, String name}) accountSpecForPackage(
  String package,
) {
  final brand = brandFor(package: package);
  final name = (brand?.shortName ?? bankNameOf(package));
  final short = name.length > 40 ? name.substring(0, 40) : name;
  return (
    kind: brand?.kind == BrandKind.wallet ? 'WALLET' : 'BANK',
    institution: short,
    name: short,
  );
}

/// Brand code of an account (by its institution), used to match apps to accounts.
String? brandCodeOf(Account a) => brandFor(institution: a.institution)?.code;

/// An existing account the app's notifications can go to: same bank / wallet brand, not a card, not SePay-linked
/// and not already fed by another app.
Account? matchAccountForPackage(
  String package,
  List<Account> accounts, {
  required Map<String, String> map,
  required Set<String> linked,
}) {
  final code = brandFor(package: package)?.code;
  if (code == null) return null;
  final taken = {
    for (final e in map.entries)
      if (e.key != package) e.value,
  };
  return accounts
      .where(
        (a) =>
            !a.isCard &&
            !linked.contains(a.id) &&
            !taken.contains(a.id) &&
            brandCodeOf(a) == code,
      )
      .firstOrNull;
}

/// Whether the bank behind [package] is linked through SePay (then its notifications are not recorded: the bank
/// sync already posts them). With [last4] only the linked account with those digits counts.
bool packageIsSepayLinked(
  String package,
  List<Account> accounts,
  Set<String> linked, {
  String? last4,
}) {
  final code = brandFor(package: package)?.code;
  if (code == null) return false;
  return accounts.any(
    (a) =>
        linked.contains(a.id) &&
        brandCodeOf(a) == code &&
        (last4 == null || a.last4 == null || a.last4 == last4),
  );
}

/// Pure gap math: the reported balance minus what MoMa expects (its balance plus open gaps). 0 = no gap.
int balanceGap({
  required int momaBalance,
  required int reported,
  int openGaps = 0,
}) => reported - (momaBalance + openGaps);

/// Opening balance for an account created from a notification: so that after recording this transaction MoMa
/// shows exactly the reported balance.
int openingFromReported(NotifyParse p) => p.balance! - p.signedAmount;

class CaptureOutcome {
  int recorded = 0;
  final created = <String>[];
  final gaps = <BalanceGap>[];
  final acked = <String>[];
  bool offline = false;
}

final _ns = Namespace.url.value;

/// The zero-tap path. For each captured notification (oldest first): find the account (mapping, an existing
/// account of the same brand, or a new one), record the transaction, then use the reported balance: a new account
/// starts so that MoMa equals the bank; an account with an unknown balance gets it; otherwise a difference becomes
/// a [BalanceGap] for the owner to resolve. Apps whose bank is SePay-linked are skipped (bank sync posts them).
/// Notifications without an amount stay in the queue for the owner. Returns what happened; the caller acks
/// [CaptureOutcome.acked].
Future<CaptureOutcome> runCapture({
  required List<CapturedNotification> items,
  required CaptureLedger ledger,
  required NotifyCapturePrefs prefs,
  bool force = false,
}) async {
  final out = CaptureOutcome();
  if (items.isEmpty) return out;
  if (!force && !await prefs.autoRecord()) return out;
  final List<Account> accounts;
  final Set<String> linked;
  try {
    accounts = [...await ledger.accounts()];
    linked = await ledger.linkedAccountIds();
  } on ApiException catch (e) {
    out.offline = e.code == 'OFFLINE';
    return out;
  }
  final cats = await ledger.categories().catchError((_) => <Category>[]);
  final map = await prefs.accountMap();
  final seen = await prefs.balancesSeen();
  final openGaps = <String, int>{};
  for (final g in await prefs.gaps()) {
    openGaps[g.accountId] = (openGaps[g.accountId] ?? 0) + g.amount;
  }
  final balances = {for (final a in accounts) a.id: a.balance};
  Account? byId(String id) => accounts.where((a) => a.id == id).firstOrNull;

  final sorted = [...items]..sort((a, b) => a.postTime.compareTo(b.postTime));
  for (final n in sorted) {
    final p = n.parsed;
    if (!p.isTransaction) {
      continue; // no amount: the owner completes it on the capture page
    }
    final when = n.postTime.millisecondsSinceEpoch > 0
        ? n.postTime
        : DateTime.now();
    try {
      var accountId = map[n.package];
      if (accountId != null && byId(accountId) == null) {
        accountId = null; // archived or gone
        await prefs.removePackage(n.package);
        map.remove(n.package);
      }
      if (accountId != null && linked.contains(accountId)) {
        out.acked.add(n.key); // bank sync already posts this account
        continue;
      }
      var created = false;
      if (accountId == null) {
        if (packageIsSepayLinked(n.package, accounts, linked, last4: p.last4)) {
          out.acked.add(n.key);
          continue;
        }
        final match = matchAccountForPackage(
          n.package,
          accounts,
          map: map,
          linked: linked,
        );
        if (match != null) {
          accountId = match.id;
        } else {
          final spec = accountSpecForPackage(n.package);
          final opening = p.balance == null ? null : openingFromReported(p);
          accountId = await ledger.createAccount(
            kind: spec.kind,
            institution: spec.institution,
            name: spec.name,
            last4: p.last4,
            opening: opening,
            baselineAt: when.subtract(const Duration(seconds: 1)),
          );
          accounts.add(
            Account(
              id: accountId,
              kind: spec.kind,
              institution: spec.institution,
              name: spec.name,
              last4: p.last4,
              balance: opening,
              version: 1,
            ),
          );
          balances[accountId] = opening;
          created = true;
          out.created.add(accountId);
        }
        map[n.package] = accountId;
        await prefs.setAccount(n.package, accountId);
      }
      final fresh = await ledger.record(
        n,
        accountId: accountId,
        direction: p.direction!,
        amount: p.amount!,
        categories: cats,
      );
      final before = balances[accountId];
      if (fresh && before != null) {
        balances[accountId] = before + p.signedAmount;
      }

      final acc = byId(accountId)!;
      final fields = <String, dynamic>{};
      if (!created && p.last4 != null && acc.last4 == null) {
        fields['last4'] = p.last4;
      }
      if (p.balance != null && !created) {
        final now = balances[accountId];
        if (now == null) {
          // Balance was unknown: the bank's figure becomes MoMa's.
          fields['balance'] = p.balance.toString();
          fields['balance_at'] = when.toUtc().toIso8601String();
          balances[accountId] = p.balance;
        } else {
          final diff = balanceGap(
            momaBalance: now,
            reported: p.balance!,
            openGaps: openGaps[accountId] ?? 0,
          );
          if (diff != 0) {
            final gap = BalanceGap(
              id: const Uuid().v5(_ns, 'moma-gap|$accountId|${n.key}'),
              accountId: accountId,
              accountName: acc.name,
              amount: diff,
              reported: p.balance!,
              from: seen[accountId]?.at,
              to: when,
            );
            await prefs.addGap(gap);
            openGaps[accountId] = (openGaps[accountId] ?? 0) + diff;
            out.gaps.add(gap);
          }
        }
      }
      if (fields.isNotEmpty) {
        await ledger.updateAccount(acc, fields);
        final i = accounts.indexOf(acc);
        accounts[i] = Account(
          id: acc.id,
          kind: acc.kind,
          institution: acc.institution,
          name: acc.name,
          last4: fields['last4'] as String? ?? acc.last4,
          balance: balances[accountId],
          version: acc.version + 1,
        );
      }
      if (p.accountNumber != null) {
        await prefs.setAccountNumber(accountId, p.accountNumber!);
      }
      if (p.balance != null) {
        await prefs.setBalanceSeen(accountId, p.balance!, when);
        seen[accountId] = BalanceSeen(p.balance!, when);
      }
      if (fresh) out.recorded++;
      out.acked.add(n.key);
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') {
        out.offline = true;
        break; // the queue keeps the rest for the next run
      }
    }
  }
  return out;
}

/// The owner (or a shared receipt) reports [reported] as the current balance of [account]: unknown balance ->
/// set it; otherwise a difference becomes a [BalanceGap]. Returns the gap, if any.
Future<BalanceGap?> reportBalance({
  required Account account,
  required int reported,
  required CaptureLedger ledger,
  required NotifyCapturePrefs prefs,
  DateTime? at,
}) async {
  final when = at ?? DateTime.now();
  BalanceGap? gap;
  if (account.balance == null) {
    await ledger.updateAccount(account, {'balance': reported.toString()});
  } else {
    final open = (await prefs.gaps())
        .where((g) => g.accountId == account.id)
        .fold<int>(0, (s, g) => s + g.amount);
    final diff = balanceGap(
      momaBalance: account.balance!,
      reported: reported,
      openGaps: open,
    );
    if (diff != 0) {
      final seen = (await prefs.balancesSeen())[account.id];
      gap = BalanceGap(
        id: const Uuid().v5(
          _ns,
          'moma-gap|${account.id}|typed|${when.millisecondsSinceEpoch}',
        ),
        accountId: account.id,
        accountName: account.name,
        amount: diff,
        reported: reported,
        from: seen?.at,
        to: when,
      );
      await prefs.addGap(gap);
    }
  }
  await prefs.setBalanceSeen(account.id, reported, when);
  return gap;
}
