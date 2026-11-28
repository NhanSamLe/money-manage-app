import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models.dart';
import '../../core/network/api_client.dart';
import '../../core/planning_models.dart';
import '../../core/providers.dart';
import '../../core/storage/offline_cache.dart';
import '../banks/qr_share.dart' show vietQrAccountNumber, renderReceiveCard;
import '../budgets/budget_plan.dart' show Pacing;
import 'routine_quick.dart';

/// Pushes the numbers shown by the home-screen widgets to the native side (channel "moma/widgets").
/// Widgets never fetch by themselves; they render what was pushed last, so they also work offline.
class WidgetSync {
  WidgetSync._();

  static const channel = MethodChannel('moma/widgets');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void>? _inFlight;
  static bool _again = false;
  static StreamSubscription<AuthState>? _auth;

  /// Refreshes widget data with the app's API client. Safe to call often: concurrent calls are coalesced.
  static Future<void> refresh(WidgetRef ref) {
    if (!supported) return Future.value();
    final api = ref.read(apiProvider);
    _watchAuth(api);
    return refreshWithApi(api);
  }

  static Future<void> refreshWithApi(ApiClient api) async {
    if (!supported) return;
    if (_inFlight != null) {
      _again = true;
      return _inFlight;
    }
    final run = _run(api);
    _inFlight = run;
    try {
      await run;
    } catch (_) {
      // Widgets keep their last data.
    } finally {
      _inFlight = null;
    }
    if (_again) {
      _again = false;
      await refreshWithApi(api);
    }
  }

  static void _watchAuth(ApiClient api) {
    if (_auth != null) return;
    try {
      _auth = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
        if (s.event == AuthChangeEvent.signedOut) {
          unawaited(clear());
          // Any sign-out (also a revoked session): drop the offline copies too.
          unawaited(OfflineCache.instance.clear());
        } else if (s.event == AuthChangeEvent.signedIn) {
          unawaited(refreshWithApi(api));
        }
      });
    } catch (_) {}
  }

  static Future<T?> _try<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, dynamic>> _list(dynamic data) => [
    for (final e in data as List) Map<String, dynamic>.from(e as Map),
  ];

  static String _two(int v) => v.toString().padLeft(2, '0');

  static Future<void> _run(ApiClient api) async {
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession == null) return;
    final now = DateTime.now();
    final month = '${now.year}-${_two(now.month)}';
    final day = '$month-${_two(now.day)}';

    final results = await Future.wait<Object?>([
      _try<dynamic>(() => api.get('/reports/summary', query: {'month': month})),
      _try<dynamic>(() => api.get('/transactions', query: {'limit': '50'})),
      _try<dynamic>(() => api.get('/budgets')),
      _try<dynamic>(() => api.get('/categories')),
      _try<dynamic>(() => api.get('/accounts')),
      _try<dynamic>(() => api.get('/banks/sepay/accounts')),
      _try<dynamic>(() => api.get('/budgets/pacing')),
      _try<QuickRoutine?>(() => fetchQuickRoutine(api)),
    ]);
    final data = <String, Object?>{};
    final summaryJson = results[0];
    final txJson = results[1];

    final categories = results[3] == null ? null : _list(results[3]);
    final catName = {
      for (final c in categories ?? const <Map<String, dynamic>>[])
        '${c['id']}': '${c['name']}',
    };
    if (categories != null) data['cache_categories'] = jsonEncode(categories);
    if (results[4] != null) {
      data['cache_accounts'] = jsonEncode(_list(results[4]));
    }

    if (summaryJson != null && txJson != null) {
      final summary = Summary.fromJson(summaryJson as Map<String, dynamic>);
      final txs = _list(txJson).map(MomaTx.fromJson).toList();
      var todaySpend = 0;
      var todayCount = 0;
      final usage = <String, int>{};
      for (final t in txs) {
        if (t.isVoid) continue;
        if (t.categoryId != null) {
          usage[t.categoryId!] = (usage[t.categoryId!] ?? 0) + 1;
        }
        final d = t.effectiveAt;
        if (t.isExpense &&
            d.year == now.year &&
            d.month == now.month &&
            d.day == now.day) {
          todaySpend += t.amount;
          todayCount++;
        }
      }
      var budget = 0;
      if (results[2] != null) {
        final budgets = _list(results[2]).map(Budget.fromJson).toList();
        final overall = budgets.where((b) => b.categoryId == null).firstOrNull;
        if (overall != null) budget = overall.limit + overall.carried;
      }
      final last = txs.where((t) => !t.isVoid).firstOrNull;
      data.addAll({
        'has_data': true,
        'day': day,
        'updated_at': now.millisecondsSinceEpoch,
        'today_spend': todaySpend,
        'today_count': todayCount,
        'month_spend': summary.expense,
        'budget': budget,
        'cache_cat_rank': jsonEncode(
          (usage.keys.toList()..sort((a, b) => usage[b]!.compareTo(usage[a]!))),
        ),
      });
      if (last != null) {
        final when = last.effectiveAt;
        final sameDay =
            when.year == now.year &&
            when.month == now.month &&
            when.day == now.day;
        data.addAll({
          'last_title': _title(last, catName),
          'last_amount': last.amount,
          'last_kind': last.isIncome
              ? 'in'
              : last.isExpense
              ? 'out'
              : 'transfer',
          'last_time': sameDay
              ? '${_two(when.hour)}:${_two(when.minute)}'
              : '${_two(when.day)}/${_two(when.month)}',
        });
      } else {
        data['last_title'] = '';
      }
    }

    Uint8List? png;
    Uint8List? card;
    if (results[5] != null) {
      final linked = _list(results[5]).where((a) => a['linked'] == true);
      if (linked.isEmpty) {
        data['qr_state'] = 'unlinked';
      } else {
        final a = linked.first;
        final qr = await _try<dynamic>(
          () => api.get(
            '/banks/sepay/qr',
            query: {'external_id': '${a['external_id']}'},
          ),
        );
        if (qr is Map && qr['payload'] != null) {
          png = await _try<Uint8List?>(() => _renderQr('${qr['payload']}'));
          card = await _try<Uint8List?>(
            () => renderReceiveCard(
              payload: '${qr['payload']}',
              bank: '${qr['bank'] ?? a['bank'] ?? ''}',
              holder: '${qr['holder'] ?? a['holder'] ?? ''}',
              accountNumber:
                  vietQrAccountNumber('${qr['payload']}') ??
                  '${a['number'] ?? ''}',
            ),
          );
          data.addAll({
            'qr_bank': '${qr['bank'] ?? a['bank'] ?? ''}',
            'qr_masked': '${qr['number_masked'] ?? a['number_masked'] ?? ''}',
            'qr_holder': '${qr['holder'] ?? a['holder'] ?? ''}',
            // Full number + QR text for the overlay's "Sao chép STK" / "Sao chép nội dung mã" and the copy icon.
            'qr_number':
                vietQrAccountNumber('${qr['payload']}') ??
                '${a['number'] ?? ''}',
            'qr_payload': '${qr['payload']}',
          });
          // Keep "ok" only when a QR image exists (new one now, or the previous file natively).
          if (png != null) data['qr_state'] = 'ok';
        }
      }
    }
    // "Hôm nay còn tiêu được ~X" (D-026) for the spending widget and the quick bar notification.
    if (results[6] is Map) {
      final pace = Pacing.fromJson((results[6] as Map).cast<String, dynamic>());
      data['safe_today'] = pace.isEmpty ? null : pace.safeToday;
      data['safe_day'] = pace.isEmpty ? null : day;
    }
    // The assistant's routine for the current slot ("Bánh mì 20k") as one-tap actions outside the app.
    final routine = results[7] as QuickRoutine?;
    data.addAll({
      'routine_slot': routine?.slot,
      'routine_q': routine?.question,
      'routine_opts': routine == null
          ? null
          : jsonEncode([for (final o in routine.options.take(3)) o.toJson()]),
      'routine_until': routine == null
          ? null
          : routineSlotEnd(routine.slot, now).millisecondsSinceEpoch,
    });
    if (data.isEmpty) return;
    // Offline the reads above came from the saved copy: keep what the widgets show (with its real update time)
    // instead of stamping old numbers as fresh. They refresh with the next online sync.
    if (NetStatus.offline) return;
    await channel.invokeMethod<void>('save', {
      'data': data,
      'qrPng': png,
      'cardPng': card,
    });
  }

  static String _title(MomaTx t, Map<String, String> catName) {
    final m = t.merchant?.trim() ?? '';
    if (m.isNotEmpty) return m;
    final n = t.note?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final c = catName[t.categoryId];
    if (c != null && c.isNotEmpty) return c;
    if (t.isIncome) return 'Khoản thu';
    if (t.isExpense) return 'Khoản chi';
    return 'Chuyển khoản';
  }

  static Future<Uint8List?> _renderQr(String payload) async {
    final painter = QrPainter(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF0B2A1F),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF0B2A1F),
      ),
    );
    final bytes = await painter.toImageData(480);
    return bytes?.buffer.asUint8List();
  }

  /// Forgets all widget numbers and the QR (on sign-out).
  static Future<void> clear() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('clear');
    } catch (_) {}
  }

  /// "Ẩn số tiền trên tiện ích" (default off).
  static Future<bool> privacy() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('getPrivacy') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setPrivacy(bool value) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('setPrivacy', {'value': value});
    } catch (_) {}
  }

  static Future<bool> canPin() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('canPin') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens MoMa's permission screen (MIUI permission editor when available).
  static Future<bool> openPermissions() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('openPermissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// "Thanh ghi nhanh" persistent notification (D-026): on/off (default off).
  static Future<bool> quickBar() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('getQuickBar') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Turns the quick bar on/off. Returns false when Android notifications are off for MoMa (bar can't show).
  static Future<bool> setQuickBar(bool value) async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('setQuickBar', {
            'value': value,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Asks Android 13+ to add the "Ghi chi nhanh" Quick Settings tile. False = add it by hand.
  static Future<bool> requestQuickTile() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('requestTile') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's notification settings for MoMa.
  static Future<void> openNotificationSettings() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }

  /// Asks the launcher to add a widget (kind: quick | spend | qr | ai).
  static Future<bool> pin(String kind) async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('pin', {'kind': kind}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<Object?> read(String key) async {
    if (!supported) return null;
    try {
      return await channel.invokeMethod<Object?>('get', {'key': key});
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, Object? value) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('set', {'key': key, 'value': value});
    } catch (_) {}
  }
}
