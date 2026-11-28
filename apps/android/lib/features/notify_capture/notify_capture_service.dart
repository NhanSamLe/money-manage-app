import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../../core/quick_parse.dart';
import '../../core/models.dart';
import 'parser.dart';

/// One notification captured by the native listener (MomaNotificationListener) and kept until acknowledged.
class CapturedNotification {
  CapturedNotification({
    required this.key,
    required this.package,
    required this.title,
    required this.text,
    required this.postTime,
    this.via = 'app',
  });
  factory CapturedNotification.fromMap(Map<dynamic, dynamic> m) =>
      CapturedNotification(
        key: '${m['key']}',
        package: '${m['package']}',
        title: '${m['title'] ?? ''}',
        text: '${m['text'] ?? ''}',
        postTime: DateTime.fromMillisecondsSinceEpoch(
          (m['postTime'] as num?)?.toInt() ?? 0,
        ),
        via: '${m['via'] ?? 'app'}',
      );
  final String key;
  final String package;
  final String title;
  final String text;
  final DateTime postTime;

  /// "app" (the bank / wallet app's own notification) or "email" (a MoMo email read from Gmail / Outlook).
  final String via;
  bool get fromEmail => via == 'email';

  NotifyParse get parsed =>
      parseBankNotification(package: package, title: title, text: text);
}

/// Bridge to the native "moma/notify_capture" channel. Off Android (tests) every call degrades to "nothing".
class NotifyCaptureChannel {
  const NotifyCaptureChannel();
  static const _ch = MethodChannel('moma/notify_capture');

  Future<bool> isPermissionGranted() async {
    try {
      return await _ch.invokeMethod<bool>('isPermissionGranted') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openPermissionSettings() async {
    try {
      await _ch.invokeMethod<bool>('openPermissionSettings');
    } on MissingPluginException {
      // Not on Android.
    }
  }

  /// Supported bank / wallet apps installed on this phone (Android package ids).
  Future<List<String>> installedSupportedApps() async {
    try {
      final list =
          await _ch.invokeMethod<List<dynamic>>('installedSupportedApps') ??
          const [];
      return [for (final p in list) '$p'];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Mirrors the auto-record switch to the native side, which then records new notifications in the background.
  Future<void> setNativeAutoRecord(bool on) async {
    try {
      await _ch.invokeMethod<void>('setAutoRecord', {'on': on});
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // Older native side.
    }
  }

  Future<List<CapturedNotification>> pending() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pending') ?? [];
      return [for (final m in list) CapturedNotification.fromMap(m as Map)]
        ..sort((a, b) => b.postTime.compareTo(a.postTime));
    } on MissingPluginException {
      return [];
    }
  }

  Future<void> ack(List<String> keys) async {
    if (keys.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('ack', {'keys': keys});
    } on MissingPluginException {
      // Not on Android.
    }
  }
}

/// A difference between the balance a bank / wallet reported and MoMa's balance for that account: money moved
/// without a notification (MoMo sends none for most payments). [amount] < 0 = money out not recorded yet,
/// > 0 = money in not recorded yet. Never posted by itself; the owner resolves it.
class BalanceGap {
  const BalanceGap({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.amount,
    required this.to,
    required this.reported,
    this.from,
  });
  factory BalanceGap.fromJson(Map<String, dynamic> j) => BalanceGap(
    id: '${j['id']}',
    accountId: '${j['account_id']}',
    accountName: '${j['account_name'] ?? ''}',
    amount: (j['amount'] as num).toInt(),
    reported: (j['reported'] as num).toInt(),
    to: DateTime.parse('${j['to']}'),
    from: j['from'] == null ? null : DateTime.tryParse('${j['from']}'),
  );
  final String id;
  final String accountId;
  final String accountName;
  final int amount;

  /// The balance the bank / wallet reported at [to].
  final int reported;

  /// Last time the balance was known to match (null = unknown), and when the gap was seen.
  final DateTime? from;
  final DateTime to;

  bool get missingOutflow => amount < 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'account_id': accountId,
    'account_name': accountName,
    'amount': amount,
    'reported': reported,
    'to': to.toUtc().toIso8601String(),
    if (from != null) 'from': from!.toUtc().toIso8601String(),
  };
}

/// The last balance a bank / wallet (or the owner) reported for an account.
class BalanceSeen {
  const BalanceSeen(this.balance, this.at);
  final int balance;
  final DateTime at;
}

/// Local settings of the feature: which MoMa account each bank app maps to, the auto-record switch, the last
/// reported balances and the open balance gaps. Everything stays on this phone (secure storage).
class NotifyCapturePrefs {
  NotifyCapturePrefs([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _mapKey = 'notify_account_map';
  static const _autoKey = 'notify_auto_record';
  static const _seenKey = 'notify_balance_seen';
  static const _gapsKey = 'notify_balance_gaps';
  static const _walletReminderKey = 'notify_wallet_reminder';
  static const _numbersKey = 'notify_account_numbers';

  /// Full account numbers seen in notifications ("Số dư TK VCB 1026746096"), per MoMa account. Local only.
  Future<Map<String, String>> accountNumbers() async => {
    for (final e in (await _readMap(_numbersKey)).entries) e.key: '${e.value}',
  };

  Future<void> setAccountNumber(String accountId, String number) async {
    final m = await accountNumbers();
    if (m[accountId] == number) return;
    m[accountId] = number;
    await _s.write(key: _numbersKey, value: jsonEncode(m));
  }

  Future<Map<String, dynamic>> _readMap(String key) async {
    final raw = await _s.read(key: key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on Object {
      return {};
    }
  }

  Future<Map<String, String>> accountMap() async => {
    for (final e in (await _readMap(_mapKey)).entries) e.key: '${e.value}',
  };

  Future<void> _writeMap(Map<String, String> m) =>
      _s.write(key: _mapKey, value: jsonEncode(m));

  /// Maps [package] to [accountId] (an app records into one account only).
  Future<void> setAccount(String package, String accountId) async {
    final m = await accountMap();
    m[package] = accountId;
    await _writeMap(m);
  }

  /// Stops recording [package] (per-app switch off).
  Future<void> removePackage(String package) async {
    final m = await accountMap();
    if (m.remove(package) != null) await _writeMap(m);
  }

  /// Removes every app mapped to [accountId] (e.g. the account is now linked through SePay).
  Future<void> removeAccount(String accountId) async {
    final m = await accountMap();
    final before = m.length;
    m.removeWhere((_, v) => v == accountId);
    if (m.length != before) await _writeMap(m);
  }

  /// Automatic recording is ON unless the owner turned it off: every parsed notification of a supported app is
  /// recorded (zero-tap), the pending list only keeps what cannot be read.
  Future<bool> autoRecord() async => await _s.read(key: _autoKey) != '0';
  Future<void> setAutoRecord(bool v) async {
    await _s.write(key: _autoKey, value: v ? '1' : '0');
    await const NotifyCaptureChannel().setNativeAutoRecord(v);
  }

  /// Weekly "Cập nhật số dư" reminder for wallets (on unless turned off).
  Future<bool> walletReminder() async =>
      await _s.read(key: _walletReminderKey) != '0';
  Future<void> setWalletReminder(bool v) =>
      _s.write(key: _walletReminderKey, value: v ? '1' : '0');

  Future<Map<String, BalanceSeen>> balancesSeen() async {
    final out = <String, BalanceSeen>{};
    for (final e in (await _readMap(_seenKey)).entries) {
      final v = e.value;
      if (v is! Map) continue;
      final at = DateTime.tryParse('${v['at']}');
      final b = v['balance'];
      if (at != null && b is num) out[e.key] = BalanceSeen(b.toInt(), at);
    }
    return out;
  }

  Future<void> setBalanceSeen(
    String accountId,
    int balance,
    DateTime at,
  ) async {
    final m = await _readMap(_seenKey);
    final old = m[accountId];
    final oldAt = old is Map ? DateTime.tryParse('${old['at']}') : null;
    if (oldAt != null && oldAt.isAfter(at)) {
      return; // an older notification never overwrites a newer balance
    }
    m[accountId] = {'balance': balance, 'at': at.toUtc().toIso8601String()};
    await _s.write(key: _seenKey, value: jsonEncode(m));
  }

  Future<List<BalanceGap>> gaps() async {
    final raw = await _s.read(key: _gapsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final g in jsonDecode(raw) as List)
          BalanceGap.fromJson(Map<String, dynamic>.from(g as Map)),
      ];
    } on Object {
      return [];
    }
  }

  Future<void> _writeGaps(List<BalanceGap> gaps) => _s.write(
    key: _gapsKey,
    value: jsonEncode([for (final g in gaps) g.toJson()]),
  );

  Future<void> addGap(BalanceGap gap) async {
    final list = await gaps();
    if (list.any((g) => g.id == gap.id)) return;
    await _writeGaps([...list, gap]);
  }

  Future<void> removeGap(String id) async {
    final list = await gaps();
    await _writeGaps([
      for (final g in list)
        if (g.id != id) g,
    ]);
  }
}

final _ns = Namespace.url.value;

/// One command id per real payment, so recording the same payment twice replays on the server instead of doubling.
/// Strongest first: the MoMo transaction code (the same payment seen in the app and by email), the bank reference
/// (FT...), the balance after the payment (a re-post reports the same balance, two real payments never do), and only
/// then this notification's own key. Re-posts without any of these are caught by [captureFingerprint].
String notifyCommandId(CapturedNotification n, {String? accountId}) {
  final p = n.parsed;
  final code = p.txCode;
  if (code != null) {
    return const Uuid().v5(_ns, 'moma-notify-tx|${n.package}|$code');
  }
  final ref = p.bankRef;
  if (ref != null && ref.isNotEmpty) {
    return const Uuid().v5(_ns, 'moma-notify-ref|${n.package}|$ref');
  }
  final balance = p.balance;
  if (balance != null && p.amount != null && p.direction != null) {
    // + the day: out 25k, in 25k, out 25k can land on the same balance again, but not across a re-post's minutes.
    final d = n.postTime.toLocal();
    return const Uuid().v5(
      _ns,
      'moma-notify-bal|${n.package}|${accountId ?? ''}|${p.direction!.name}|${p.amount}|$balance|${d.year}-${d.month}-${d.day}',
    );
  }
  return const Uuid().v5(_ns, 'moma-notify|${n.package}|${n.key}');
}

/// True when [notifyCommandId] could only use the notification key (no code, reference or balance).
bool needsFingerprint(CapturedNotification n) {
  final p = n.parsed;
  return p.txCode == null &&
      (p.bankRef == null || p.bankRef!.isEmpty) &&
      (p.balance == null || p.amount == null || p.direction == null);
}

// Times and dates change between two copies of one notification; everything else (amounts, codes) must match.
final _timeOrDate = RegExp(
  r'\b\d{1,2}[:h]\d{2}(?::\d{2})?\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b',
);

/// What two copies of one notification share: app, direction, amount and the text without times / dates, folded
/// (no diacritics, lower case, single spaces).
String captureFingerprint(
  CapturedNotification n, {
  required int amount,
  required NotifyDirection direction,
}) {
  final text = foldVietnamese(
    '${n.title} ${n.text}'.replaceAll(_timeOrDate, ' '),
  ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return '${n.package}|${direction.name}|$amount|$text';
}

/// Recently recorded notifications that had no unique code (local, this phone only): a re-post within
/// [window] with the same fingerprint reuses the first command id. Bounded to the last [max] entries.
class RecentCaptures {
  RecentCaptures([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'notify_recent_fingerprints';
  static const window = Duration(minutes: 10);
  static const max = 100;

  Future<List<Map<String, dynamic>>> _read() async {
    try {
      final raw = await _s.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          Map<String, dynamic>.from(e as Map),
      ];
    } on Object {
      return [];
    }
  }

  /// The command id of an earlier copy posted within [window] of [at], if any.
  Future<String?> find(String fingerprint, DateTime at) async {
    for (final e in (await _read()).reversed) {
      final t = DateTime.tryParse('${e['at']}');
      if (e['fp'] == fingerprint &&
          t != null &&
          at.difference(t).abs() <= window) {
        return '${e['id']}';
      }
    }
    return null;
  }

  Future<void> remember(
    String fingerprint,
    String commandId,
    DateTime at,
  ) async {
    try {
      final list = (await _read())
        ..removeWhere((e) {
          final t = DateTime.tryParse('${e['at']}');
          return t == null || at.difference(t) > const Duration(days: 1);
        })
        ..add({
          'fp': fingerprint,
          'id': commandId,
          'at': at.toUtc().toIso8601String(),
        });
      final kept = list.length > max ? list.sublist(list.length - max) : list;
      await _s.write(key: _key, value: jsonEncode(kept));
    } on Object {
      // Best effort: the server still merges re-posts (migration 018).
    }
  }
}

/// Sends TX_CREATE for one captured notification. A matching keyword picks the category (as CSV import does);
/// otherwise the transaction goes in as unclassified money in/out for later review. Returns false when the
/// server replayed an earlier identical command (already recorded).
Future<bool> recordNotification(
  ApiClient api,
  CapturedNotification n, {
  required String accountId,
  required NotifyDirection direction,
  required int amount,
  List<Category> categories = const [],
  String? categoryId,
  String? note,
  String source = 'NOTIFICATION',
  RecentCaptures? recent,
}) async {
  final p = n.parsed;
  final income = direction == NotifyDirection.inflow;
  final text = (note ?? p.description ?? n.text).trim();
  final type = income ? 'INCOME' : 'EXPENSE';
  String? catId = categoryId;
  if (catId == null) {
    final q = parseQuickText(text);
    catId = q.categoryName == null
        ? null
        : categories
              .where((c) => c.name == q.categoryName && c.type == type)
              .firstOrNull
              ?.id;
  }
  final kind = catId != null
      ? type
      : (income ? 'UNKNOWN_CREDIT' : 'UNKNOWN_DEBIT');
  final when = n.postTime.millisecondsSinceEpoch > 0
      ? n.postTime
      : DateTime.now();
  // A re-post of a notification without any unique code reuses the first copy's command id.
  var commandId = notifyCommandId(n, accountId: accountId);
  final store = recent ?? RecentCaptures();
  String? fingerprint;
  if (needsFingerprint(n)) {
    fingerprint = captureFingerprint(n, amount: amount, direction: direction);
    final earlier = await store.find(fingerprint, when);
    if (earlier != null) commandId = earlier;
  }
  final Map<String, dynamic> r;
  try {
    r = await api.command('TX_CREATE', {
      'kind': kind,
      'account_id': accountId,
      'amount': amount.toString(),
      'effective_at': when.toUtc().toIso8601String(),
      'category_id': ?catId,
      if (text.isNotEmpty)
        'note': text.length > 1000 ? text.substring(0, 1000) : text,
      'source': source,
    }, commandId: commandId);
  } on ApiException catch (e) {
    // Same payment already recorded from another copy (its time / text differed): nothing to do.
    if (e.code == 'DUPLICATE_KEY_MISMATCH') return false;
    rethrow;
  }
  if (fingerprint != null) await store.remember(fingerprint, commandId, when);
  return r['status'] != 'REPLAYED';
}
