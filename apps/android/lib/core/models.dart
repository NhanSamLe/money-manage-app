import 'money/money.dart';

class Account {
  Account({
    required this.id,
    required this.kind,
    required this.institution,
    required this.name,
    required this.last4,
    required this.balance,
    required this.version,
  });
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    version: j['version'] as int,
    id: j['id'] as String,
    kind: j['kind'] as String,
    institution: j['institution'] as String,
    name: j['name'] as String,
    last4: j['last4'] as String?,
    balance: j['balance'] == null ? null : parseVnd(j['balance'] as String),
  );
  final String id;
  final String kind;
  final String institution;
  final String name;
  final String? last4;
  final int version;

  /// Null means the baseline is unknown: the UI must show "chưa biết", never 0.
  final int? balance;
  bool get isCard => kind == 'CREDIT_CARD';
}

class Category {
  Category({
    required this.id,
    required this.type,
    required this.name,
    required this.icon,
    required this.version,
    required this.parentId,
  });
  factory Category.fromJson(Map<String, dynamic> j) => Category(
    version: (j['version'] as int?) ?? 1,
    parentId: j['parent_id'] as String?,
    id: j['id'] as String,
    type: j['type'] as String,
    name: j['name'] as String,
    icon: j['icon'] as String?,
  );
  final String id;
  final String type;
  final String name;
  final String? icon;
  final int version;
  final String? parentId;
}

class MomaTx {
  MomaTx({
    required this.id,
    required this.kind,
    required this.status,
    required this.effectiveAt,
    required this.amount,
    required this.fee,
    required this.accountId,
    required this.toAccountId,
    required this.categoryId,
    required this.merchant,
    required this.note,
    required this.version,
    required this.rawEffectiveAt,
    required this.relatedTxId,
    required this.debtLinked,
    this.source = 'MANUAL',
    this.debtId,
  });
  factory MomaTx.fromJson(Map<String, dynamic> j) => MomaTx(
    rawEffectiveAt: j['effective_at'] as String,
    relatedTxId: j['related_tx_id'] as String?,
    debtLinked: (j['debt_linked'] as bool?) ?? false,
    debtId: j['debt_id'] as String?,
    source: (j['source'] as String?) ?? 'MANUAL',
    id: j['id'] as String,
    kind: j['kind'] as String,
    status: j['status'] as String,
    effectiveAt: DateTime.parse(j['effective_at'] as String).toLocal(),
    amount: parseVnd((j['amount'] ?? '0') as String),
    fee: parseVnd((j['fee'] ?? '0') as String),
    accountId: j['account_id'] as String?,
    toAccountId: j['to_account_id'] as String?,
    categoryId: j['category_id'] as String?,
    merchant: j['merchant'] as String?,
    note: j['note'] as String?,
    version: j['version'] as int,
  );
  final String id;
  final String kind;
  final String status;
  final DateTime effectiveAt;
  final int amount;
  final int fee;
  final String? accountId;
  final String? toAccountId;
  final String? categoryId;
  final String? merchant;
  final String? note;
  final int version;

  /// Exact server timestamp string; needed to build the next-page cursor without re-formatting.
  final String rawEffectiveAt;
  final String? relatedTxId;

  /// Debt repayments/origins can only be corrected from the debt screen.
  final bool debtLinked;

  /// The debt this LOAN_* / write-off transaction belongs to (migration 014; null on older servers).
  final String? debtId;

  /// Where the entry came from: MANUAL, BANK, AI, NOTIFICATION, IMPORT, RECURRING or SYSTEM (older servers: MANUAL).
  final String source;

  bool get isVoid => status == 'VOID';
  bool get isIncome => kind == 'INCOME' || kind == 'UNKNOWN_CREDIT';
  bool get isExpense => kind == 'EXPENSE' || kind == 'UNKNOWN_DEBIT';
}

class CategorySpend {
  CategorySpend({required this.name, required this.icon, required this.amount});
  factory CategorySpend.fromJson(Map<String, dynamic> j) => CategorySpend(
    name: j['name'] as String,
    icon: j['icon'] as String?,
    amount: parseVnd(j['amount'] as String),
  );
  final String name;
  final String? icon;
  final int amount;
}

class Summary {
  Summary({
    required this.income,
    required this.expense,
    required this.netWorth,
    required this.unknownBaselines,
    required this.byCategory,
  });
  factory Summary.fromJson(Map<String, dynamic> j) => Summary(
    income: parseVnd(j['income'] as String),
    expense: parseVnd(j['expense'] as String),
    netWorth: parseVnd(j['net_worth'] as String),
    unknownBaselines: j['accounts_unknown_baseline'] as int,
    byCategory: (j['expense_by_category'] as List<dynamic>)
        .map((e) => CategorySpend.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  final int income;
  final int expense;
  final int netWorth;

  /// Accounts whose opening balance is unknown; net worth excludes them and the UI must say so.
  final int unknownBaselines;
  final List<CategorySpend> byCategory;
}
