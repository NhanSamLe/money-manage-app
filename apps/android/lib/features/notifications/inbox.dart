import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';

/// One pushed notification kept by the server (migration 012): money in/out, reminders, insights, budget alerts.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.route,
    required this.createdAt,
    required this.read,
  });

  factory InboxItem.fromJson(Map<String, dynamic> j) {
    final data = (j['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final r = data['route'];
    return InboxItem(
      id: '${j['id']}',
      type: '${j['type'] ?? 'general'}',
      title: '${j['title'] ?? ''}',
      body: '${j['body'] ?? ''}',
      route: r is String && r.startsWith('/') ? r : '/notifications',
      createdAt:
          DateTime.tryParse('${j['created_at']}')?.toLocal() ?? DateTime.now(),
      read: j['read'] == true,
    );
  }

  final String id;
  final String type;
  final String title;
  final String body;
  final String route;
  final DateTime createdAt;
  final bool read;

  IconData get icon => switch (type) {
    'bank_tx' =>
      title.startsWith('Tiền vào')
          ? Symbols.south_west_rounded
          : Symbols.north_east_rounded,
    'reminder' => Symbols.restaurant_rounded,
    'insight' => Symbols.insights_rounded,
    'budget' => Symbols.pie_chart_rounded,
    'classify' => Symbols.help_rounded,
    _ => Symbols.notifications_rounded,
  };

  Color get color => switch (type) {
    'bank_tx' =>
      title.startsWith('Tiền vào') ? MomaColors.income : MomaColors.expense,
    'reminder' => const Color(0xFFE0A100),
    'insight' => const Color(0xFF2F80ED),
    'budget' => MomaColors.expense,
    'classify' => const Color(0xFFE0A100),
    _ => MomaColors.emerald,
  };
}

class Inbox {
  const Inbox({this.items = const [], this.unread = 0});
  final List<InboxItem> items;
  final int unread;
}

/// Server inbox. Never fails the bell: an unavailable endpoint (not deployed yet) simply shows nothing.
final inboxProvider = FutureProvider.autoDispose<Inbox>((ref) async {
  try {
    final r = await ref
        .read(apiProvider)
        .get('/notifications', query: {'limit': '100'});
    final m = (r as Map).cast<String, dynamic>();
    final items = [
      for (final e in (m['items'] as List? ?? const []))
        InboxItem.fromJson((e as Map).cast<String, dynamic>()),
    ];
    return Inbox(items: items, unread: (m['unread'] as num?)?.toInt() ?? 0);
  } catch (_) {
    return const Inbox();
  }
});

Future<void> markInboxRead(WidgetRef ref) async {
  try {
    await ref.read(apiProvider).post('/notifications/read', const {});
  } catch (_) {}
}

String _when(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'Hôm nay, $hm';
  if (day == today.subtract(const Duration(days: 1))) return 'Hôm qua, $hm';
  return '${two(t.day)}/${two(t.month)}/${t.year}, $hm';
}

class InboxTile extends StatelessWidget {
  const InboxTile({super.key, required this.item});
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: item.read ? pal.surface : pal.tintSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push(item.route),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CategoryAvatar(iconData: item.icon, color: item.color, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: pal.ink,
                            ),
                          ),
                        ),
                        if (!item.read)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: MomaColors.emerald,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    if (item.body.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.body,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: pal.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _when(item.createdAt),
                      style: TextStyle(fontSize: 12, color: pal.hint),
                    ),
                  ],
                ),
              ),
              Icon(Symbols.chevron_right_rounded, color: pal.muted),
            ],
          ),
        ),
      ),
    );
  }
}
