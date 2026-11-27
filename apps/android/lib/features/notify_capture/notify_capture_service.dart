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
      );
  final String key;
  final String package;
  final String title;
  final String text;
  final DateTime postTime;

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

  Future<List<CapturedNotification>> pending() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pending') ?? [];
      return [
        for (final m in list) CapturedNotification.fromMap(m as Map),
      ]..sort((a, b) => b.postTime.compareTo(a.postTime));
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

/// Local settings of the feature: which MoMa account each bank app maps to, and the auto-record switch.
class NotifyCapturePrefs {
  NotifyCapturePrefs([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _mapKey = 'notify_account_map';
  static const _autoKey = 'notify_auto_record';

  Future<Map<String, String>> accountMap() async {
    final raw = await _s.read(key: _mapKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } on Object {
      return {};
    }
  }

  Future<void> setAccount(String package, String accountId) async {
    final m = await accountMap();
    m[package] = accountId;
    await _s.write(key: _mapKey, value: jsonEncode(m));
  }

  Future<bool> autoRecord() async => await _s.read(key: _autoKey) == '1';
  Future<void> setAutoRecord(bool v) =>
      _s.write(key: _autoKey, value: v ? '1' : '0');
}

final _ns = Namespace.url.value;

/// One command id per notification: recording the same notification twice (button + auto) replays, never doubles.
String notifyCommandId(CapturedNotification n) =>
    const Uuid().v5(_ns, 'moma-notify|${n.package}|${n.key}');

/// Sends TX_CREATE for one captured notification. A matching keyword picks the category (as CSV import does);
/// otherwise the transaction goes in as unclassified money in/out for later review.
Future<void> recordNotification(
  ApiClient api,
  CapturedNotification n, {
  required String accountId,
  required NotifyDirection direction,
  required int amount,
  List<Category> categories = const [],
}) async {
  final p = n.parsed;
  final income = direction == NotifyDirection.inflow;
  final note = (p.description ?? n.text).trim();
  final q = parseQuickText(note);
  final type = income ? 'INCOME' : 'EXPENSE';
  final cat = q.categoryName == null
      ? null
      : categories
            .where((c) => c.name == q.categoryName && c.type == type)
            .firstOrNull;
  final kind = cat != null
      ? type
      : (income ? 'UNKNOWN_CREDIT' : 'UNKNOWN_DEBIT');
  final when = n.postTime.millisecondsSinceEpoch > 0
      ? n.postTime
      : DateTime.now();
  await api.command('TX_CREATE', {
    'kind': kind,
    'account_id': accountId,
    'amount': amount.toString(),
    'effective_at': when.toUtc().toIso8601String(),
    'category_id': ?cat?.id,
    if (note.isNotEmpty)
      'note': note.length > 1000 ? note.substring(0, 1000) : note,
  }, commandId: notifyCommandId(n));
}
