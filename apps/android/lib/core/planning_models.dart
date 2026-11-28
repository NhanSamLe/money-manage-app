import 'money/money.dart';

class Contact {
  Contact({required this.id, required this.alias, required this.version});
  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    id: j['id'] as String,
    alias: j['alias'] as String,
    version: j['version'] as int,
  );
  final String id;
  final String alias;
  final int version;
}

/// One repayment or write-off of a debt (migration 014). [reversed] = already undone, kept for history.
class DebtPayment {
  DebtPayment({
    required this.id,
    required this.kind,
    required this.principal,
    required this.interest,
    required this.txId,
    required this.accountId,
    required this.effectiveAt,
    required this.reversed,
  });
  factory DebtPayment.fromJson(Map<String, dynamic> j) => DebtPayment(
    id: j['id'] as String,
    kind: j['kind'] as String,
    principal: parseVnd('${j['principal'] ?? '0'}'),
    interest: parseVnd('${j['interest'] ?? '0'}'),
    txId: j['tx_id'] as String?,
    accountId: j['account_id'] as String?,
    effectiveAt: DateTime.tryParse('${j['effective_at']}')?.toLocal(),
    reversed: j['reversed'] == true,
  );
  final String id;

  /// REPAYMENT or WRITEOFF.
  final String kind;
  final int principal;
  final int interest;
  final String? txId;
  final String? accountId;
  final DateTime? effectiveAt;
  final bool reversed;

  bool get isWriteOff => kind == 'WRITEOFF';
}

class Debt {
  Debt({
    required this.id,
    required this.direction,
    required this.contactAlias,
    required this.principal,
    required this.remaining,
    required this.state,
    required this.dueDate,
    required this.overdue,
    required this.version,
    this.contactId,
    this.note,
    this.originTxId,
    this.accountId,
    this.originatedAt,
    this.payments = const [],
  });
  factory Debt.fromJson(Map<String, dynamic> j) => Debt(
    id: j['id'] as String,
    direction: j['direction'] as String,
    contactAlias: j['contact_alias'] as String,
    principal: parseVnd(j['principal'] as String),
    remaining: parseVnd(j['remaining'] as String),
    state: j['state'] as String,
    dueDate: j['due_date'] as String?,
    overdue: j['overdue'] as bool,
    version: j['version'] as int,
    contactId: j['contact_id'] as String?,
    note: j['note'] as String?,
    originTxId: j['origin_tx_id'] as String?,
    accountId: j['account_id'] as String?,
    originatedAt: DateTime.tryParse('${j['originated_at']}')?.toLocal(),
    payments: [
      for (final p in (j['payments'] as List? ?? const []))
        DebtPayment.fromJson((p as Map).cast<String, dynamic>()),
    ],
  );
  final String id;
  final String direction;
  final String contactAlias;
  final int principal;
  final int remaining;
  final String state;
  final String? dueDate;
  final bool overdue;
  final int version;
  final String? contactId;
  final String? note;
  final String? originTxId;

  /// Cash account of the origin transaction (null for a historical debt).
  final String? accountId;
  final DateTime? originatedAt;

  /// Newest first, including undone ones.
  final List<DebtPayment> payments;

  bool get isReceivable => direction == 'RECEIVABLE';
  bool get isOpen => state == 'OPEN' || state == 'PARTIAL';
  List<DebtPayment> get activePayments => [
    for (final p in payments)
      if (!p.reversed) p,
  ];

  /// The amount can change only while nothing was repaid or written off (server: DEBT_HAS_PAYMENTS).
  bool get amountEditable => activePayments.isEmpty;
}

class Goal {
  Goal({
    required this.id,
    required this.name,
    required this.target,
    required this.allocated,
    required this.state,
    required this.version,
  });
  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
    id: j['id'] as String,
    name: j['name'] as String,
    target: parseVnd(j['target'] as String),
    allocated: parseVnd(j['allocated'] as String),
    state: j['state'] as String,
    version: j['version'] as int,
  );
  final String id;
  final String name;
  final int target;
  final int allocated;
  final String state;
  final int version;

  double get progress =>
      target <= 0 ? 0 : (allocated / target).clamp(0.0, 1.0).toDouble();
}

class GoalAccount {
  GoalAccount({
    required this.accountId,
    required this.name,
    required this.available,
  });
  factory GoalAccount.fromJson(Map<String, dynamic> j) => GoalAccount(
    accountId: j['account_id'] as String,
    name: j['name'] as String,
    available: parseVnd(j['available'] as String),
  );
  final String accountId;
  final String name;
  final int available;
}

class GoalsData {
  GoalsData({required this.goals, required this.accounts});
  factory GoalsData.fromJson(Map<String, dynamic> j) => GoalsData(
    goals: (j['goals'] as List<dynamic>)
        .map((e) => Goal.fromJson(e as Map<String, dynamic>))
        .toList(),
    accounts: (j['accounts'] as List<dynamic>)
        .map((e) => GoalAccount.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  final List<Goal> goals;
  final List<GoalAccount> accounts;
}

class Budget {
  Budget({
    required this.id,
    required this.categoryId,
    required this.categoryName,
    required this.icon,
    required this.limit,
    required this.spent,
    required this.carried,
    required this.remaining,
    required this.carryover,
    required this.version,
  });
  factory Budget.fromJson(Map<String, dynamic> j) => Budget(
    id: j['id'] as String,
    categoryId: j['category_id'] as String?,
    categoryName: j['category_name'] as String,
    icon: j['icon'] as String?,
    limit: parseVnd(j['limit_amount'] as String),
    spent: parseVnd(j['spent'] as String),
    carried: parseVnd(j['carried'] as String),
    remaining: parseVnd(j['remaining'] as String),
    carryover: j['carryover'] as bool,
    version: j['version'] as int,
  );
  final String id;
  final String? categoryId;
  final String categoryName;
  final String? icon;
  final int limit;
  final int spent;
  final int carried;
  final int remaining;
  final bool carryover;
  final int version;

  int get effectiveLimit => limit + carried;
  double get usage => effectiveLimit <= 0
      ? 0
      : (spent / effectiveLimit).clamp(0.0, 1.0).toDouble();
  bool get over => remaining < 0;
}

class Occurrence {
  Occurrence({required this.id, required this.dueDate, required this.version});
  factory Occurrence.fromJson(Map<String, dynamic> j) => Occurrence(
    id: j['id'] as String,
    dueDate: j['due_date'] as String,
    version: j['version'] as int,
  );
  final String id;
  final String dueDate;
  final int version;
}

class RecurringItem {
  RecurringItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.accountId,
    required this.amount,
    required this.interval,
    required this.template,
    required this.expected,
  });
  factory RecurringItem.fromJson(Map<String, dynamic> j) => RecurringItem(
    id: j['id'] as String,
    name: j['name'] as String,
    kind: j['kind'] as String,
    accountId: j['account_id'] as String,
    amount: parseVnd(j['amount'] as String),
    interval: j['interval'] as String,
    template: (j['template'] as Map<String, dynamic>?) ?? const {},
    expected: (j['expected'] as List<dynamic>)
        .map((e) => Occurrence.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  final String id;
  final String name;
  final String kind;
  final String accountId;
  final int amount;
  final String interval;
  final Map<String, dynamic> template;
  final List<Occurrence> expected;

  String get intervalLabel => switch (interval) {
    'WEEKLY' => 'Hằng tuần',
    'MONTHLY' => 'Hằng tháng',
    _ => 'Hằng năm',
  };
}
