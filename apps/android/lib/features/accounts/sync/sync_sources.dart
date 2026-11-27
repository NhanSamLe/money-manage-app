import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../../../core/models.dart';
import '../../../core/providers.dart';
import '../../notify_capture/notify_capture_service.dart';
import '../../notify_capture/parser.dart' show notifyBankNames;

/// One MoMa account linked to a bank account through SePay (GET /v1/banks/links).
class BankLink {
  BankLink(Map<String, dynamic> j)
    : accountId = '${j['account_id']}',
      externalId = j['external_id'] as String?,
      last4 = j['last4'] as String?,
      number = j['number'] as String?,
      holder = j['holder_name'] as String?,
      bankName = j['bank_name'] as String?,
      bankBalance = int.tryParse('${j['bank_balance'] ?? ''}'),
      ledgerBalance = int.tryParse('${j['ledger_balance'] ?? ''}'),
      bankBalanceAt = DateTime.tryParse('${j['bank_balance_at'] ?? ''}');
  final String accountId;
  final String? externalId;
  final String? last4;

  /// Full account number (owner only; shown masked until revealed). Null when SePay was unreachable.
  final String? number;
  final String? holder;
  final String? bankName;
  final int? bankBalance;
  final int? ledgerBalance;

  /// When SePay last reported this account's balance (the closest thing to a "last sync" time).
  final DateTime? bankBalanceAt;
}

final bankLinksProvider = FutureProvider.autoDispose<List<BankLink>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/banks/links');
  return [
    for (final l in (data as List? ?? const []))
      BankLink(Map<String, dynamic>.from(l as Map)),
  ];
});

/// How an account can record transactions by itself.
enum SyncKind {
  /// Cash: only typed in by hand or through the assistant.
  manual,

  /// A bank account SePay can link (bank sync available).
  bank,

  /// Wallets, cards, savings: no bank API, only Android notifications.
  notifyOnly,
}

SyncKind syncKindOf(Account a) => switch (a.kind) {
  'CASH' => SyncKind.manual,
  'BANK' => SyncKind.bank,
  _ => SyncKind.notifyOnly,
};

/// Android packages whose notifications MoMa can read, as (package, display name). Apps whose name matches
/// [institution] come first so the likely choice is on top.
List<(String, String)> notifySourceApps({String? institution}) {
  final key = (institution ?? '').trim().toLowerCase();
  final all = [for (final e in notifyBankNames.entries) (e.key, e.value)];
  bool hit((String, String) p) {
    final n = p.$2.toLowerCase();
    return key.isNotEmpty && (n.contains(key) || key.contains(n));
  }

  return [...all.where(hit), ...all.where((p) => !hit(p))];
}

/// Local notification-capture settings seen from the Accounts page: which bank app feeds which account.
abstract class NotifySyncStore {
  Future<Map<String, String>> accountMap();
  Future<void> mapPackage(String package, String accountId);

  /// Removes every app mapped to [accountId].
  Future<void> unmapAccount(String accountId);

  /// Stops recording one app.
  Future<void> unmapPackage(String package);
  Future<bool> autoRecord();
  Future<void> setAutoRecord(bool v);
}

/// Real store: reads and writes the same secure-storage entries as [NotifyCapturePrefs].
class SecureNotifySyncStore implements NotifySyncStore {
  SecureNotifySyncStore([FlutterSecureStorage? storage])
    : _prefs = NotifyCapturePrefs(storage);
  final NotifyCapturePrefs _prefs;

  @override
  Future<Map<String, String>> accountMap() => _prefs.accountMap();

  @override
  Future<void> mapPackage(String package, String accountId) =>
      _prefs.setAccount(package, accountId);

  @override
  Future<void> unmapAccount(String accountId) =>
      _prefs.removeAccount(accountId);

  @override
  Future<void> unmapPackage(String package) => _prefs.removePackage(package);

  @override
  Future<bool> autoRecord() => _prefs.autoRecord();

  @override
  Future<void> setAutoRecord(bool v) => _prefs.setAutoRecord(v);
}

/// Notification-access permission and the queue of captured notifications.
abstract class NotifyAccess {
  Future<bool> isGranted();
  Future<void> openSettings();
  Future<int> pendingCount();

  /// Supported bank / wallet apps installed on this phone.
  Future<List<String>> installedApps();
}

class ChannelNotifyAccess implements NotifyAccess {
  const ChannelNotifyAccess();
  static const _ch = NotifyCaptureChannel();
  @override
  Future<bool> isGranted() => _ch.isPermissionGranted();
  @override
  Future<void> openSettings() => _ch.openPermissionSettings();
  @override
  Future<int> pendingCount() async => (await _ch.pending()).length;
  @override
  Future<List<String>> installedApps() => _ch.installedSupportedApps();
}

final notifySyncStoreProvider = Provider<NotifySyncStore>(
  (_) => SecureNotifySyncStore(),
);
final notifyAccessProvider = Provider<NotifyAccess>(
  (_) => const ChannelNotifyAccess(),
);

/// Snapshot of the notification side, reloaded after every change and when the app comes back to front.
class NotifySyncState {
  const NotifySyncState({
    required this.map,
    required this.granted,
    required this.pending,
    required this.autoRecord,
  });
  final Map<String, String> map;
  final bool granted;
  final int pending;
  final bool autoRecord;

  List<String> packagesOf(String accountId) => [
    for (final e in map.entries)
      if (e.value == accountId) e.key,
  ];
}

final notifySyncStateProvider = FutureProvider.autoDispose<NotifySyncState>((
  ref,
) async {
  final store = ref.watch(notifySyncStoreProvider);
  final access = ref.watch(notifyAccessProvider);
  final results = await Future.wait<Object>([
    store.accountMap(),
    access.isGranted(),
    access.pendingCount(),
    store.autoRecord(),
  ]);
  return NotifySyncState(
    map: results[0] as Map<String, String>,
    granted: results[1] as bool,
    pending: results[2] as int,
    autoRecord: results[3] as bool,
  );
});

/// Whether push notifications are allowed (OneSignal's cached state); null when it cannot be read.
final pushPermissionProvider = FutureProvider.autoDispose<bool?>((_) async {
  try {
    return OneSignal.Notifications.permission;
  } on Object {
    return null;
  }
});
