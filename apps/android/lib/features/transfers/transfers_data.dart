import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';

/// One side of a possible own-account transfer (server: pf_transfer_leg_json, migration 010).
class TransferLeg {
  TransferLeg({
    required this.txId,
    required this.amount,
    required this.effectiveAt,
    required this.accountId,
    required this.accountName,
    required this.institution,
    required this.accountKind,
    this.note,
    this.merchant,
    this.source = 'MANUAL',
  });

  factory TransferLeg.fromJson(Map<String, dynamic> j) => TransferLeg(
    txId: j['tx_id'] as String,
    amount: parseVnd('${j['amount'] ?? '0'}'),
    effectiveAt: DateTime.parse(j['effective_at'] as String).toLocal(),
    accountId: j['account_id'] as String,
    accountName: (j['account_name'] as String?) ?? '',
    institution: (j['institution'] as String?) ?? '',
    accountKind: (j['account_kind'] as String?) ?? 'OTHER',
    note: j['note'] as String?,
    merchant: j['merchant'] as String?,
    source: (j['source'] as String?) ?? 'MANUAL',
  );

  final String txId;
  final int amount;
  final DateTime effectiveAt;
  final String accountId;
  final String accountName;
  final String institution;
  final String accountKind;
  final String? note;
  final String? merchant;
  final String source;

  /// Bank / notification text of this leg, if any.
  String get content {
    final n = (note ?? '').trim();
    return n.isNotEmpty ? n : (merchant ?? '').trim();
  }
}

/// A money-out and a money-in the server thinks may be the same money moving between the owner's accounts.
/// For a one-leg transfer (the other side never notifies) [out] or [inLeg] is null and [synthAccountName] names it.
class TransferPair {
  TransferPair({
    required this.id,
    required this.state,
    required this.out,
    required this.inLeg,
    this.score = 0,
    this.canUndo = false,
    this.synthAccountName,
    this.synthInstitution,
    this.synthKind,
  });

  factory TransferPair.fromJson(Map<String, dynamic> j) {
    final synth = j['synth_account'];
    return TransferPair(
      id: j['id'] as String,
      state: (j['state'] as String?) ?? 'SUGGESTED',
      score: (j['score'] as num?)?.toInt() ?? 0,
      out: j['out'] is Map<String, dynamic>
          ? TransferLeg.fromJson(j['out'] as Map<String, dynamic>)
          : null,
      inLeg: j['in'] is Map<String, dynamic>
          ? TransferLeg.fromJson(j['in'] as Map<String, dynamic>)
          : null,
      canUndo: j['can_undo'] == true,
      synthAccountName: synth is Map ? synth['account_name'] as String? : null,
      synthInstitution: synth is Map ? synth['institution'] as String? : null,
      synthKind: synth is Map ? synth['account_kind'] as String? : null,
    );
  }

  final String id;

  /// AUTO, CONFIRMED, REJECTED or SUGGESTED.
  final String state;
  final int score;
  final TransferLeg? out;
  final TransferLeg? inLeg;
  final bool canUndo;
  final String? synthAccountName;
  final String? synthInstitution;
  final String? synthKind;

  bool get isPaired => state == 'AUTO' || state == 'CONFIRMED';
  bool get oneLeg => out == null || inLeg == null;
  int get amount => (out ?? inLeg)?.amount ?? 0;
}

/// Pairs waiting for the owner's decision. Empty on any error, so Home never breaks because of it.
final transferSuggestionsProvider =
    FutureProvider.autoDispose<List<TransferPair>>((ref) async {
      final data = await ref.watch(apiProvider).get('/transfers/suggestions');
      return [
        for (final e in (data as List<dynamic>? ?? const []))
          if (e is Map<String, dynamic>) TransferPair.fromJson(e),
      ].where((p) => p.out != null && p.inLeg != null).toList();
    });

/// The pairing behind a transfer transaction, or null when it was entered by hand.
final transferPairForTxProvider = FutureProvider.autoDispose
    .family<TransferPair?, String>((ref, txId) async {
      final data = await ref.watch(apiProvider).get('/transfers/by-tx/$txId');
      return data is Map<String, dynamic> ? TransferPair.fromJson(data) : null;
    });

/// Đúng (accept=true) books one transfer; Không (false) keeps both and never asks again for that pair.
Future<void> decideTransferSuggestion(
  WidgetRef ref,
  String pairId, {
  required bool accept,
}) async {
  await ref.read(apiProvider).post('/transfers/suggestions/$pairId', {
    'accept': accept,
  });
  ref.invalidate(transferSuggestionsProvider);
  if (accept) refreshAll(ref);
}

/// "Tách ra": the transfer is reversed and the original transactions come back.
Future<void> undoTransferPair(WidgetRef ref, String pairId) async {
  await ref.read(apiProvider).post('/transfers/$pairId/undo', const {});
  ref.invalidate(transferSuggestionsProvider);
  ref.invalidate(transferPairForTxProvider);
  refreshAll(ref);
}

/// Exposed for widgets that only need the error message.
String transferErrorMessage(Object e) =>
    e is ApiException ? e.message : 'Không thực hiện được, hãy thử lại sau.';
