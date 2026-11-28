import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_client.dart';
import '../../core/planning_providers.dart';
import '../../core/providers.dart';
import 'split_models.dart';

List<Map<String, dynamic>> _list(dynamic data) => [
  for (final e in (data as List? ?? const []))
    (e as Map).cast<String, dynamic>(),
];

/// Splits of one transaction (newest first): the applied one with undo, or a pending proposal.
final txSplitsProvider = FutureProvider.autoDispose
    .family<List<SplitApplication>, String>((ref, txId) async {
      final data = await ref
          .watch(apiProvider)
          .get('/splits', query: {'tx_id': txId});
      return _list(data).map(SplitApplication.fromJson).toList();
    });

/// Pending proposals for the bell "Cần xử lý".
final pendingSplitsProvider =
    FutureProvider.autoDispose<List<SplitApplication>>((ref) async {
      try {
        final data = await ref
            .watch(apiProvider)
            .get('/splits', query: {'state': 'PROPOSED'});
        return _list(data).map(SplitApplication.fromJson).toList();
      } catch (_) {
        return const []; // never breaks the bell (offline, endpoint not deployed yet)
      }
    });

/// Recent splits (last 60 days) — used for "Nhóm hay đi".
final recentSplitsProvider = FutureProvider.autoDispose<List<SplitApplication>>(
  (ref) async {
    try {
      final data = await ref.watch(apiProvider).get('/splits');
      return _list(data).map(SplitApplication.fromJson).toList();
    } catch (_) {
      return const [];
    }
  },
);

/// Recurring rules with their split settings (GET /recurring, migration 016 fields).
final recurringRulesProvider = FutureProvider.autoDispose<List<RecurringRule>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/recurring');
  return _list(data).map(RecurringRule.fromJson).toList();
});

final ruleSuggestionsProvider =
    FutureProvider.autoDispose<List<RuleSuggestion>>((ref) async {
      try {
        final data = await ref
            .watch(apiProvider)
            .get('/splits/rule-suggestions');
        return _list(data).map(RuleSuggestion.fromJson).toList();
      } catch (_) {
        return const [];
      }
    });

void refreshSplits(WidgetRef ref, String txId) {
  ref.invalidate(txSplitsProvider(txId));
  ref.invalidate(pendingSplitsProvider);
  ref.invalidate(recentSplitsProvider);
  ref.invalidate(recurringRulesProvider);
  refreshPlanning(ref);
}

class SplitApi {
  SplitApi(this._api);
  final ApiClient _api;

  /// Confirms a proposal (optionally with edited shares) or splits directly.
  Future<void> apply({
    required String txId,
    String? applicationId,
    List<SplitShare>? shares,
    String? categoryId,
  }) => _api.post('/splits/apply', {
    'tx_id': txId,
    'application_id': ?applicationId,
    if (shares != null) 'shares': [for (final s in shares) s.toApply()],
    'category_id': ?categoryId,
  });

  Future<void> undo(String applicationId) =>
      _api.post('/splits/$applicationId/undo', const {});

  Future<void> dismiss(String applicationId) =>
      _api.post('/splits/$applicationId/dismiss', const {});

  /// Bill photo text (read on the phone) -> server analysis. See [BillAnalysis].
  Future<BillAnalysis> analyzeBill(String txId, String text) async {
    final r = await _api.post('/bills/analyze', {'tx_id': txId, 'text': text});
    return BillAnalysis.fromJson((r as Map).cast<String, dynamic>());
  }
}

final splitApiProvider = Provider<SplitApi>(
  (ref) => SplitApi(ref.watch(apiProvider)),
);

/// What the server made of a bill picture (POST /bills/analyze).
class BillAnalysis {
  const BillAnalysis({
    this.updated,
    this.suggestion,
    this.billTotal,
    this.txAmount,
    this.split = 'NONE',
    this.items,
    this.merchant,
  });

  factory BillAnalysis.fromJson(Map<String, dynamic> j) {
    final mm = (j['amount_mismatch'] as Map?)?.cast<String, dynamic>();
    final reading = (j['reading'] as Map?)?.cast<String, dynamic>() ?? const {};
    return BillAnalysis(
      updated: (j['updated'] as Map?)?.cast<String, dynamic>(),
      suggestion: (j['suggestion'] as Map?)?.cast<String, dynamic>(),
      billTotal: mm == null ? null : int.tryParse('${mm['bill_total']}'),
      txAmount: mm == null ? null : int.tryParse('${mm['tx_amount']}'),
      split: '${j['split'] ?? 'NONE'}',
      items: reading['items'] as String?,
      merchant: reading['merchant'] as String?,
    );
  }

  /// Applied in place: {category_id, merchant, note, previous: {kind, category_id, merchant, note}}.
  final Map<String, dynamic>? updated;

  /// Not sure: {category_id, merchant, note, confidence} for a one-tap confirm.
  final Map<String, dynamic>? suggestion;
  final int? billTotal;
  final int? txAmount;

  /// APPLIED (a recurring rule split it) / PROPOSED (split card) / NONE.
  final String split;
  final String? items;
  final String? merchant;

  bool get mismatch => billTotal != null && txAmount != null;
}

/// Reads the text of a picture on the phone (ML Kit, nothing leaves the device but the text). Overridable in tests.
final billTextReaderProvider = Provider<Future<String> Function(Uint8List)>(
  (ref) => readImageText,
);

Future<String> readImageText(Uint8List bytes) async {
  if (kIsWeb || !Platform.isAndroid) return '';
  final dir = await getTemporaryDirectory();
  final f = File(
    '${dir.path}/moma-bill-${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  await f.writeAsBytes(bytes, flush: true);
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    return (await recognizer.processImage(InputImage.fromFilePath(f.path)))
        .text;
  } finally {
    await recognizer.close();
    f.delete().ignore();
  }
}

/// Latest analysis per transaction (suggestion / amount mismatch cards on the detail page).
class BillAnalysisStore extends Notifier<Map<String, BillAnalysis>> {
  @override
  Map<String, BillAnalysis> build() => const {};
  void set(String txId, BillAnalysis a) => state = {...state, txId: a};
  void clear(String txId) => state = {...state}..remove(txId);
}

final billAnalysisProvider =
    NotifierProvider<BillAnalysisStore, Map<String, BillAnalysis>>(
      BillAnalysisStore.new,
    );
