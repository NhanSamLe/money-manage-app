import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/network/api_client.dart';
import '../../core/outbox.dart';

/// The assistant's learned routine ("Sáng nay bạn ăn gì? [Bánh mì 20k]") for surfaces outside the app: the
/// quick-entry overlay, the quick bar notification and the widgets. Same endpoint as the in-app chips
/// (features/assistant/routine_chips.dart); offline a tap is queued as the equivalent TX_CREATE with the id the
/// server derives, so it is recorded once when the phone is back online.
class QuickRoutineOption {
  const QuickRoutineOption({
    required this.key,
    required this.label,
    required this.amount,
    this.accountId,
    this.categoryId,
  });

  factory QuickRoutineOption.fromJson(Map<String, dynamic> j) =>
      QuickRoutineOption(
        key: '${j['key']}',
        label: '${j['label']}',
        amount: (j['amount'] as num?)?.toInt() ?? 0,
        accountId: j['account_id'] as String?,
        categoryId: j['category_id'] as String?,
      );

  final String key;
  final String label;
  final int amount;
  final String? accountId;
  final String? categoryId;

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'amount': amount,
    'account_id': accountId,
    'category_id': categoryId,
  };

  /// "Bánh mì 20k".
  String get chip => '$label ${_short(amount)}';
}

String _short(int n) {
  if (n >= 1000000) {
    final v = (n / 100000).round() / 10;
    final s = v == v.roundToDouble() ? v.toInt().toString() : '$v';
    return '${s.replaceAll('.', ',')}tr';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$nđ';
}

class QuickRoutine {
  const QuickRoutine({
    required this.slot,
    required this.question,
    required this.options,
  });
  final String slot;
  final String question;
  final List<QuickRoutineOption> options;
}

/// GET /v1/ai/routine?slot=now. Null when nothing to ask (no slot now, already recorded, nothing learned, error).
Future<QuickRoutine?> fetchQuickRoutine(ApiClient api) async {
  try {
    final r = await api.get('/ai/routine', query: {'slot': 'now'});
    final m = (r as Map).cast<String, dynamic>();
    final slot = m['slot'];
    if (slot is! String || m['recorded'] == true) return null;
    final options = [
      for (final o in (m['options'] as List? ?? const []))
        QuickRoutineOption.fromJson((o as Map).cast<String, dynamic>()),
    ].where((o) => o.amount > 0).toList();
    if (options.isEmpty) return null;
    return QuickRoutine(
      slot: slot,
      question: '${m['question'] ?? 'Bạn vừa chi gì?'}',
      options: options,
    );
  } catch (_) {
    return null;
  }
}

/// The copy saved by WidgetSync (keys routine_slot / routine_q / routine_opts / routine_until), or null when
/// missing, malformed or past the slot's window.
Future<QuickRoutine?> storedQuickRoutine({
  required Object? slot,
  required Object? question,
  required Object? options,
  required Object? until,
  DateTime? now,
}) async {
  if (slot is! String || options is! String) return null;
  final end = until is num ? until.toInt() : int.tryParse('$until') ?? 0;
  if ((now ?? DateTime.now()).millisecondsSinceEpoch >= end) return null;
  try {
    final list = [
      for (final o in jsonDecode(options) as List)
        QuickRoutineOption.fromJson((o as Map).cast<String, dynamic>()),
    ].where((o) => o.amount > 0).toList();
    if (list.isEmpty) return null;
    return QuickRoutine(
      slot: slot,
      question: question is String && question.isNotEmpty
          ? question
          : 'Bạn vừa chi gì?',
      options: list,
    );
  } catch (_) {
    return null;
  }
}

/// End of a slot's window (local time), mirroring the server's SLOT_WINDOW: after it the chips are stale.
DateTime routineSlotEnd(String slot, DateTime now) {
  final (h, m) = switch (slot) {
    'breakfast' => (10, 30),
    'lunch' => (14, 30),
    _ => (21, 30),
  };
  return DateTime(now.year, now.month, now.day, h, m);
}

/// Same derivation as the server's routineCommandId (sha256 -> UUID v4 layout).
String routineCommandId(String owner, String day, String slot, String key) {
  final h = sha256
      .convert(utf8.encode('moma-routine|$owner|$day|$slot|$key'))
      .toString();
  final variant = ((int.parse(h[16], radix: 16) & 0x3) | 0x8).toRadixString(16);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-$variant${h.substring(17, 20)}-${h.substring(20, 32)}';
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Records one learned option. Online: the routine endpoint (it picks account / category and dedupes). Offline:
/// queued as TX_CREATE with the server's command id. Returns the message to show; throws [ApiException] for real
/// server errors (and when offline queueing is impossible).
Future<String> recordQuickRoutine(
  ApiClient api,
  OutboxController outbox, {
  required String owner,
  required String slot,
  required QuickRoutineOption option,
  DateTime? now,
}) async {
  try {
    final r = await api.post('/ai/routine/record', {
      'slot': slot,
      'keys': [option.key],
    });
    final m = (r as Map).cast<String, dynamic>();
    return '${m['message'] ?? 'Đã ghi ${option.chip}'}';
  } on ApiException catch (e) {
    if (e.code != 'OFFLINE') rethrow;
    if (option.accountId == null || option.categoryId == null) rethrow;
    final at = now ?? DateTime.now();
    await outbox.load();
    final queued = await outbox.add('TX_CREATE', {
      'kind': 'EXPENSE',
      'account_id': option.accountId,
      'amount': '${option.amount}',
      'effective_at': at.toUtc().toIso8601String(),
      'category_id': option.categoryId,
      'note': option.label,
      'source': 'AI',
    }, routineCommandId(owner, _day(at), slot, option.key));
    if (!queued) rethrow;
    return 'Đang offline: đã lưu ${option.chip}, sẽ tự đồng bộ';
  }
}
