import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';

/// "Trợ lý AI": an agent, not a chat. One sentence becomes concrete steps (record, transfer, lend, repay, budget,
/// cancel, answer). Low-risk steps run by themselves when "Tự động ghi" is on; everything else is one tap away.
/// The model only plans: every step is validated by the server and executed through the normal idempotent commands.

enum _St { pending, running, done, failed, skipped }

class _Step {
  _Step(this.json) : commandId = ApiClient.newId();
  final Map<String, dynamic> json;
  final String commandId;
  _St status = _St.pending;
  String? error;
  String? txId;
  bool undone = false;

  String get type => '${json['type']}';
  bool get isCommand => type == 'COMMAND';
  bool get low => json['risk'] == 'low';
  bool get undoable => json['undoable'] == true;
  String get title => '${json['title'] ?? ''}';
  List<String> get lines => [
    for (final l in (json['lines'] as List? ?? const [])) '$l',
  ];
  String get commandType =>
      '${(json['command'] as Map?)?['command_type'] ?? ''}';
}

class _Turn {
  _Turn.user(this.text)
    : isUser = true,
      steps = const [],
      reply = '',
      plan = const [];
  _Turn.agent(this.reply, this.steps, [this.plan = const []])
    : isUser = false,
      text = '';
  final List<Map<String, dynamic>> plan;
  final bool isUser;
  final String text;
  final String reply;
  final List<_Step> steps;
}

class _Chat extends Notifier<List<_Turn>> {
  @override
  List<_Turn> build() => [];
  void add(_Turn t) => state = [...state, t];
  void touch() => state = [...state];
}

final _chatProvider = NotifierProvider<_Chat, List<_Turn>>(_Chat.new);

class _Busy extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final _busyProvider = NotifierProvider<_Busy, bool>(_Busy.new);

/// Owner preference: let the agent record low-risk steps without asking (default on, every step can be undone).
class _Auto extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) => state = v;
}

final aiAutoProvider = NotifierProvider<_Auto, bool>(_Auto.new);

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

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  /// The agent's last plan with the status of each step, so the next sentence can continue the same task
  /// ("50k" after "which amount?") instead of starting over.
  Map<String, dynamic>? _previousPlan() {
    final turns = ref.read(_chatProvider);
    final last = turns.lastWhere(
      (t) => !t.isUser,
      orElse: () => _Turn.user(''),
    );
    if (last.isUser || last.plan.isEmpty) return null;
    String status(_Step s) {
      if (s.type == 'ASK') return 'ASKED';
      if (s.type == 'ANSWER') return 'DONE';
      return switch (s.status) {
        _St.done => 'DONE',
        _St.pending || _St.running || _St.failed => 'PENDING',
        _St.skipped => 'DONE',
      };
    }

    final steps = <Map<String, dynamic>>[];
    for (var i = 0; i < last.plan.length && i < last.steps.length; i++) {
      steps.add({
        'do': '${last.plan[i]['do']}',
        'status': status(last.steps[i]),
        'data': last.plan[i],
      });
    }
    final ask = last.steps
        .where((s) => s.type == 'ASK')
        .map((s) => '${s.json['question']}')
        .firstOrNull;
    return {'steps': steps, 'question': ?ask};
  }

  List<Map<String, String>> _history() {
    final turns = ref.read(_chatProvider);
    final tail = turns.length > 6 ? turns.sublist(turns.length - 6) : turns;
    return [
      for (final t in tail)
        {
          'role': t.isUser ? 'user' : 'agent',
          'text': (t.isUser ? t.text : t.reply).length > 280
              ? (t.isUser ? t.text : t.reply).substring(0, 280)
              : (t.isUser ? t.text : t.reply),
        },
    ];
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || ref.read(_busyProvider)) return;
    _input.clear();
    final chat = ref.read(_chatProvider.notifier);
    final history = _history();
    chat.add(_Turn.user(text));
    ref.read(_busyProvider.notifier).set(true);
    _toEnd();
    try {
      final data = await ref.read(apiProvider).post('/ai/agent', {
        'text': text,
        'auto': ref.read(aiAutoProvider),
        if (history.isNotEmpty) 'history': history,
        if (_previousPlan() != null) 'previous': _previousPlan(),
      }) as Map<String, dynamic>;
      final steps = [
        for (final a in (data['actions'] as List))
          _Step(Map<String, dynamic>.from(a as Map)),
      ];
      final turn = _Turn.agent('${data['reply'] ?? ''}', steps, [
        for (final p in (data['plan'] as List? ?? const []))
          Map<String, dynamic>.from(p as Map),
      ]);
      chat.add(turn);
      _toEnd();
      if (ref.read(aiAutoProvider)) {
        for (final s in steps.where((s) => s.isCommand && s.low)) {
          await _run(s);
        }
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      ref.read(_busyProvider.notifier).set(false);
      _toEnd();
    }
  }

  Future<void> _run(_Step s) async {
    if (s.status == _St.running || s.status == _St.done) return;
    s.status = _St.running;
    s.error = null;
    ref.read(_chatProvider.notifier).touch();
    final api = ref.read(apiProvider);
    try {
      var payload = jsonEncode((s.json['command'] as Map)['payload']);
      final pre = s.json['pre'] as Map?;
      if (pre != null) {
        final r = await api.command(
          '${pre['command_type']}',
          Map<String, dynamic>.from(pre['payload'] as Map),
          commandId: ApiClient.newId(),
        );
        payload = payload.replaceAll(
          '\$${pre['bind']}',
          '${r['${pre['bind']}']}',
        );
      }
      final res = await api.command(
        s.commandType,
        jsonDecode(payload) as Map<String, dynamic>,
        commandId: s.commandId,
      );
      s.txId = res['tx_id'] as String?;
      s.status = _St.done;
      refreshAll(ref);
      ref.invalidate(profileProvider);
    } on ApiException catch (e) {
      s.status = _St.failed;
      s.error = e.message;
    }
    ref.read(_chatProvider.notifier).touch();
  }

  Future<void> _undo(_Step s) async {
    if (s.txId == null || s.undone) return;
    try {
      await ref.read(apiProvider).command('TX_REVERSE', {
        'tx_id': s.txId,
        'reason': 'Hoàn tác từ Trợ lý AI',
        'expected_version': 1,
      }, commandId: ApiClient.newId());
      s.undone = true;
      refreshAll(ref);
      ref.read(_chatProvider.notifier).touch();
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final turns = ref.watch(_chatProvider);
    final busy = ref.watch(_busyProvider);
    final auto = ref.watch(aiAutoProvider);
    final pal = context.pal;
    return MomaPage(
      title: 'Trợ lý AI',
      titleIcon: Symbols.auto_awesome_rounded,
      child: Column(
        children: [
          Expanded(
            child: turns.isEmpty
                ? _Intro(onPick: _send)
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    children: [
                      for (final t in turns)
                        t.isUser
                            ? _UserBubble(text: t.text)
                            : _AgentTurn(
                                turn: t,
                                onRun: _run,
                                onUndo: _undo,
                                onRunAll: () async {
                                  for (final s in t.steps.where(
                                    (s) =>
                                        s.isCommand &&
                                        (s.status == _St.pending ||
                                            s.status == _St.failed),
                                  )) {
                                    await _run(s);
                                  }
                                },
                                onSkip: (s) {
                                  s.status = _St.skipped;
                                  ref.read(_chatProvider.notifier).touch();
                                },
                              ),
                      if (busy) const _Thinking(),
                    ],
                  ),
          ),
          Container(
            color: pal.surface,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => ref.read(aiAutoProvider.notifier).set(!auto),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              auto
                                  ? Symbols.bolt_rounded
                                  : Symbols.touch_app_rounded,
                              size: 18,
                              color: auto ? MomaColors.emerald : pal.muted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              auto ? 'Tự động ghi: Bật' : 'Tự động ghi: Tắt',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: auto ? MomaColors.emerald : pal.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    InkResponse(
                      radius: 18,
                      onTap: () => showInfoDialog(
                        context,
                        title: 'Tự động ghi',
                        message: 'Khi bật, Trợ lý tự ghi các khoản thu chi và chuyển khoản mà nó hiểu chắc chắn, rồi cho bạn hoàn tác nếu sai. Các việc quan trọng như công nợ, ngân sách hay hủy giao dịch luôn chờ bạn xác nhận.',
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Symbols.help_rounded,
                          size: 18,
                          color: pal.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        maxLength: 600,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: 'Nhập yêu cầu cho Trợ lý',
                          filled: true,
                          fillColor: pal.surfaceAlt,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: const BorderSide(
                              color: MomaColors.emerald,
                              width: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Gửi',
                      onPressed: busy ? null : () => _send(),
                      style: IconButton.styleFrom(
                        backgroundColor: MomaColors.emerald,
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(
                        Symbols.arrow_upward_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.onPick});
  final Future<void> Function([String?]) onPick;

  static const _chips = [
    (
      Symbols.restaurant_rounded,
      Color(0xFFFF8A3D),
      'Sáng cà phê 30k, trưa cơm 65k',
    ),
    (
      Symbols.payments_rounded,
      Color(0xFF1B8A5A),
      'Nhận lương 15 triệu vào Vietcombank',
    ),
    (Symbols.handshake_rounded, Color(0xFF8B5CF6), 'Nam mượn 500k hôm qua'),
    (Symbols.insights_rounded, Color(0xFF2F80ED), 'Tháng này tiêu bao nhiêu'),
  ];

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [MomaColors.forest, MomaColors.emerald],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Symbols.auto_awesome_rounded,
                color: MomaColors.mint,
                size: 30,
              ),
              const SizedBox(height: 10),
              const Text(
                'Bạn nói, MoMa làm',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Ghi thu chi, chuyển khoản, cho vay, thu nợ, đặt ngân sách, hủy giao dịch, xem số liệu. Một câu có thể làm nhiều việc cùng lúc.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Thử ngay',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: pal.ink,
          ),
        ),
        const SizedBox(height: 10),
        for (final c in _chips)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: pal.surface,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onPick(c.$3),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      CategoryAvatar(iconData: c.$1, color: c.$2, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          c.$3,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      Icon(
                        Symbols.north_east_rounded,
                        size: 18,
                        color: pal.muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12, left: 56),
    child: Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: MomaColors.emerald,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            height: 1.4,
          ),
        ),
      ),
    ),
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: MomaColors.emerald,
          ),
        ),
        const SizedBox(width: 10),
        Text('Đang xử lý...', style: TextStyle(color: context.pal.muted)),
      ],
    ),
  );
}

class _AgentTurn extends StatelessWidget {
  const _AgentTurn({
    required this.turn,
    required this.onRun,
    required this.onUndo,
    required this.onRunAll,
    required this.onSkip,
  });
  final _Turn turn;
  final Future<void> Function(_Step) onRun;
  final Future<void> Function(_Step) onUndo;
  final Future<void> Function() onRunAll;
  final void Function(_Step) onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final pending = turn.steps
        .where((s) => s.isCommand && s.status == _St.pending)
        .length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (turn.reply.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: pal.bubble,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  turn.reply,
                  style: TextStyle(fontSize: 14.5, height: 1.4, color: pal.ink),
                ),
              ),
            ),
          for (final s in turn.steps)
            if (s.type == 'ASK')
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 24),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: pal.bubble,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    '${s.json['question']}',
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.4,
                      color: pal.ink,
                    ),
                  ),
                ),
              )
            else if (s.type == 'ANSWER')
              _AnswerCard(json: s.json)
            else
              _ActionCard(
                step: s,
                onRun: onRun,
                onUndo: onUndo,
                onSkip: onSkip,
              ),
          if (pending > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: FilledButton(
                onPressed: onRunAll,
                child: Text('Xác nhận tất cả ($pending)'),
              ),
            ),
        ],
      ),
    );
  }
}

IconData _iconFor(String commandType) => switch (commandType) {
  'TX_CREATE' => Symbols.receipt_long_rounded,
  'TX_REVERSE' => Symbols.undo_rounded,
  'DEBT_CREATE' || 'DEBT_REPAY' => Symbols.handshake_rounded,
  'GOAL_CREATE' || 'GOAL_ALLOCATE' => Symbols.savings_rounded,
  'BUDGET_UPSERT' => Symbols.pie_chart_rounded,
  'RECURRING_UPSERT' => Symbols.event_repeat_rounded,
  'ACCOUNT_CREATE' => Symbols.account_balance_wallet_rounded,
  _ => Symbols.bolt_rounded,
};

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.step,
    required this.onRun,
    required this.onUndo,
    required this.onSkip,
  });
  final _Step step;
  final Future<void> Function(_Step) onRun;
  final Future<void> Function(_Step) onUndo;
  final void Function(_Step) onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final done = step.status == _St.done;
    final failed = step.status == _St.failed;
    final c = failed
        ? MomaColors.expense
        : (done ? MomaColors.income : MomaColors.emerald);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: failed
              ? MomaColors.expense.withValues(alpha: 0.5)
              : pal.lineSoft,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CategoryAvatar(
                iconData: _iconFor(step.commandType),
                color: c,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: pal.ink,
                        decoration: step.undone || step.status == _St.skipped
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    for (final l in step.lines)
                      Text(
                        l,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: pal.muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (step.status == _St.running)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: MomaColors.emerald,
                  ),
                )
              else if (done && !step.undone)
                const Icon(
                  Symbols.check_circle_rounded,
                  color: MomaColors.income,
                  fill: 1,
                )
              else if (step.undone)
                Text(
                  'Đã hoàn tác',
                  style: TextStyle(fontSize: 12, color: pal.muted),
                ),
            ],
          ),
          if (failed && step.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                step.error!,
                style: const TextStyle(
                  color: MomaColors.expense,
                  fontSize: 12.5,
                ),
              ),
            ),
          if (step.status == _St.pending || failed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => onSkip(step),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42),
                      ),
                      child: const Text('Bỏ qua'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => onRun(step),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                      ),
                      child: Text(failed ? 'Thử lại' : 'Xác nhận'),
                    ),
                  ),
                ],
              ),
            ),
          if (done && step.undoable && !step.undone)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onUndo(step),
                child: const Text('Hoàn tác'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.json});
  final Map<String, dynamic> json;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final what = '${json['what']}';
    final data = json['data'];
    final rows = <(String, String, Color?)>[];
    var title = 'Số liệu';
    try {
      switch (what) {
        case 'BALANCES':
          title = 'Số dư các tài khoản';
          for (final a in (data as List)) {
            final m = a as Map;
            rows.add((
              '${m['name']}',
              m['balance'] == null
                  ? 'Chưa biết'
                  : formatVnd(parseVnd('${m['balance']}')),
              null,
            ));
          }
        case 'RECENT':
          title = 'Giao dịch gần đây';
          for (final t in (data as List)) {
            final tx = MomaTx.fromJson(Map<String, dynamic>.from(t as Map));
            rows.add((
              tx.merchant?.isNotEmpty == true
                  ? tx.merchant!
                  : (tx.note ?? 'Giao dịch'),
              '${tx.isIncome
                  ? '+'
                  : tx.isExpense
                  ? '-'
                  : ''}${formatVnd(tx.amount)}',
              tx.isIncome
                  ? MomaColors.income
                  : (tx.isExpense ? MomaColors.expense : null),
            ));
          }
        case 'DEBTS':
          title = 'Công nợ đang mở';
          for (final d in (data as List)) {
            final m = d as Map;
            rows.add((
              '${m['direction'] == 'RECEIVABLE' ? 'Phải thu' : 'Phải trả'} ${m['contact_alias']}',
              formatVnd(parseVnd('${m['remaining']}')),
              null,
            ));
          }
        case 'BUDGETS':
          title = 'Ngân sách tháng';
          for (final b in (data as List)) {
            final m = b as Map;
            rows.add((
              '${m['category_name'] ?? 'Tổng'}',
              'Còn ${formatVnd(parseVnd('${m['remaining']}'))}',
              null,
            ));
          }
        case 'GOALS':
          title = 'Mục tiêu tiết kiệm';
          for (final g
              in (data as Map)['goals'] == null
                  ? (data as List)
                  : ((data)['goals'] as List)) {
            final m = g as Map;
            rows.add((
              '${m['name']}',
              '${formatVnd(parseVnd('${m['allocated']}'))} / ${formatVnd(parseVnd('${m['target']}'))}',
              null,
            ));
          }
        default:
          final s = Summary.fromJson(Map<String, dynamic>.from(data as Map));
          final mm = '${json['month']}';
          title = 'Tháng ${mm.substring(5)}/${mm.substring(0, 4)}';
          rows
            ..add(('Thu nhập', '+${formatVnd(s.income)}', MomaColors.income))
            ..add(('Chi tiêu', '-${formatVnd(s.expense)}', MomaColors.expense))
            ..add(('Tài sản ròng', formatVnd(s.netWorth), null));
      }
    } on Object {
      rows.add(('Không đọc được dữ liệu', '', null));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: pal.ink,
            ),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text('Chưa có dữ liệu.', style: TextStyle(color: pal.muted)),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.$1,
                      style: TextStyle(fontSize: 14, color: pal.muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    r.$2,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: r.$3 ?? pal.ink,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Số liệu do hệ thống tính từ sổ cái.',
            style: TextStyle(fontSize: 11.5, color: pal.muted),
          ),
        ],
      ),
    );
  }
}
