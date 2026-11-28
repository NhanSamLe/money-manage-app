import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/money/money_input.dart';
import '../../core/network/api_client.dart';
import '../../core/outbox.dart';
import '../../core/providers.dart';
import 'widget_sync.dart';
import 'routine_quick.dart';
import '../../core/storage/offline_cache.dart' show NetStatus;
import '../lock/lock_screen.dart';

/// Root of the translucent quick-entry sheet started from the home-screen widget.
class QuickEntryOverlayApp extends StatelessWidget {
  const QuickEntryOverlayApp({
    super.key,
    required this.income,
    this.routineSlot,
    this.routineKey,
  });
  final bool income;

  /// Set when started from a quick bar action ("Bánh mì 20k"): record that learned option right away.
  final String? routineSlot;
  final String? routineKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MoMa',
      debugShowCheckedModeBanner: false,
      theme: buildMomaTheme(),
      darkTheme: buildMomaTheme(Brightness.dark),
      color: Colors.transparent,
      home: QuickEntryOverlay(
        income: income,
        routineSlot: routineSlot,
        routineKey: routineKey,
      ),
    );
  }
}

Future<void> _close() async {
  try {
    await WidgetSync.channel.invokeMethod<void>('finish');
  } catch (_) {
    await SystemNavigator.pop();
  }
}

/// Compact bottom card: amount, top categories, account, note, "Lưu". Offline saves go to the outbox.
class QuickEntryOverlay extends ConsumerStatefulWidget {
  const QuickEntryOverlay({
    super.key,
    required this.income,
    this.routineSlot,
    this.routineKey,
  });
  final bool income;
  final String? routineSlot;
  final String? routineKey;
  @override
  ConsumerState<QuickEntryOverlay> createState() => _QuickEntryOverlayState();
}

class _QuickEntryOverlayState extends ConsumerState<QuickEntryOverlay> {
  late bool _income = widget.income;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final String _commandId = ApiClient.newId();
  List<Account> _accounts = const [];
  List<Category> _categories = const [];
  List<String> _rank = const [];
  String? _accountId;
  String? _categoryId;
  bool _loading = true;
  bool _busy = false;
  bool _done = false;
  String? _doneText;
  String? _error;
  final bool _signedIn = Supabase.instance.client.auth.currentSession != null;

  /// The assistant's learned answers for the current part of the day ("Sáng nay bạn ăn gì?").
  QuickRoutine? _routine;
  String? _routineBusy;

  /// Flips once the theme's Google Fonts have loaded: chips measured with the fallback font keep a too-narrow
  /// size ("Khoản ch"), so the type chips are rebuilt (new key) after the real font arrives.
  bool _fontsReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      GoogleFonts.pendingFonts().then((_) {
        if (mounted) setState(() => _fontsReady = true);
      }, onError: (_) {}),
    );
    if (_signedIn) unawaited(_unlockThenLoad());
  }

  /// The app lock also guards the home-screen quick entry: no form until unlocked.
  Future<void> _unlockThenLoad() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ok = await ensureUnlocked(context);
    if (!ok) {
      await SystemNavigator.pop();
      return;
    }
    await _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          Map<String, dynamic>.from(e as Map),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _apply(List<Account> accounts, List<Category> categories) {
    _accounts = accounts;
    _categories = categories;
    if (_accountId == null || !accounts.any((a) => a.id == _accountId)) {
      _accountId =
          accounts.where((a) => a.kind == 'CASH').firstOrNull?.id ??
          accounts.firstOrNull?.id;
    }
  }

  Future<void> _load() async {
    // Cached copies (written by WidgetSync) first: instant and works offline.
    final cachedAcc = _decode(await WidgetSync.read('cache_accounts'));
    final cachedCat = _decode(await WidgetSync.read('cache_categories'));
    final last = await WidgetSync.read('last_account');
    try {
      _rank = [
        for (final e
            in jsonDecode('${await WidgetSync.read('cache_cat_rank')}') as List)
          '$e',
      ];
    } catch (_) {}
    if (last is String && last.isNotEmpty) _accountId = last;
    if (mounted) {
      setState(() {
        _apply(
          cachedAcc.map(Account.fromJson).toList(),
          cachedCat.map(Category.fromJson).toList(),
        );
        _loading = cachedAcc.isEmpty;
      });
    }
    final api = ref.read(apiProvider);
    try {
      final results = await Future.wait([
        api.get('/accounts'),
        api.get('/categories'),
      ]);
      final accounts = (results[0] as List)
          .map((e) => Account.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final categories = (results[1] as List)
          .map((e) => Category.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (mounted) setState(() => _apply(accounts, categories));
    } catch (_) {
      // Offline: keep the cached lists.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    await _loadRoutine(api);
  }

  /// Routine chips: the saved copy first (works offline, instant), then the live answer.
  Future<void> _loadRoutine(ApiClient api) async {
    final stored = await storedQuickRoutine(
      slot: await WidgetSync.read('routine_slot'),
      question: await WidgetSync.read('routine_q'),
      options: await WidgetSync.read('routine_opts'),
      until: await WidgetSync.read('routine_until'),
    );
    if (stored != null && mounted) setState(() => _routine = stored);
    final key = widget.routineKey;
    if (key != null) {
      final o = stored?.options.where((x) => x.key == key).firstOrNull;
      if (o != null) {
        await _recordRoutine(stored!.slot, o);
        return;
      }
    }
    final live = await fetchQuickRoutine(api);
    if (!mounted) return;
    if (live != null) setState(() => _routine = live);
    if (key != null) {
      final r = live ?? stored;
      final o = r?.options.where((x) => x.key == key).firstOrNull;
      if (o != null) {
        await _recordRoutine(r!.slot, o);
      } else {
        setState(() => _error = 'Món quen này đã hết giờ, hãy ghi bằng tay.');
      }
    }
  }

  Future<void> _recordRoutine(String slot, QuickRoutineOption o) async {
    final owner = Supabase.instance.client.auth.currentUser?.id;
    if (owner == null) return;
    setState(() {
      _routineBusy = o.key;
      _error = null;
    });
    final api = ref.read(apiProvider);
    try {
      final message = await recordQuickRoutine(
        api,
        ref.read(outboxProvider.notifier),
        owner: owner,
        slot: slot,
        option: o,
      );
      await _finish(message, NetStatus.offline ? null : api);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Không ghi được. Thử lại.');
    } finally {
      if (mounted) setState(() => _routineBusy = null);
    }
  }

  List<Category> get _topCategories {
    final type = _income ? 'INCOME' : 'EXPENSE';
    final list = _categories.where((c) => c.type == type).toList();
    int score(Category c) {
      final i = _rank.indexOf(c.id);
      return i < 0 ? 1000 : i;
    }

    list.sort((a, b) => score(a).compareTo(score(b)));
    return list.take(8).toList();
  }

  Future<void> _save() async {
    final amount = parseVndInput(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Nhập số tiền.');
      return;
    }
    if (_accountId == null) {
      setState(() => _error = 'Chọn tài khoản.');
      return;
    }
    if (_categoryId == null) {
      setState(() => _error = 'Chọn danh mục.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final payload = <String, dynamic>{
      'kind': _income ? 'INCOME' : 'EXPENSE',
      'account_id': _accountId,
      'amount': amount.toString(),
      'effective_at': DateTime.now().toUtc().toIso8601String(),
      'category_id': _categoryId,
      if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
    };
    final api = ref.read(apiProvider);
    try {
      await api.command('TX_CREATE', payload, commandId: _commandId);
      await _finish('Đã ghi ${formatVnd(amount)}', api);
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') {
        final outbox = ref.read(outboxProvider.notifier);
        await outbox.load();
        final queued = await outbox.add('TX_CREATE', payload, _commandId);
        if (queued) {
          await _finish('Đang offline: đã lưu, sẽ tự đồng bộ', null);
        } else if (mounted) {
          setState(
            () => _error = 'Hàng đợi offline đã đầy. Hãy mở MoMa để đồng bộ.',
          );
        }
      } else if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Không lưu được. Thử lại.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish(String text, ApiClient? api) async {
    await WidgetSync.write('last_account', _accountId);
    if (mounted) {
      setState(() {
        _done = true;
        _doneText = text;
      });
    }
    await Future.wait([
      Future<void>.delayed(const Duration(milliseconds: 1100)),
      if (api != null)
        WidgetSync.refreshWithApi(api)
            .timeout(const Duration(seconds: 5), onTimeout: () {}),
    ]);
    await _close();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
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
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      child: _done
                          ? _doneView(scheme)
                          : !_signedIn
                          ? _signedOutView()
                          : _form(scheme),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _doneView(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Symbols.check_circle_rounded,
          color: MomaColors.emerald,
          size: 32,
          fill: 1,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            _doneText ?? 'Đã ghi',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );

  Widget _signedOutView() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 12),
      const Text(
        'Hãy đăng nhập MoMa trước khi ghi nhanh.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => WidgetSync.channel.invokeMethod<void>('openApp', {
            'path': '/home',
          }),
          child: const Text('Mở MoMa'),
        ),
      ),
    ],
  );

  /// "Sáng nay bạn ăn gì?  [Bánh mì 20k] [Cà phê sữa 25k]": one tap records, no typing.
  Widget _routineRow(QuickRoutine r) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.question,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in r.options)
              ActionChip(
                key: ValueKey('routine-${o.key}'),
                avatar: _routineBusy == o.key
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.add_rounded, size: 16),
                label: Text(o.chip),
                onPressed: _routineBusy == null && !_busy
                    ? () => _recordRoutine(r.slot, o)
                    : null,
              ),
          ],
        ),
      ],
    ),
  );

  Widget _form(ColorScheme scheme) {
    final cats = _topCategories;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          key: ValueKey(_fontsReady),
          children: [
            ChoiceChip(
              label: const Text('Khoản chi'),
              selected: !_income,
              onSelected: (_) => setState(() {
                _income = false;
                _categoryId = null;
              }),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Khoản thu'),
              selected: _income,
              onSelected: (_) => setState(() {
                _income = true;
                _categoryId = null;
              }),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Đóng',
              onPressed: _busy ? null : _close,
              icon: const Icon(Symbols.close_rounded),
            ),
          ],
        ),
        if (_routine != null && !_income) _routineRow(_routine!),
        TextField(
          controller: _amount,
          autofocus: widget.routineKey == null,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            ThousandsFormatter(),
          ],
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: _income ? MomaColors.income : scheme.onSurface,
          ),
          decoration: const InputDecoration(
            hintText: '0',
            suffixText: '₫',
            border: InputBorder.none,
            filled: false,
          ),
        ),
        const SizedBox(height: 4),
        if (_loading && _categories.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in cats)
                ChoiceChip(
                  avatar: Icon(categoryIcon(c.icon), size: 18),
                  label: Text(c.name),
                  selected: _categoryId == c.id,
                  onSelected: (_) => setState(() {
                    _categoryId = c.id;
                    _error = null;
                  }),
                ),
            ],
          ),
        const SizedBox(height: 12),
        if (_accounts.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Tài khoản',
              isDense: true,
            ),
            items: [
              for (final a in _accounts)
                DropdownMenuItem(
                  value: a.id,
                  child: Row(
                    children: [
                      Icon(accountIcon(a.kind), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(a.name, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
        const SizedBox(height: 10),
        TextField(
          controller: _note,
          maxLength: 100,
          decoration: const InputDecoration(
            hintText: 'Ghi chú (không bắt buộc)',
            isDense: true,
            counterText: '',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: const TextStyle(color: MomaColors.expense),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: MomaColors.emerald,
          ),
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'Lưu',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
        ),
      ],
    );
  }
}
