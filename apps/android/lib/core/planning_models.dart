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

  bool get isReceivable => direction == 'RECEIVABLE';
  bool get isOpen => state == 'OPEN' || state == 'PARTIAL';
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
