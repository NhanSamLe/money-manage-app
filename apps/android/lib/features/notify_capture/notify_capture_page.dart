import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/account_presets.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/header.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/moma_switch.dart';
import '../../core/ui/select_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import '../accounts/sync/detected_apps.dart';
import '../accounts/sync/sync_sources.dart'
    show BankLink, bankLinksProvider, notifySyncStateProvider;
import 'capture_engine.dart';
import 'capture_state.dart';
import 'notify_capture_service.dart';
import 'parser.dart';

export 'capture_state.dart' show autoRecordNotifications;

/// Opens the "Thông báo ngân hàng trên máy" page.
Future<void> openNotifyCaptureSettings(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const NotifyCapturePage()));

/// Accounts a notification may be recorded into. Accounts linked through SePay are left out: their
/// transactions already arrive from the bank, recording the notification too would count them twice.
final notifyTargetAccountsProvider = FutureProvider.autoDispose<List<Account>>((
  ref,
) async {
  final accounts = await ref.watch(accountsProvider.future);
  final links = await ref
      .watch(bankLinksProvider.future)
      .catchError((_) => <BankLink>[]);
  final linked = {for (final l in links) l.accountId};
  return [
    for (final a in accounts)
      if (!linked.contains(a.id)) a,
  ];
});

class NotifyCapturePage extends ConsumerStatefulWidget {
  const NotifyCapturePage({super.key});
  @override
  ConsumerState<NotifyCapturePage> createState() => _NotifyCapturePageState();
}

class _NotifyCapturePageState extends ConsumerState<NotifyCapturePage>
    with WidgetsBindingObserver {
  static const _channel = NotifyCaptureChannel();
  bool? _granted;
  bool _auto = true;
  bool _walletReminder = true;
  bool _loading = true;
  List<CapturedNotification> _items = const [];
  Map<String, String> _map = const {};

  NotifyCapturePrefs get _prefs => ref.read(notifyCapturePrefsProvider);

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
    if (state == AppLifecycleState.resumed) _load(autoRecord: true);
  }

  Future<void> _load({bool autoRecord = false}) async {
    if (autoRecord) {
      try {
        final n = await autoRecordNotifications(ref);
        if (n > 0 && mounted) showSnack(context, 'Đã tự ghi $n giao dịch.');
      } on Object {
        // Offline or not signed in: the items stay below.
      }
    }
    final granted = await _channel.isPermissionGranted();
    final items = await _channel.pending();
    final map = await _prefs.accountMap();
    final auto = await _prefs.autoRecord();
    final reminder = await _prefs.walletReminder();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _items = items;
      _map = map;
      _auto = auto;
      _walletReminder = reminder;
      _loading = false;
    });
    ref.invalidate(notifySyncStateProvider);
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

  Future<void> _setReminder(bool v) async {
    await _prefs.setWalletReminder(v);
    ref.invalidate(walletsToUpdateProvider);
    setState(() => _walletReminder = v);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final gaps = ref.watch(balanceGapsProvider).value ?? const <BalanceGap>[];
    return Scaffold(
      body: MomaPage(
        title: 'Thông báo ngân hàng trên máy',
        showBack: true,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _load(autoRecord: true),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'MoMa đọc thông báo biến động số dư của các ứng dụng ngân hàng, ví điện tử trên máy này '
                            'và tự ghi thành giao dịch, cả khi không mở MoMa. Tài khoản đã kết nối qua SePay được bỏ qua. '
                            'Thông báo của ứng dụng khác bị bỏ qua, không lưu lại.',
                            style: TextStyle(color: pal.muted, height: 1.4),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'MoMo: xác thực email trong MoMo và bật thông báo Gmail để tự ghi khoản chi.',
                            style: TextStyle(
                              color: pal.ink,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
                      granted: _granted == true,
                      onGrant: _channel.openPermissionSettings,
                    ),
                    const SizedBox(height: 12),
                    const DetectedAppsCard(),
                    const SizedBox(height: 12),
                    _Card(
                      child: Column(
                        children: [
                          _SwitchRow(
                            switchKey: const ValueKey('auto-record'),
                            label: 'Tự động ghi',
                            help:
                                'Mỗi thông báo đọc được số tiền được ghi ngay vào tài khoản của ứng dụng đó; chưa có '
                                'tài khoản thì MoMa tạo, số dư lấy theo thông báo. Thông báo không đọc được số tiền '
                                'chờ bạn ghi bên dưới.',
                            value: _auto,
                            onChanged: _setAuto,
                          ),
                          const SizedBox(height: 10),
                          _SwitchRow(
                            switchKey: const ValueKey('wallet-reminder'),
                            label: 'Nhắc cập nhật số dư ví hằng tuần',
                            help: 'Ví như MoMo không báo mọi khoản chi. Mỗi tuần MoMa nhắc bạn nhập số dư ví để tìm khoản chưa ghi.',
                            value: _walletReminder,
                            onChanged: _setReminder,
                          ),
                        ],
                      ),
                    ),
                    if (gaps.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _SectionTitle('Khoản chưa ghi theo số dư'),
                      for (final g in gaps) ...[
                        _GapCard(gap: g),
                        const SizedBox(height: 10),
                      ],
                    ],
                    const SizedBox(height: 16),
                    _SectionTitle('Cần bạn ghi'),
                    if (_items.isEmpty)
                      const EmptyState(
                        embedded: true,
                        icon: Symbols.notifications_active_rounded,
                        title: 'Không có thông báo chờ',
                        hint: 'Thông báo đọc được số tiền đã được tự ghi. Thông báo nào không đọc được sẽ hiện ở đây.',
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: context.pal.muted,
      ),
    ),
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.switchKey,
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
  });
  final Key switchKey;
  final String label;
  final String help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontWeight: FontWeight.w700, color: pal.ink),
              ),
              const SizedBox(height: 2),
              Text(
                help,
                style: TextStyle(fontSize: 12.5, height: 1.4, color: pal.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        MomaSwitch(key: switchKey, value: value, onChanged: onChanged),
      ],
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

class _GapCard extends StatelessWidget {
  const _GapCard({required this.gap});
  final BalanceGap gap;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => openBalanceGap(context, gap),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                gap.missingOutflow
                    ? Symbols.trending_down_rounded
                    : Symbols.trending_up_rounded,
                color: gap.missingOutflow
                    ? MomaColors.expense
                    : MomaColors.income,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  gapText(gap),
                  style: TextStyle(color: pal.ink, height: 1.35),
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
        ? 'Chưa đọc được số tiền'
        : '${p.direction == null ? '' : (inflow ? '+' : '-')}${formatVnd(p.amount!)}';
    final color = p.amount == null || p.direction == null
        ? pal.muted
        : (inflow ? MomaColors.income : MomaColors.expense);
    final heading = item.fromEmail ? 'Email ${p.bank}: ${item.title}' : p.bank;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AccountBadge(
                institution: p.bank,
                kind: 'BANK',
                package: item.package,
                size: 28,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
              FilledButton(onPressed: onRecord, child: const Text('Ghi')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Value of the account picker meaning "create an account for this app".
const _newAccount = '__new__';

/// Confirms one notification: target account (or a new one for the app), money in / out and amount (prefilled).
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
        _accountId == _newAccount ||
        (_accountId != null && accounts.any((a) => a.id == _accountId));
    setState(() {
      _accountError = validAccount ? null : 'Chọn tài khoản.';
      _amountError = amount == null || amount <= 0 ? 'Nhập số tiền.' : null;
    });
    if (!validAccount || amount == null || amount <= 0) return;
    final edited = amount != _p.amount || _direction != _p.direction;
    final ok = await _runner.run(() async {
      final api = ref.read(apiProvider);
      var id = _accountId!;
      if (id == _newAccount) {
        final spec = accountSpecForPackage(widget.item.package);
        id = await ApiCaptureLedger(api).createAccount(
          kind: spec.kind,
          institution: spec.institution,
          name: spec.name,
          last4: _p.last4,
        );
      }
      await recordNotification(
        api,
        widget.item,
        accountId: id,
        direction: _direction,
        amount: amount,
        categories: ref.read(categoriesProvider).value ?? const [],
        source: edited ? 'MANUAL' : 'NOTIFICATION',
      );
      await ref
          .read(notifyCapturePrefsProvider)
          .setAccount(widget.item.package, id);
      await const NotifyCaptureChannel().ack([widget.item.key]);
      refreshAll(ref);
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(categoriesProvider);
    final accounts = ref.watch(notifyTargetAccountsProvider);
    final brand = accountSpecForPackage(widget.item.package).name;
    return accounts.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ErrorView(
        error: e,
        onRetry: () => ref.invalidate(notifyTargetAccountsProvider),
      ),
      data: (accs) {
        if (_accountId == null) {
          final match = matchAccountForPackage(
            widget.item.package,
            accs,
            map: const {},
            linked: const {},
          );
          _accountId = match?.id ?? _newAccount;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ghi giao dịch từ ${_p.bank}',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
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
                DropdownMenuItem(
                  value: _newAccount,
                  child: Text('Tạo tài khoản $brand'),
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
              onPressed: _runner.busy ? null : () => _save(accs),
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
        );
      },
    );
  }
}
