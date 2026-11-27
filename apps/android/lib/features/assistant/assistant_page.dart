import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/outbox.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';

enum _Role { user, bot }

enum _Kind { text, proposal, summary }

enum _Status { pending, saved, queued, cancelled }

class _Msg {
  _Msg.user(this.text)
    : role = _Role.user,
      kind = _Kind.text,
      at = DateTime.now();
  _Msg.bot(this.text)
    : role = _Role.bot,
      kind = _Kind.text,
      at = DateTime.now();
  _Msg.proposal(this.proposal, this.text)
    : role = _Role.bot,
      kind = _Kind.proposal,
      commandId = ApiClient.newId(),
      at = DateTime.now();
  _Msg.summary(this.month, this.summary)
    : role = _Role.bot,
      kind = _Kind.summary,
      text = '',
      at = DateTime.now();

  final _Role role;
  final _Kind kind;
  final DateTime at;
  String text = '';
  Map<String, dynamic>? proposal;
  String? commandId;
  String? month;
  Summary? summary;
  _Status status = _Status.pending;
}

/// Conversation state lives for the app session only (no chat history is stored server-side).
class _Chat extends Notifier<List<_Msg>> {
  @override
  List<_Msg> build() => [];
  void add(_Msg m) => state = [...state, m];
  void touch() => state = [...state];
}

final _chatProvider = NotifierProvider<_Chat, List<_Msg>>(_Chat.new);
final _thinkingProvider = NotifierProvider<_Flag, bool>(_Flag.new);

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

/// "Trợ lý AI": the assistant only proposes; the owner confirms and the normal idempotent command path writes.
class AssistantPage extends ConsumerStatefulWidget {
  const AssistantPage({super.key});
  @override
  ConsumerState<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends ConsumerState<AssistantPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || ref.read(_thinkingProvider)) return;
    _input.clear();
    final chat = ref.read(_chatProvider.notifier);
    chat.add(_Msg.user(text));
    ref.read(_thinkingProvider.notifier).set(true);
    _toEnd();
    try {
      final data = await ref.read(apiProvider).post('/ai/chat', {
        'text': text,
      }) as Map<String, dynamic>;
      switch (data['type']) {
        case 'proposal':
          chat.add(
            _Msg.proposal(
              data['proposal'] as Map<String, dynamic>,
              '${data['reason'] ?? ''}',
            ),
          );
        case 'query_summary':
          chat.add(
            _Msg.summary(
              '${data['month']}',
              Summary.fromJson(data['summary'] as Map<String, dynamic>),
            ),
          );
        case 'ask':
          chat.add(_Msg.bot('${data['question']}'));
        default:
          chat.add(
            _Msg.bot(
              '${data['reason'] ?? 'Mình chỉ hỗ trợ ghi chép và xem tình hình tài chính cá nhân.'}',
            ),
          );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      ref.read(_thinkingProvider.notifier).set(false);
      _toEnd();
    }
  }

  Future<void> _confirm(_Msg m) async {
    final p = m.proposal!;
    final payload = <String, dynamic>{
      'kind': p['kind'],
      'account_id': p['account_id'],
      'amount': p['amount_vnd'],
      'effective_at': p['effective_at'],
      'category_id': p['category_id'],
      if ('${p['note']}'.isNotEmpty) 'note': p['note'],
    };
    try {
      await ref
          .read(apiProvider)
          .command('TX_CREATE', payload, commandId: m.commandId!);
      refreshAll(ref);
      m.status = _Status.saved;
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') {
        // Same command id is queued, so a later sync can never duplicate the transaction.
        final queued = await ref
            .read(outboxProvider.notifier)
            .add('TX_CREATE', payload, m.commandId!);
        if (queued) {
          m.status = _Status.queued;
        } else if (mounted) {
          await showErrorDialog(
            context,
            'Hàng đợi offline đã đầy. Hãy đồng bộ trước.',
          );
        }
      } else if (mounted) {
        await showErrorDialog(context, e.message);
      }
    }
    ref.read(_chatProvider.notifier).touch();
  }

  @override
  Widget build(BuildContext context) {
    final msgs = ref.watch(_chatProvider);
    final thinking = ref.watch(_thinkingProvider);
    final accounts = {
      for (final a in ref.watch(accountsProvider).value ?? <Account>[]) a.id: a,
    };
    final cats = {
      for (final c in ref.watch(categoriesProvider).value ?? <Category>[])
        c.id: c,
    };
    return MomaPage(
      title: 'Trợ lý AI',
      titleIcon: Icons.auto_awesome_outlined,
      subtitle: 'Trợ lý tài chính thông minh của bạn',
      child: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              children: [
                _BotBubble(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Chào ${_firstName()}! 👋\n',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const TextSpan(
                          text: 'Mình là Trợ lý AI của MoMa. Mình giúp bạn ghi nhanh giao dịch bằng câu nói tự nhiên và xem tình hình thu chi. Mình chỉ đề xuất, bạn xác nhận thì mới ghi vào sổ.',
                        ),
                      ],
                    ),
                  ),
                ),
                if (msgs.isEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Bạn có thể thử:',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Chip(
                        icon: Icons.restaurant_rounded,
                        color: const Color(0xFFFF8A3D),
                        text: 'Hôm nay ăn tối 200k',
                        onTap: _send,
                      ),
                      _Chip(
                        icon: Icons.account_balance_wallet_rounded,
                        color: const Color(0xFF1B8A5A),
                        text: 'Nhận lương 15 triệu',
                        onTap: _send,
                      ),
                      _Chip(
                        icon: Icons.insights_rounded,
                        color: const Color(0xFF2F80ED),
                        text: 'Tháng này tiêu bao nhiêu?',
                        onTap: _send,
                      ),
                    ],
                  ),
                ],
                for (final m in msgs) _bubble(m, accounts, cats),
                if (thinking) const _Typing(),
              ],
            ),
          ),
          _Composer(controller: _input, busy: thinking, onSend: _send),
        ],
      ),
    );
  }

  Widget _bubble(
    _Msg m,
    Map<String, Account> accounts,
    Map<String, Category> cats,
  ) {
    if (m.role == _Role.user) return _UserBubble(text: m.text, at: m.at);
    switch (m.kind) {
      case _Kind.text:
        return _BotBubble(child: Text(m.text));
      case _Kind.summary:
        final s = m.summary!;
        final mm = m.month!;
        return _BotBubble(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tháng ${mm.substring(5)}/${mm.substring(0, 4)}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              _kv('Thu nhập', '+${formatVnd(s.income)}', MomaColors.income),
              _kv('Chi tiêu', '-${formatVnd(s.expense)}', MomaColors.expense),
              _kv('Tài sản ròng', formatVnd(s.netWorth), MomaColors.ink),
              const SizedBox(height: 6),
              const Text(
                'Số liệu do hệ thống tính từ sổ cái.',
                style: TextStyle(color: MomaColors.muted, fontSize: 12),
              ),
            ],
          ),
        );
      case _Kind.proposal:
        return _ProposalCard(
          msg: m,
          account: accounts['${m.proposal!['account_id']}'],
          category: cats['${m.proposal!['category_id']}'],
          onConfirm: () => _confirm(m),
          onCancel: () {
            m.status = _Status.cancelled;
            ref.read(_chatProvider.notifier).touch();
          },
        );
    }
  }

  static Widget _kv(String k, String v, Color c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(k, style: const TextStyle(color: MomaColors.muted)),
        const Spacer(),
        Text(
          v,
          style: TextStyle(fontWeight: FontWeight.w800, color: c),
        ),
      ],
    ),
  );

  static String _firstName() {
    try {
      final u = Supabase.instance.client.auth.currentUser;
      final n = (u?.userMetadata?['display_name'] as String?)?.trim();
      if (n != null && n.isNotEmpty) return n.split(' ').last;
    } on Object {
      // fall through
    }
    return 'bạn';
  }
}

class _BotBubble extends StatelessWidget {
  const _BotBubble({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CircleAvatar(
          radius: 20,
          backgroundColor: Color(0xFFD7F0E1),
          child: Icon(
            Icons.auto_awesome_rounded,
            color: MomaColors.emerald,
            size: 22,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F5EC),
              borderRadius: BorderRadius.circular(20),
            ),
            child: DefaultTextStyle.merge(
              style: const TextStyle(
                color: MomaColors.ink,
                height: 1.4,
                fontSize: 15,
              ),
              child: child,
            ),
          ),
        ),
      ],
    ),
  );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.at});
  final String text;
  final DateTime at;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12, left: 48),
    child: Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: MomaColors.emerald,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) => const _BotBubble(
    child: SizedBox(
      width: 28,
      height: 18,
      child: LinearProgressIndicator(
        minHeight: 4,
        color: MomaColors.emerald,
        backgroundColor: Color(0xFFCDEBDC),
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.color,
    required this.text,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String text;
  final Future<void> Function([String?]) onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: () => onTap(text),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14073D33),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CategoryAvatar(iconData: icon, color: color, size: 32),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.msg,
    required this.account,
    required this.category,
    required this.onConfirm,
    required this.onCancel,
  });
  final _Msg msg;
  final Account? account;
  final Category? category;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final p = msg.proposal!;
    final expense = p['kind'] == 'EXPENSE';
    final color = expense ? MomaColors.expense : MomaColors.income;
    final amount = parseVnd('${p['amount_vnd']}');
    final when = DateTime.parse('${p['effective_at']}').toLocal();
    final whenText =
        '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')} ${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    final title = switch (msg.status) {
      _Status.pending => 'Mình hiểu như sau, bạn kiểm tra nhé:',
      _Status.saved => 'Đã ghi nhận giao dịch cho bạn ✅',
      _Status.queued => 'Đang offline: đã lưu, sẽ tự đồng bộ khi có mạng.',
      _Status.cancelled => 'Đã hủy, mình không ghi gì cả.',
    };
    return _BotBubble(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    CategoryAvatar(iconKey: category?.icon, size: 44),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            expense ? 'Chi tiêu' : 'Thu nhập',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            category?.name ?? '',
                            style: const TextStyle(color: MomaColors.muted),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${expense ? '-' : '+'}${formatVnd(amount)}',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 20),
                _row(Icons.event_outlined, 'Thời gian', whenText),
                _row(
                  Icons.account_balance_wallet_outlined,
                  'Tài khoản',
                  account?.name ?? '',
                ),
                if ('${p['note']}'.isNotEmpty)
                  _row(Icons.notes_rounded, 'Nội dung', '${p['note']}'),
              ],
            ),
          ),
          if (msg.status == _Status.pending) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: const Text('Hủy'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: onConfirm,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: const Text('Xác nhận ghi'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(IconData i, String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(i, size: 20, color: MomaColors.muted),
        const SizedBox(width: 8),
        Text(k),
        const Spacer(),
        Flexible(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: const TextStyle(color: MomaColors.muted),
          ),
        ),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSend,
  });
  final TextEditingController controller;
  final bool busy;
  final Future<void> Function([String?]) onSend;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    color: Colors.white,
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            maxLength: 600,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              counterText: '',
              hintText: 'Nhập tin nhắn cho Trợ lý AI...',
              filled: true,
              fillColor: const Color(0xFFF1F4F3),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Gửi',
          onPressed: busy ? null : () => onSend(),
          style: IconButton.styleFrom(
            backgroundColor: MomaColors.emerald,
            minimumSize: const Size(48, 48),
          ),
          icon: const Icon(Icons.send_rounded, color: Colors.white),
        ),
      ],
    ),
  );
}
