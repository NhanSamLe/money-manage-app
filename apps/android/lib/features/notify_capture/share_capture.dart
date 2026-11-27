import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/ui/select_field.dart';
import '../lock/lock_screen.dart';
import '../widgets/widget_sync.dart';
import 'capture_engine.dart';
import 'notify_capture_service.dart';
import 'parser.dart';

/// What a shared receipt / text says, ready to prefill the sheet.
class ShareDraft {
  const ShareDraft({
    required this.text,
    required this.package,
    required this.parse,
  });
  final String text;

  /// Bank / wallet named in the text (MoMo, ZaloPay, a bank), null when none.
  final String? package;
  final NotifyParse parse;
}

/// Parses a shared text (or the OCR of a shared screenshot) with the notification parser.
ShareDraft draftFromSharedText(String text) {
  final pkg = detectPackageFromText(text);
  final lines = text.trim().split('\n');
  final p = parseBankNotification(
    package: pkg ?? '',
    title: lines.first,
    text: lines.skip(1).join('\n'),
  );
  return ShareDraft(text: text, package: pkg, parse: p);
}

/// Root of the translucent share sheet (ShareReceiveActivity). [kind] = text | image | none.
class ShareCaptureApp extends StatelessWidget {
  const ShareCaptureApp({super.key, required this.kind, required this.value});
  final String kind;
  final String value;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MoMa',
    debugShowCheckedModeBanner: false,
    theme: buildMomaTheme(),
    darkTheme: buildMomaTheme(Brightness.dark),
    color: Colors.transparent,
    home: ShareCaptureOverlay(kind: kind, value: value),
  );
}

Future<void> _close() async {
  try {
    await WidgetSync.channel.invokeMethod<void>('finish');
  } catch (_) {
    await SystemNavigator.pop();
  }
}

/// Reads the shared receipt (OCR on the device for images), then a compact form: account (matched wallet / bank),
/// money in / out, amount, note, category. "Lưu" records TX_CREATE (source NOTIFICATION, or MANUAL when edited)
/// and checks a reported balance the same way notifications do.
class ShareCaptureOverlay extends ConsumerStatefulWidget {
  const ShareCaptureOverlay({
    super.key,
    required this.kind,
    required this.value,
    this.readImage,
  });
  final String kind;
  final String value;

  /// OCR override for tests.
  final Future<String> Function(String path)? readImage;
  @override
  ConsumerState<ShareCaptureOverlay> createState() =>
      _ShareCaptureOverlayState();
}

class _ShareCaptureOverlayState extends ConsumerState<ShareCaptureOverlay> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  ShareDraft? _draft;
  List<Account> _accounts = const [];
  List<Category> _categories = const [];
  String? _accountId;
  String? _categoryId;
  NotifyDirection _direction = NotifyDirection.outflow;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _amountError;
  String? _doneText;

  static const _newAccount = '__new__';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<String> _ocr(String path) async {
    final r = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      return (await r.processImage(InputImage.fromFilePath(path))).text;
    } finally {
      await r.close();
    }
  }

  Future<void> _start() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (!await ensureUnlocked(context)) {
      await _close();
      return;
    }
    try {
      final text = switch (widget.kind) {
        'image' => await (widget.readImage ?? _ocr)(widget.value),
        'text' => widget.value,
        _ => '',
      };
      final draft = draftFromSharedText(text);
      final api = ref.read(apiProvider);
      final ledger = ApiCaptureLedger(api);
      final accounts = await ledger.accounts();
      final linked = await ledger.linkedAccountIds().catchError(
        (_) => <String>{},
      );
      final cats = await ledger.categories().catchError((_) => <Category>[]);
      final map = await NotifyCapturePrefs().accountMap();
      final p = draft.parse;
      String? accountId;
      final pkg = draft.package;
      if (pkg != null) {
        final mapped = map[pkg];
        accountId = mapped != null && accounts.any((a) => a.id == mapped)
            ? mapped
            : matchAccountForPackage(
                pkg,
                accounts,
                map: map,
                linked: linked,
              )?.id;
        accountId ??= _newAccount;
      }
      final type = p.direction == NotifyDirection.inflow ? 'INCOME' : 'EXPENSE';
      final q = parseQuickText(p.description ?? text);
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _accounts = [
          for (final a in accounts)
            if (!linked.contains(a.id)) a,
        ];
        _categories = cats;
        _accountId = accountId ?? _accounts.firstOrNull?.id;
        _direction = p.direction ?? NotifyDirection.outflow;
        _categoryId = cats
            .where((c) => c.name == q.categoryName && c.type == type)
            .firstOrNull
            ?.id;
        if (p.amount != null) {
          _amount.text = formatVnd(p.amount!).replaceAll(' ₫', '');
        }
        _note.text = p.description ?? p.counterparty ?? '';
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Không đọc được nội dung chia sẻ.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final draft = _draft;
    final amount = parseVndInput(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _amountError = 'Nhập số tiền.');
      return;
    }
    if (_accountId == null) {
      setState(() => _error = 'Chọn tài khoản.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final ledger = ApiCaptureLedger(api);
      final prefs = NotifyCapturePrefs();
      final p = draft?.parse;
      var id = _accountId!;
      if (id == _newAccount && draft?.package != null) {
        final spec = accountSpecForPackage(draft!.package!);
        id = await ledger.createAccount(
          kind: spec.kind,
          institution: spec.institution,
          name: spec.name,
          last4: p?.last4,
        );
        await prefs.setAccount(draft.package!, id);
      }
      final edited =
          p == null ||
          amount != p.amount ||
          _direction != p.direction ||
          _note.text.trim() != (p.description ?? p.counterparty ?? '');
      final income = _direction == NotifyDirection.inflow;
      final hash = sha256.convert(utf8.encode(draft?.text ?? '')).toString();
      await api.command(
        'TX_CREATE',
        {
          'kind': _categoryId != null
              ? (income ? 'INCOME' : 'EXPENSE')
              : (income ? 'UNKNOWN_CREDIT' : 'UNKNOWN_DEBIT'),
          'account_id': id,
          'amount': amount.toString(),
          'effective_at': (p?.postedAt ?? DateTime.now())
              .toUtc()
              .toIso8601String(),
          'category_id': ?_categoryId,
          if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
          'source': edited ? 'MANUAL' : 'NOTIFICATION',
        },
        commandId: const Uuid().v5(
          Namespace.url.value,
          'moma-share|$hash|$amount|$id',
        ),
      );
      // A balance on the receipt is checked like a notification's (gap -> "khoản chưa ghi").
      final reported = p?.balance;
      if (reported != null) {
        final acc = (await ledger.accounts())
            .where((a) => a.id == id)
            .firstOrNull;
        if (acc != null) {
          await reportBalance(
            account: acc,
            reported: reported,
            ledger: ledger,
            prefs: prefs,
          );
        }
      }
      await WidgetSync.refreshWithApi(api)
          .timeout(const Duration(seconds: 5), onTimeout: () {});
      if (!mounted) return;
      setState(() {
        _busy = false;
        _doneText = 'Đã ghi ${income ? '+' : '-'}${formatVnd(amount)}';
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await _close();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final signedIn = Supabase.instance.client.auth.currentSession != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _busy ? null : _close,
              child: const ColoredBox(color: Color(0x80000000)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: insets),
              child: Material(
                color: scheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: !signedIn
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'Đăng nhập MoMa trước để ghi giao dịch.',
                            ),
                          )
                        : _doneText != null
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Symbols.check_circle_rounded,
                                  color: MomaColors.emerald,
                                  fill: 1,
                                ),
                                const SizedBox(width: 8),
                                Text(_doneText!),
                              ],
                            ),
                          )
                        : _loading
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : _form(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form() {
    final draft = _draft;
    final type = _direction == NotifyDirection.inflow ? 'INCOME' : 'EXPENSE';
    final brand = draft?.package == null
        ? null
        : accountSpecForPackage(draft!.package!).name;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            brand == null
                ? 'Ghi giao dịch được chia sẻ'
                : 'Ghi giao dịch $brand',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          PickField<String>(
            key: const ValueKey('share-account'),
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: 'Tài khoản'),
            items: [
              for (final a in _accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
              if (brand != null)
                DropdownMenuItem(
                  value: _newAccount,
                  child: Text('Tạo tài khoản $brand'),
                ),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
          const SizedBox(height: 12),
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
            onSelectionChanged: (s) => setState(() {
              _direction = s.first;
              _categoryId = null;
            }),
          ),
          const SizedBox(height: 12),
          MoneyField(
            controller: _amount,
            onChanged: (_) {
              if (_amountError != null) setState(() => _amountError = null);
            },
          ),
          if (_amountError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                _amountError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 12),
          PickField<String>(
            key: ValueKey('share-category-$type'),
            initialValue: _categoryId,
            optional: true,
            decoration: const InputDecoration(labelText: 'Danh mục'),
            items: [
              for (final c in _categories)
                if (c.type == type)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 12),
          LabeledField(
            label: 'Ghi chú',
            hint: 'Không bắt buộc',
            controller: _note,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Lưu'),
          ),
        ],
      ),
    );
  }
}
