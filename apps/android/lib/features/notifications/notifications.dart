import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/money/money.dart';
import '../../core/outbox.dart';
import '../../core/planning_providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';
import 'inbox.dart';
import '../notify_capture/capture_state.dart' show captureNoticesProvider;
import '../classify/classify_page.dart' show unclearProvider;
import '../splits/split_api.dart' show pendingSplitsProvider;
import '../collect/collect.dart'
    show
        GoalProposal,
        Settlement,
        collectSuggestionsProvider,
        goalProposalsProvider,
        openReminder,
        showCollectSuggestionsSheet;
import '../splits/split_models.dart' show SplitApplication;
import '../transfers/duplicates.dart'
    show
        SamePayment,
        duplicateSuggestionsProvider,
        samePaymentTitle,
        showDuplicateSuggestionsSheet;

/// A reminder or alert derived from the owner's own data (no server push needed): overdue debts, budgets about to
/// be exceeded, recurring items that are due, and offline commands that still need attention.
class Notice {
  const Notice({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.route,
    this.onOpen,
  });
  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final String route;

  /// Opens something other than a route (e.g. a sheet to resolve a balance gap); [route] is the fallback.
  final void Function(BuildContext context)? onOpen;
}

final noticesProvider = Provider.autoDispose<AsyncValue<List<Notice>>>((ref) {
  final debts = ref.watch(debtsProvider);
  final budgets = ref.watch(budgetsProvider);
  final recurring = ref.watch(recurringProvider);
  final outbox = ref.watch(outboxProvider);
  final out = <Notice>[...ref.watch(captureNoticesProvider)];
  // Money the classifier could not place: one notice, opens "Chọn loại nhanh" (id changes with the count).
  final unclear = ref.watch(unclearProvider).value;
  if (unclear != null && unclear.total > 0) {
    final first = unclear.items.isEmpty ? null : unclear.items.first;
    out.insert(
      0,
      Notice(
        id: 'classify-${unclear.total}-${first?.id ?? ''}',
        icon: Symbols.help_rounded,
        color: const Color(0xFFE0A100),
        title: unclear.total == 1
            ? '1 khoản chưa rõ loại'
            : '${unclear.total} khoản chưa rõ loại',
        text: first == null
            ? 'Chạm để chọn loại nhanh.'
            : '${first.isIncome ? '+' : '-'}${formatVnd(first.amount)} ở ${first.institution.isNotEmpty ? first.institution : first.accountName}. Chạm để chọn loại, một chạm là xong.',
        route: '/classify',
      ),
    );
  }
  // One payment seen twice (bank + MoMo, a re-posted notification...): Gộp / Không trùng in a sheet.
  for (final s
      in ref.watch(duplicateSuggestionsProvider).value ??
          const <SamePayment>[]) {
    out.insert(
      0,
      Notice(
        id: 'dup-${s.id}',
        icon: Symbols.call_merge_rounded,
        color: const Color(0xFFE0A100),
        title: samePaymentTitle(s),
        text: 'Có thể là một lần trả tiền được báo 2 lần. Chạm để Gộp hoặc giữ cả hai.',
        route: '/tx/${s.keep!.txId}',
        onOpen: showDuplicateSuggestionsSheet,
      ),
    );
  }
  // Money that may be a repayment (name / amount, not certain): one sheet, one tap per item (migration 019).
  final settles =
      ref.watch(collectSuggestionsProvider).value ?? const <Settlement>[];
  if (settles.isNotEmpty) {
    out.insert(
      0,
      Notice(
        id: 'collect-${settles.length}-${settles.first.id}',
        icon: Symbols.handshake_rounded,
        color: MomaColors.income,
        title: settles.length == 1
            ? settles.first.question
            : '${settles.length} khoản có thể là tiền trả nợ',
        text: 'Chạm để xác nhận đúng người, MoMa sẽ gạch nợ giúp bạn.',
        route: '/planning?tab=0',
        onOpen: showCollectSuggestionsSheet,
      ),
    );
  }
  // "Trích X vào mục tiêu?" after a salary / an under-spent month.
  for (final p
      in ref.watch(goalProposalsProvider).value ?? const <GoalProposal>[]) {
    out.insert(
      0,
      Notice(
        id: 'goal-prop-${p.id}',
        icon: Symbols.savings_rounded,
        color: const Color(0xFF2F80ED),
        title: p.title,
        text: '${p.why}. Chạm để trích một chạm.',
        route: '/planning?tab=1',
      ),
    );
  }
  // Split proposals (recurring rule not sure enough, group bill photo): one tap on the transaction page.
  for (final s
      in ref.watch(pendingSplitsProvider).value ?? const <SplitApplication>[]) {
    out.insert(
      0,
      Notice(
        id: 'split-${s.id}',
        icon: Symbols.call_split_rounded,
        color: const Color(0xFF2F80ED),
        title: s.recurringName != null
            ? 'Có phải ${s.recurringName}? ${formatVnd(s.total)}'
            : 'Chia ${formatVnd(s.total)}?',
        text: s.shares.isEmpty
            ? 'Hóa đơn ăn chung. Chạm để chọn người chia hoặc bỏ qua.'
            : '${s.shares.map((x) => '${x.name} ${formatVnd(x.amount)}').join(', ')}. Chạm để xác nhận.',
        route: '/tx/${s.txId}',
      ),
    );
  }
  final today = DateTime.now();
  final todayKey =
      '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
  for (final d in debts.value ?? const []) {
    if (d.state != 'OPEN' && d.state != 'PARTIAL') continue;
    final person = d.contactAlias;
    if (d.overdue) {
      out.add(
        Notice(
          id: 'debt-${d.id}-overdue',
          icon: Symbols.event_busy_rounded,
          color: MomaColors.expense,
          title: d.direction == 'RECEIVABLE'
              ? 'Khoản phải thu quá hạn'
              : 'Khoản phải trả quá hạn',
          text:
              '$person ${d.direction == 'RECEIVABLE' ? 'còn nợ bạn' : 'bạn còn nợ'} ${formatVnd(d.remaining)}${d.dueDate == null ? '' : ', hạn ${d.dueDate}'}. '
              '${d.direction == 'RECEIVABLE' ? 'Chạm để nhắc kèm mã QR.' : 'Chạm để trả ngay.'}',
          route: '/planning?tab=0',
          onOpen: (c) => openReminder(c, d.id),
        ),
      );
    }
  }
  for (final b in budgets.value ?? const []) {
    final lim = b.effectiveLimit;
    if (lim <= 0) continue;
    final ratio = b.spent / lim;
    if (ratio >= 1) {
      out.add(
        Notice(
          id: 'budget-${b.id}-over',
          icon: Symbols.warning_rounded,
          color: MomaColors.expense,
          title: 'Vượt ngân sách ${b.categoryName}',
          text: 'Đã chi ${formatVnd(b.spent)} trên hạn mức ${formatVnd(lim)}.',
          route: '/planning?tab=2',
        ),
      );
    } else if (ratio >= 0.8) {
      out.add(
        Notice(
          id: 'budget-${b.id}-near',
          icon: Symbols.pie_chart_rounded,
          color: const Color(0xFFE0A100),
          title: 'Sắp hết ngân sách ${b.categoryName}',
          text:
              'Đã dùng ${(ratio * 100).round()}%, còn ${formatVnd(b.remaining)}.',
          route: '/planning?tab=2',
        ),
      );
    }
  }
  for (final r in recurring.value ?? const []) {
    for (final o in r.expected) {
      if (o.dueDate.compareTo(todayKey) <= 0) {
        out.add(
          Notice(
            id: 'rec-${o.id}',
            icon: Symbols.event_repeat_rounded,
            color: const Color(0xFF2F80ED),
            title: 'Đến hạn: ${r.name}',
            text:
                '${formatVnd(r.amount)} đến hạn ngày ${o.dueDate}. Bấm để xác nhận.',
            route: '/planning?tab=3',
          ),
        );
      }
    }
  }
  if (outbox.failed > 0) {
    out.add(
      Notice(
        id: 'outbox-failed-${outbox.failed}',
        icon: Symbols.sync_problem_rounded,
        color: MomaColors.expense,
        title: 'Có giao dịch chưa gửi được',
        text: '${outbox.failed} giao dịch cần bạn xử lý ở Trang chủ.',
        route: '/home',
      ),
    );
  } else if (outbox.waiting > 0) {
    out.add(
      Notice(
        id: 'outbox-wait-${outbox.waiting}',
        icon: Symbols.cloud_off_rounded,
        color: const Color(0xFFE0A100),
        title: 'Giao dịch đang chờ đồng bộ',
        text: '${outbox.waiting} giao dịch sẽ tự gửi khi có mạng.',
        route: '/home',
      ),
    );
  }
  if (debts.isLoading && budgets.isLoading && recurring.isLoading) {
    return const AsyncLoading();
  }
  return AsyncData(out);
});

/// Ids already opened by the user in this session; the bell dot shows when something new appears.
class _Seen extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void markAll(Iterable<String> ids) => state = {...state, ...ids};
}

final seenNoticesProvider = NotifierProvider<_Seen, Set<String>>(_Seen.new);

final unreadNoticesProvider = Provider.autoDispose<int>((ref) {
  final seen = ref.watch(seenNoticesProvider);
  final list = ref.watch(noticesProvider).value ?? const [];
  final inbox = ref.watch(inboxProvider).value?.unread ?? 0;
  return list.where((n) => !seen.contains(n.id)).length + inbox;
});

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});
  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final list = ref.read(noticesProvider).value ?? const [];
      ref.read(seenNoticesProvider.notifier).markAll(list.map((n) => n.id));
      // Opening the bell reads everything; refresh so the badge drops after the server confirms.
      await markInboxRead(ref);
      ref.invalidate(inboxProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final list = ref.watch(noticesProvider);
    final inbox = ref.watch(inboxProvider).value ?? const Inbox();
    return Scaffold(
      body: MomaPage(
        title: 'Thông báo',
        showBack: true,
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () {
              ref.invalidate(debtsProvider);
              ref.invalidate(budgetsProvider);
              ref.invalidate(recurringProvider);
              ref.invalidate(unclearProvider);
              ref.invalidate(duplicateSuggestionsProvider);
            },
          ),
          data: (items) {
            if (items.isEmpty && inbox.items.isEmpty) {
              return const EmptyState(
                icon: Symbols.notifications_rounded,
                title: 'Chưa có thông báo',
                hint: 'Tiền vào, tiền ra, nhắc nhở, tổng kết và các việc cần xử lý đều hiện ở đây.',
              );
            }
            Widget head(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
              child: Text(
                t,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: pal.muted,
                ),
              ),
            );
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(inboxProvider);
                await ref.read(inboxProvider.future);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  if (items.isNotEmpty) head('Cần xử lý'),
                  for (final n in items)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: pal.surface,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => n.onOpen != null
                            ? n.onOpen!(context)
                            : context.push(n.route),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CategoryAvatar(
                                iconData: n.icon,
                                color: n.color,
                                size: 42,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      n.title,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        color: pal.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      n.text,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        height: 1.4,
                                        color: pal.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Symbols.chevron_right_rounded,
                                color: pal.muted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (inbox.items.isNotEmpty) head('Gần đây'),
                  for (final it in inbox.items) InboxTile(item: it),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
