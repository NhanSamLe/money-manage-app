import '../../core/money/money.dart';
import '../../core/planning_models.dart';

/// One person's part of a split bill (migration 016). [contactId] null = a new person, created on confirm by [name].
class SplitShare {
  const SplitShare({
    required this.contactId,
    required this.name,
    required this.amount,
    this.debtId,
  });

  factory SplitShare.fromJson(Map<String, dynamic> j) => SplitShare(
    contactId: j['contact_id'] as String?,
    name: '${j['name'] ?? ''}',
    amount: _int(j['amount']),
    debtId: j['debt_id'] as String?,
  );

  final String? contactId;
  final String name;
  final int amount;
  final String? debtId;

  Map<String, dynamic> toApply() => {
    if (contactId != null) 'contact_id': contactId else 'name': name,
    'amount': '$amount',
  };

  SplitShare copyWith({int? amount}) => SplitShare(
    contactId: contactId,
    name: name,
    amount: amount ?? this.amount,
    debtId: debtId,
  );
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? 0}') ?? 0;

/// A split of one expense: PROPOSED (one tap to confirm), APPLIED (debts created), UNDONE, DISMISSED.
class SplitApplication {
  const SplitApplication({
    required this.id,
    required this.txId,
    required this.state,
    required this.source,
    required this.total,
    required this.ownerAmount,
    required this.shares,
    required this.canUndo,
    this.recurringId,
    this.recurringName,
    this.occurrenceId,
    this.categoryId,
    this.note,
    this.hints = const [],
    this.confidence = 0,
  });

  factory SplitApplication.fromJson(Map<String, dynamic> j) => SplitApplication(
    id: j['id'] as String,
    txId: j['tx_id'] as String,
    state: '${j['state']}',
    source: '${j['source'] ?? 'MANUAL'}',
    total: _int(j['total']),
    ownerAmount: _int(j['owner_amount']),
    shares: [
      for (final s in (j['shares'] as List? ?? const []))
        SplitShare.fromJson((s as Map).cast<String, dynamic>()),
    ],
    canUndo: j['can_undo'] == true,
    recurringId: j['recurring_id'] as String?,
    recurringName: j['recurring_name'] as String?,
    occurrenceId: j['occurrence_id'] as String?,
    categoryId: j['category_id'] as String?,
    note: j['note'] as String?,
    hints: [for (final h in (j['hints'] as List? ?? const [])) '$h'],
    confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
  );

  final String id;
  final String txId;
  final String state;
  final String source;
  final int total;
  final int ownerAmount;
  final List<SplitShare> shares;
  final bool canUndo;
  final String? recurringId;
  final String? recurringName;
  final String? occurrenceId;
  final String? categoryId;
  final String? note;
  final List<String> hints;
  final double confidence;

  bool get proposed => state == 'PROPOSED';
  bool get applied => state == 'APPLIED';

  /// "Tiền nhà", "Lẩu Hội An" or the plain bill.
  String get label => recurringName ?? note ?? 'khoản này';
}

/// The split part of a recurring rule (pf_recurring_split).
class RuleSplit {
  const RuleSplit({
    required this.windowStart,
    required this.windowEnd,
    required this.tolerancePct,
    required this.keywords,
    required this.rounding,
    required this.ownerShare,
    required this.autoApply,
    required this.participants,
  });

  factory RuleSplit.fromJson(Map<String, dynamic> j) => RuleSplit(
    windowStart: _int(j['window_start']),
    windowEnd: _int(j['window_end']),
    tolerancePct: _int(j['tolerance_pct'] ?? 10),
    keywords: [
      for (final k in (j['payee_keywords'] as List? ?? const [])) '$k',
    ],
    rounding: _int(j['rounding'] ?? 5000),
    ownerShare: j['owner_share'] != false,
    autoApply: j['auto_apply'] != false,
    participants: [
      for (final p in (j['participants'] as List? ?? const []))
        RuleParticipant.fromJson((p as Map).cast<String, dynamic>()),
    ],
  );

  final int windowStart;
  final int windowEnd;
  final int tolerancePct;
  final List<String> keywords;
  final int rounding;
  final bool ownerShare;
  final bool autoApply;
  final List<RuleParticipant> participants;
}

class RuleParticipant {
  const RuleParticipant({
    required this.contactId,
    required this.name,
    this.mode = 'EQUAL',
    this.value,
  });
  factory RuleParticipant.fromJson(Map<String, dynamic> j) => RuleParticipant(
    contactId: '${j['contact_id']}',
    name: '${j['name'] ?? ''}',
    mode: '${j['mode'] ?? 'EQUAL'}',
    value: (j['value'] as num?)?.toDouble(),
  );
  final String contactId;
  final String name;
  final String mode;
  final double? value;

  Map<String, dynamic> toJson() => {
    'contact_id': contactId,
    'mode': mode,
    if (value != null && mode != 'EQUAL') 'value': value,
  };
}

/// A recurring expense rule as listed by GET /recurring (migration 016 adds split + last automatic match).
class RecurringRule {
  const RecurringRule({
    required this.item,
    required this.version,
    required this.enabled,
    required this.nextDate,
    this.categoryId,
    this.split,
    this.last,
  });

  factory RecurringRule.fromJson(Map<String, dynamic> j) {
    final last = j['last_application'];
    return RecurringRule(
      item: RecurringItem.fromJson(j),
      version: _int(j['version'] ?? 1),
      enabled: j['enabled'] != false,
      nextDate: DateTime.tryParse('${j['next_date']}') ?? DateTime.now(),
      categoryId: ((j['template'] as Map?)?['category_id']) as String?,
      split: j['split'] is Map
          ? RuleSplit.fromJson((j['split'] as Map).cast<String, dynamic>())
          : null,
      last: last is Map ? last.cast<String, dynamic>() : null,
    );
  }

  final RecurringItem item;
  final int version;
  final bool enabled;
  final DateTime nextDate;
  final String? categoryId;
  final RuleSplit? split;
  final Map<String, dynamic>? last;

  String get windowLabel {
    final s = split;
    if (s == null) return item.intervalLabel;
    return s.windowStart == s.windowEnd
        ? 'Ngày ${s.windowStart} hằng tháng'
        : 'Ngày ${s.windowStart}–${s.windowEnd} hằng tháng';
  }
}

/// "Có vẻ bạn trả 1.600.000đ vào ngày 6 hằng tháng — tạo quy tắc?"
class RuleSuggestion {
  const RuleSuggestion({
    required this.accountId,
    required this.amount,
    required this.months,
    required this.dayMin,
    required this.dayMax,
    this.categoryId,
    this.label,
  });
  factory RuleSuggestion.fromJson(Map<String, dynamic> j) => RuleSuggestion(
    accountId: '${j['account_id']}',
    amount: _int(j['amount']),
    months: _int(j['months']),
    dayMin: _int(j['day_min']),
    dayMax: _int(j['day_max']),
    categoryId: j['category_id'] as String?,
    label: j['label'] as String?,
  );
  final String accountId;
  final int amount;
  final int months;
  final int dayMin;
  final int dayMax;
  final String? categoryId;
  final String? label;

  String get text =>
      'Có vẻ bạn trả ${formatVnd(amount)} vào ngày '
      '${dayMin == dayMax ? '$dayMin' : '$dayMin–$dayMax'} hằng tháng — tạo quy tắc?';
}

const kRoundings = [0, 1000, 5000, 10000];

int roundUpTo(double x, int step) =>
    step <= 0 ? x.ceil() : ((x / step).ceil() * step);

/// Same math as the server (apps/api/src/modules/split/split.ts computeShares), for the live preview.
/// Returns each participant's amount (same order) and what the owner keeps.
({List<int> shares, int owner}) computeShares(
  int total,
  List<({String mode, double? value})> participants, {
  bool ownerShare = true,
  int rounding = 5000,
}) {
  final out = List<int>.filled(participants.length, 0);
  var fixed = 0;
  for (var i = 0; i < participants.length; i++) {
    final p = participants[i];
    if (p.mode == 'FIXED') {
      out[i] = (p.value ?? 0).round();
    } else if (p.mode == 'PERCENT') {
      final v = roundUpTo(total * (p.value ?? 0) / 100, rounding);
      out[i] = v > total ? total : v;
    }
    fixed += out[i];
  }
  final equal = [
    for (var i = 0; i < participants.length; i++)
      if (participants[i].mode == 'EQUAL') i,
  ];
  final people = equal.length + (ownerShare ? 1 : 0);
  if (equal.isNotEmpty && people > 0 && fixed <= total) {
    final each = roundUpTo((total - fixed) / people, rounding);
    for (final i in equal) {
      out[i] = each;
    }
    var excess = out.fold<int>(0, (a, b) => a + b) - total;
    for (var k = equal.length - 1; k >= 0 && excess > 0; k--) {
      final cut = excess < out[equal[k]] ? excess : out[equal[k]];
      out[equal[k]] -= cut;
      excess -= cut;
    }
  }
  final sum = out.fold<int>(0, (a, b) => a + b);
  return (shares: out, owner: total - sum);
}

/// "Nam 535.000 · Lan 535.000 · Bạn 530.000"
String splitPreviewLine(List<String> names, List<int> amounts, int owner) {
  String n(int v) =>
      formatVnd(v).replaceAll(' ₫', '').replaceAll('₫', '').trim();
  return [
    for (var i = 0; i < names.length; i++) '${names[i]} ${n(amounts[i])}',
    if (owner > 0) 'Bạn ${n(owner)}',
  ].join(' · ');
}

/// Who usually shares bills with the owner: the people of the most recent applied split (most frequent first).
List<Contact> usualGroup(
  List<SplitApplication> recent,
  List<Contact> contacts,
) {
  final counts = <String, int>{};
  for (final a in recent.where((a) => a.applied)) {
    for (final s in a.shares) {
      final id = s.contactId;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
  }
  final ids = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return [for (final id in ids.take(6)) ...contacts.where((c) => c.id == id)];
}
