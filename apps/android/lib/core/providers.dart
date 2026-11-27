import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/widgets/widget_sync.dart';
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

/// Selected report month as `YYYY-MM` (local Vietnam calendar month).
class SelectedMonth extends Notifier<String> {
  @override
  String build() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}';
  }

  void set(String month) => state = month;

  void shift(int months) {
    final y = int.parse(state.substring(0, 4));
    final m = int.parse(state.substring(5, 7));
    final d = DateTime(y, m + months);
    state =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  }
}

final selectedMonthProvider = NotifierProvider<SelectedMonth, String>(
  SelectedMonth.new,
);

final summaryProvider = FutureProvider.autoDispose<Summary>((ref) async {
  final month = ref.watch(selectedMonthProvider);
  final data = await ref
      .watch(apiProvider)
      .get('/reports/summary', query: {'month': month});
  return Summary.fromJson(data as Map<String, dynamic>);
});

class TxList {
  const TxList(this.items, {required this.hasMore});
  final List<MomaTx> items;
  final bool hasMore;
}

const _pageSize = 50;

/// Cursor paging, newest first. Keeps what is already loaded when "load more" fails.
class TransactionsNotifier extends AsyncNotifier<TxList> {
  @override
  Future<TxList> build() => _fetch(const []);

  Future<TxList> _fetch(List<MomaTx> existing) async {
    final query = <String, String>{'limit': '$_pageSize'};
    if (existing.isNotEmpty) {
      final last = existing.last;
      query['cursor'] = base64Url
          .encode(
            utf8.encode(jsonEncode({'at': last.rawEffectiveAt, 'id': last.id})),
          )
          .replaceAll('=', '');
    }
    final data = await ref.read(apiProvider).get('/transactions', query: query);
    final page = _list(data).map(MomaTx.fromJson).toList();
    return TxList([...existing, ...page], hasMore: page.length == _pageSize);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore) return;
    try {
      state = AsyncData(await _fetch(current.items));
    } on ApiException {
      state = AsyncData(TxList(current.items, hasMore: current.hasMore));
      rethrow;
    }
  }
}

final transactionsProvider =
    AsyncNotifierProvider.autoDispose<TransactionsNotifier, TxList>(
      TransactionsNotifier.new,
    );

/// Refreshes every read model after a successful command.
void refreshAll(WidgetRef ref) {
  ref.invalidate(accountsProvider);
  ref.invalidate(summaryProvider);
  ref.invalidate(transactionsProvider);
  WidgetSync.refresh(ref).ignore(); // keep home-screen widgets in step
}

/// Selected bottom-navigation tab of the main shell (lets Home jump to "Giao dịch" etc.).
class ShellTab extends Notifier<int> {
  @override
  int build() => 0;
  void select(int i) => state = i;
}

final shellTabProvider = NotifierProvider<ShellTab, int>(ShellTab.new);

/// Owner profile (display name etc.) from the API; the greeting and settings read the name from here.
final profileProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/profile');
  return data as Map<String, dynamic>;
});

/// First word group the owner is called by (last word of the display name), or a neutral fallback.
String callName(Map<String, dynamic>? profile, {String fallback = 'bạn'}) {
  final n = (profile?['display_name'] as String?)?.trim() ?? '';
  if (n.isEmpty) return fallback;
  return n.split(RegExp(r'\s+')).last;
}
