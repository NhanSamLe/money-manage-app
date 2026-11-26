import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'planning_models.dart';
import 'providers.dart';

List<Map<String, dynamic>> _list(dynamic data) =>
    (data as List<dynamic>).cast<Map<String, dynamic>>();

final contactsProvider = FutureProvider.autoDispose<List<Contact>>((ref) async {
  final data = await ref.watch(apiProvider).get('/contacts');
  return _list(data).map(Contact.fromJson).toList();
});

final debtsProvider = FutureProvider.autoDispose<List<Debt>>((ref) async {
  final data = await ref.watch(apiProvider).get('/debts');
  return _list(data).map(Debt.fromJson).toList();
});

final goalsProvider = FutureProvider.autoDispose<GoalsData>((ref) async {
  final data = await ref.watch(apiProvider).get('/goals');
  return GoalsData.fromJson(data as Map<String, dynamic>);
});

final budgetsProvider = FutureProvider.autoDispose<List<Budget>>((ref) async {
  final data = await ref.watch(apiProvider).get('/budgets');
  return _list(data).map(Budget.fromJson).toList();
});

final recurringProvider = FutureProvider.autoDispose<List<RecurringItem>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/recurring');
  return _list(data).map(RecurringItem.fromJson).toList();
});

/// Refreshes every read model touched by planning commands (they also move balances).
void refreshPlanning(WidgetRef ref) {
  refreshAll(ref);
  ref.invalidate(contactsProvider);
  ref.invalidate(debtsProvider);
  ref.invalidate(goalsProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(recurringProvider);
}
