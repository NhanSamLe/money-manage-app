import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/header.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import '../banks/bank_connect_page.dart' show bankAccountsProvider;
import 'notify_capture_service.dart';
import 'parser.dart';

/// Opens the "Thông báo ngân hàng trên máy" page.
Future<void> openNotifyCaptureSettings(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const NotifyCapturePage()),
    );

/// Accounts a notification may be recorded into. Accounts linked through SePay are left out: their
/// transactions already arrive from the bank, recording the notification too would count them twice.
/// The account model has no "linked" flag, so a SePay link is recognised by bank account + last 4 digits.
final notifyTargetAccountsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  final accounts = await ref.watch(accountsProvider.future);
  var linkedLast4 = <String>{};
  try {
    final banks = await ref.watch(bankAccountsProvider.future);
    linkedLast4 = {
      for (final b in banks)
        if (b.linked && b.masked.length >= 4)
          b.masked.substring(b.masked.length - 4),
    };
  } on Object {
    // SePay not configured or unreachable: no account is known to be linked.
  }
  return [
    for (final a in accounts)
      if (!(a.kind == 'BANK' && a.last4 != null && linkedLast4.contains(a.last4)))
        a,
  ];
});

/// Records every pending notification whose app already has a target account (when the owner turned the
/// automatic mode on). Returns how many were recorded. Safe to call at app start: each notification has a
/// fixed command id, so a repeat replays instead of creating a second transaction.
Future<int> autoRecordNotifications(WidgetRef ref) async {
  final prefs = NotifyCapturePrefs();
  if (!await prefs.autoRecord()) return 0;
  const channel = NotifyCaptureChannel();
  final items = await channel.pending();
  if (items.isEmpty) return 0;
  final map = await prefs.accountMap();
  if (map.isEmpty) return 0;
  final List<Account> targets;
  try {
    targets = await ref.read(notifyTargetAccountsProvider.future);
  } on Object {
    return 0;
  }
  final allowed = {for (final a in targets) a.id};
  final cats = await ref
      .read(categoriesProvider.future)
      .catchError((_) => <Category>[]);
  final api = ref.read(apiProvider);
  final done = <String>[];
  for (final n in items) {
    final accountId = map[n.package];
    final p = n.parsed;
    if (accountId == null || !allowed.contains(accountId) || !p.isTransaction) {
      continue;
    }
    try {
      await recordNotification(
        api,
        n,
        accountId: accountId,
        direction: p.direction!,
        amount: p.amount!,
        categories: cats,
      );
      done.add(n.key);
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') break;
    }
  }
  await channel.ack(done);
  if (done.isNotEmpty) refreshAll(ref);
  return done.length;
}

class NotifyCapturePage extends ConsumerStatefulWidget {
  const NotifyCapturePage({super.key});
  @override
  ConsumerState<NotifyCapturePage> createState() => _NotifyCapturePageState();
}

class _NotifyCapturePageState extends ConsumerState<NotifyCapturePage>
    with WidgetsBindingObserver {
  static const _channel = NotifyCaptureChannel();
  final _prefs = NotifyCapturePrefs();
  bool? _granted;
  bool _auto = false;
  bool _loading = true;
  List<CapturedNotification> _items = const [];
  Map<String, String> _map = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(autoRecord: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the system screen where the permission is granted.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load({bool autoRecord = false}) async {
    if (autoRecord) {
      final n = await autoRecordNotifications(ref);
      if (n > 0 && mounted) showSnack(context, 'Đã tự ghi $n giao dịch.');
    }
    final granted = await _channel.isPermissionGranted();
    final items = await _channel.pending();
    final map = await _prefs.accountMap();
    final auto = await _prefs.autoRecord();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _items = items;
      _map = map;
      _auto = auto;
      _loading = false;
    });
  }

  Future<void> _skip(CapturedNotification n) async {
    await _channel.ack([n.key]);
    await _load();
  }

  Future<void> _record(CapturedNotification n) async {
    final ok = await showFormSheet<bool>(
      context,
      (_) => _RecordSheet(item: n, initialAccountId: _map[n.package]),
    );
    if (ok == true) {
      if (mounted) showSnack(context, 'Đã ghi giao dịch.');
      await _load();
    }
  }

  Future<void> _setAuto(bool v) async {
    await _prefs.setAutoRecord(v);
    setState(() => _auto = v);
    if (v) await _load(autoRecord: true);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      body: MomaPage(
        title: 'Thông báo ngân hàng trên máy',
        showBack: true,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    _Card(
                      child: Text(
                        'MoMa đọc thông báo biến động số dư của các ứng dụng ngân hàng, ví điện tử trên máy này '
                        'và gợi ý ghi thành giao dịch. Dùng cho tài khoản chưa kết nối qua SePay. '
                        'Thông báo của ứng dụng khác bị bỏ qua, không lưu lại.',
                        style: TextStyle(color: pal.muted, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
                      granted: _granted == true,
                      onGrant: _channel.openPermissionSettings,
                    ),
                    const SizedBox(height: 12),
                    _Card(
                      child: LabeledSwitch(
                        label: 'Tự động ghi khi đã chọn tài khoản',
                        help:
                            'Khi mở MoMa, các thông báo của ứng dụng đã từng được ghi vào một tài khoản sẽ tự ghi '
                            'vào tài khoản đó. Thông báo không đọc được số tiền vẫn chờ bạn xử lý.',
                        value: _auto,
                        onChanged: _setAuto,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Thông báo chờ xử lý',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: pal.muted,
                        ),
                      ),
                    ),
                    if (_items.isEmpty)
                      const EmptyState(
                        embedded: true,
                        icon: Symbols.notifications_active_rounded,
                        title: 'Chưa có thông báo nào',
                        hint:
                            'Khi có biến động số dư từ ứng dụng ngân hàng hoặc ví, thông báo sẽ hiện ở đây.',
                      )
                    else
                      for (final n in _items) ...[
                        _ItemCard(
                          item: n,
                          onRecord: () => _record(n),
                          onSkip: () => _skip(n),
                        ),
                        const SizedBox(height: 10),
                      ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.granted, required this.onGrant});
  final bool granted;
  final VoidCallback onGrant;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                granted ? Symbols.check_circle_rounded : Symbols.error_rounded,
                color: granted ? MomaColors.income : const Color(0xFFE0A100),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  granted
                      ? 'Đã cho phép đọc thông báo'
                      : 'Chưa cho phép đọc thông báo',
                  style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
                ),
              ),
            ],
          ),
          if (!granted) ...[
            const SizedBox(height: 8),
            Text(
              'Mở cài đặt, tìm MoMa trong danh sách và bật quyền truy cập thông báo.',
              style: TextStyle(color: pal.muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onGrant,
              icon: const Icon(Symbols.settings_rounded),
              label: const Text('Cấp quyền'),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onGrant,
                child: const Text('Mở cài đặt quyền'),
              ),
            ),
        ],
      ),
    );
  }
}

String _timeLabel(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ${dateLabel(t)}';

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.onRecord,
    required this.onSkip,
  });
  final CapturedNotification item;
  final VoidCallback onRecord;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final p = item.parsed;
    final inflow = p.direction == NotifyDirection.inflow;
    final amountText = p.amount == null
        ? 'Không đọc được số tiền'
        : '${p.direction == null ? '' : (inflow ? '+' : '-')}${formatVnd(p.amount!)}';
    final color = p.amount == null || p.direction == null
        ? pal.muted
        : (inflow ? MomaColors.income : MomaColors.expense);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.bank,
                  style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
                ),
              ),
              Text(
                _timeLabel(item.postTime),
                style: TextStyle(color: pal.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            amountText,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: p.amount == null ? 14 : 18,
              color: color,
            ),
          ),
          if (p.description != null) ...[
            const SizedBox(height: 4),
            Text(
              p.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: pal.ink),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            item.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: pal.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onSkip, child: const Text('Bỏ qua')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onRecord, child: const Text('Ghi lại')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Confirms one notification: target account, money in / out and amount (prefilled from the parser).
class _RecordSheet extends ConsumerStatefulWidget {
  const _RecordSheet({required this.item, this.initialAccountId});
  final CapturedNotification item;
  final String? initialAccountId;
  @override
  ConsumerState<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends ConsumerState<_RecordSheet> {
  late final NotifyParse _p = widget.item.parsed;
  late NotifyDirection _direction = _p.direction ?? NotifyDirection.outflow;
  late final _amount = TextEditingController(
    text: _p.amount == null ? '' : formatVnd(_p.amount!).replaceAll(' ₫', ''),
  );
  String? _accountId;
  String? _accountError;
  String? _amountError;
  late final FormRunner _runner = FormRunner(setState);

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(List<Account> accounts) async {
    final amount = parseVndInput(_amount.text);
    final validAccount =
        _accountId != null && accounts.any((a) => a.id == _accountId);
    setState(() {
      _accountError = validAccount ? null : 'Chọn tài khoản.';
      _amountError = amount == null || amount <= 0 ? 'Nhập số tiền.' : null;
    });
    if (!validAccount || amount == null || amount <= 0) return;
    final ok = await _runner.run(() async {
      await recordNotification(
        ref.read(apiProvider),
        widget.item,
        accountId: _accountId!,
        direction: _direction,
        amount: amount,
        categories: ref.read(categoriesProvider).value ?? const [],
      );
      await NotifyCapturePrefs().setAccount(widget.item.package, _accountId!);
      await const NotifyCaptureChannel().ack([widget.item.key]);
      refreshAll(ref);
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(categoriesProvider);
    final accounts = ref.watch(notifyTargetAccountsProvider);
    return accounts.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ErrorView(
        error: e,
        onRetry: () => ref.invalidate(notifyTargetAccountsProvider),
      ),
      data: (accs) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Ghi giao dịch từ ${_p.bank}',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          if (accs.isEmpty)
            Text(
              'Chưa có tài khoản phù hợp. Hãy thêm tài khoản ở mục Tài khoản trước.',
              style: TextStyle(color: context.pal.muted),
            )
          else
            PickField<String>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'Tài khoản'),
              errorText: _accountError,
              items: [
                for (final a in accs)
                  DropdownMenuItem(
                    value: a.id,
                    child: Text('${a.name} · ${accountKindLabel(a.kind)}'),
                  ),
              ],
              onChanged: (v) => setState(() {
                _accountId = v;
                _accountError = null;
              }),
            ),
          const SizedBox(height: 16),
          PillTabs<NotifyDirection>(
            segments: const [
              ButtonSegment(
                value: NotifyDirection.inflow,
                label: Text('Tiền vào'),
              ),
              ButtonSegment(
                value: NotifyDirection.outflow,
                label: Text('Tiền ra'),
              ),
            ],
            selected: {_direction},
            onSelectionChanged: (s) => setState(() => _direction = s.first),
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Số tiền',
            controller: _amount,
            required: true,
            icon: Symbols.payments_rounded,
            suffixText: '₫',
            keyboardType: TextInputType.number,
            errorText: _amountError,
            onChanged: (_) {
              if (_amountError != null) setState(() => _amountError = null);
            },
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              ThousandsFormatter(),
            ],
            validator: V.amount('Số tiền'),
          ),
          FormError(_runner.error),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _runner.busy || accs.isEmpty ? null : () => _save(accs),
            child: _runner.busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Ghi lại'),
          ),
        ],
      ),
    );
  }
}
