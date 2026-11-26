import 'package:moma/core/network/api_client.dart';
import 'package:moma/core/storage/local_store.dart';

/// In-memory stand-in for the MoMa API used by widget tests. Records every command it receives.
class FakeApi extends ApiClient {
  FakeApi({Map<String, dynamic>? data})
    : data = data ?? defaultData(),
      super(LocalStore());

  final Map<String, dynamic> data;
  final List<({String type, Map<String, dynamic> payload, String id})>
  commands = [];

  /// When set, the next command throws this instead of succeeding.
  ApiException? failNext;

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (!data.containsKey(path)) {
      throw ApiException('NOT_FOUND', 'Không có dữ liệu giả cho $path');
    }
    return data[path];
  }

  @override
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    commands.add((type: type, payload: payload, id: commandId));
    return {
      'status': 'COMMITTED',
      'tx_id': 'tx-new',
      'contact_id': 'contact-new',
    };
  }

  static Map<String, dynamic> defaultData() => {
    '/accounts': [
      {
        'id': 'a1',
        'kind': 'BANK',
        'institution': 'VCB',
        'name': 'Vietcombank',
        'last4': '8301',
        'balance': '10000000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
      {
        'id': 'a2',
        'kind': 'CASH',
        'institution': 'Ví',
        'name': 'Tiền mặt',
        'last4': null,
        'balance': '500000',
        'version': 1,
        'archived': false,
        'baseline_known': true,
      },
    ],
    '/categories': [
      {
        'id': 'c-food',
        'type': 'EXPENSE',
        'name': 'Ăn uống',
        'icon': 'restaurant',
        'parent_id': null,
        'version': 1,
      },
      {
        'id': 'c-move',
        'type': 'EXPENSE',
        'name': 'Di chuyển',
        'icon': 'directions_car',
        'parent_id': null,
        'version': 1,
      },
      {
        'id': 'c-salary',
        'type': 'INCOME',
        'name': 'Lương',
        'icon': 'payments',
        'parent_id': null,
        'version': 1,
      },
    ],
    '/reports/summary': {
      'income': '15000000',
      'expense': '250000',
      'net_worth': '10250000',
      'receivable': '0',
      'payable': '0',
      'accounts_unknown_baseline': 1,
      'expense_by_category': [
        {
          'category_id': 'c-food',
          'name': 'Ăn uống',
          'icon': 'restaurant',
          'amount': '250000',
        },
      ],
    },
    '/transactions': [
      {
        'id': 't1',
        'kind': 'EXPENSE',
        'status': 'POSTED',
        'effective_at': '2026-11-27T05:00:00+00:00',
        'amount': '65000',
        'fee': '0',
        'account_id': 'a1',
        'to_account_id': null,
        'category_id': 'c-food',
        'merchant': 'Cơm trưa',
        'note': null,
        'version': 2,
        'related_tx_id': null,
        'contact_id': null,
        'debt_linked': false,
      },
      {
        'id': 't2',
        'kind': 'INCOME',
        'status': 'POSTED',
        'effective_at': '2026-11-26T02:00:00+00:00',
        'amount': '15000000',
        'fee': '0',
        'account_id': 'a1',
        'to_account_id': null,
        'category_id': 'c-salary',
        'merchant': null,
        'note': 'Lương T11',
        'version': 2,
        'related_tx_id': null,
        'contact_id': null,
        'debt_linked': false,
      },
      {
        'id': 't3',
        'kind': 'LOAN_COLLECTED',
        'status': 'POSTED',
        'effective_at': '2026-11-25T02:00:00+00:00',
        'amount': '200000',
        'fee': '0',
        'account_id': 'a1',
        'to_account_id': null,
        'category_id': null,
        'merchant': null,
        'note': null,
        'version': 2,
        'related_tx_id': null,
        'contact_id': 'k1',
        'debt_linked': true,
      },
    ],
    '/contacts': [
      {'id': 'k1', 'alias': 'Nam', 'note': null, 'version': 1},
    ],
    '/debts': [
      {
        'id': 'd1',
        'direction': 'RECEIVABLE',
        'contact_id': 'k1',
        'contact_alias': 'Nam',
        'principal': '500000',
        'remaining': '300000',
        'state': 'PARTIAL',
        'due_date': '2026-11-20',
        'originated_at': '2026-11-10T00:00:00Z',
        'note': null,
        'version': 3,
        'overdue': true,
      },
    ],
    '/goals': {
      'goals': [
        {
          'id': 'g1',
          'name': 'Du lịch Đà Lạt',
          'target': '5000000',
          'allocated': '1000000',
          'state': 'ACTIVE',
          'due_date': null,
          'version': 2,
        },
      ],
      'accounts': [
        {'account_id': 'a2', 'name': 'Tiền mặt', 'available': '500000'},
      ],
    },
    '/budgets': [
      {
        'id': 'b1',
        'category_id': 'c-food',
        'category_name': 'Ăn uống',
        'icon': 'restaurant',
        'limit_amount': '1000000',
        'carryover': false,
        'version': 1,
        'spent': '1200000',
        'carried': '0',
        'remaining': '-200000',
      },
    ],
    '/recurring': [
      {
        'id': 'r1',
        'name': 'Netflix',
        'kind': 'EXPENSE',
        'account_id': 'a1',
        'amount': '70000',
        'interval': 'MONTHLY',
        'next_date': '2026-11-28',
        'enabled': true,
        'template': {'category_id': 'c-food'},
        'version': 1,
        'expected': [
          {'id': 'o1', 'due_date': '2026-11-28', 'version': 1},
        ],
      },
    ],
  };
}
