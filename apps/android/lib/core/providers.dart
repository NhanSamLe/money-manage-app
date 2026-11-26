import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'network/api_client.dart';
import 'storage/local_store.dart';

final storeProvider = Provider<LocalStore>((_) => LocalStore());
final apiProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.watch(storeProvider)),
);

List<Map<String, dynamic>> _list(dynamic data) =>
    (data as List<dynamic>).cast<Map<String, dynamic>>();

final accountsProvider = FutureProvider.autoDispose<List<Account>>((ref) async {
  final data = await ref.watch(apiProvider).get('/accounts');
  return _list(data).map(Account.fromJson).toList();
});

final categoriesProvider = FutureProvider.autoDispose<List<Category>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/categories');
  return _list(data).map(Category.fromJson).toList();
});

final summaryProvider = FutureProvider.autoDispose<Summary>((ref) async {
  final data = await ref.watch(apiProvider).get('/reports/summary');
  return Summary.fromJson(data as Map<String, dynamic>);
});

final transactionsProvider = FutureProvider.autoDispose<List<MomaTx>>((
  ref,
) async {
  final data = await ref
      .watch(apiProvider)
      .get('/transactions', query: {'limit': '100'});
  return _list(data).map(MomaTx.fromJson).toList();
});

/// Refreshes every read model after a successful command.
void refreshAll(WidgetRef ref) {
  ref.invalidate(accountsProvider);
  ref.invalidate(summaryProvider);
  ref.invalidate(transactionsProvider);
}
