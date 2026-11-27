import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/moma_theme.dart';
import '../../../app/theme/palette.dart';
import '../../../core/brands/brand_registry.dart';
import '../../../core/models.dart';
import '../../../core/network/api_client.dart';
import '../../../core/providers.dart';
import '../../../core/ui/moma_switch.dart';
import '../../../core/widgets.dart';
import '../../notify_capture/capture_engine.dart';
import '../../notify_capture/parser.dart' show bankNameOf;
import 'sync_sources.dart';

/// A supported bank / wallet app found on this phone.
class DetectedApp {
  const DetectedApp({
    required this.package,
    required this.name,
    this.brand,
    this.accountId,
  });
  final String package;
  final String name;
  final Brand? brand;

  /// MoMa account its notifications are recorded into (null = not recorded).
  final String? accountId;
  bool get on => accountId != null;
}

/// Supported apps installed here, minus those whose bank is linked through SePay (bank sync posts those).
final detectedAppsProvider = FutureProvider.autoDispose<List<DetectedApp>>((
  ref,
) async {
  final access = ref.watch(notifyAccessProvider);
  final installed = await access.installedApps();
  if (installed.isEmpty) return const [];
  final accounts = await ref.watch(accountsProvider.future);
  final links = await ref
      .watch(bankLinksProvider.future)
      .catchError((_) => <BankLink>[]);
  final linked = {for (final l in links) l.accountId};
  final map = (await ref.watch(notifySyncStateProvider.future)).map;
  final seenBrands = <String>{};
  final out = <DetectedApp>[];
  for (final p in installed) {
    final brand = brandFor(package: p);
    if (brand != null && !seenBrands.add(brand.code)) continue;
    if (packageIsSepayLinked(p, accounts, linked)) continue;
    final mapped = map[p];
    out.add(
      DetectedApp(
        package: p,
        name: brand?.shortName ?? bankNameOf(p),
        brand: brand,
        accountId: mapped != null && accounts.any((a) => a.id == mapped)
            ? mapped
            : null,
      ),
    );
  }
  return out;
});

/// Maps every package in [packages] to a MoMa account: an existing account of the same bank / wallet (not linked,
/// not fed by another app), else a new one (kind BANK / WALLET, name = the brand; balance unknown until the first
/// notification reports it). Turns automatic recording on. Returns how many accounts were created.
Future<int> enableAutoCapture(
  List<String> packages, {
  required NotifySyncStore store,
  required ApiClient api,
  required List<Account> accounts,
  required Set<String> linked,
}) async {
  final map = await store.accountMap();
  final all = [...accounts];
  final ledger = ApiCaptureLedger(api);
  var created = 0;
  for (final p in packages) {
    final current = map[p];
    if (current != null && all.any((a) => a.id == current)) continue;
    final match = matchAccountForPackage(p, all, map: map, linked: linked);
    final String id;
    if (match != null) {
      id = match.id;
    } else {
      final spec = accountSpecForPackage(p);
      id = await ledger.createAccount(
        kind: spec.kind,
        institution: spec.institution,
        name: spec.name,
      );
      all.add(
        Account(
          id: id,
          kind: spec.kind,
          institution: spec.institution,
          name: spec.name,
          last4: null,
          balance: null,
          version: 1,
        ),
      );
      created++;
    }
    map[p] = id;
    await store.mapPackage(p, id);
  }
  if (!await store.autoRecord()) await store.setAutoRecord(true);
  return created;
}

/// Asks for notification access (when missing) the way the account switches do. Returns whether it is granted
/// (or the owner went to settings).
Future<bool> ensureNotifyAccess(
  BuildContext context,
  NotifyAccess access,
) async {
  if (await access.isGranted()) return true;
  if (!context.mounted) return false;
  final open = await showConfirmDialog(
    context,
    title: 'Cần quyền đọc thông báo',
    message:
        'Android cần bạn cho phép MoMa đọc thông báo. MoMa chỉ đọc thông báo của ứng dụng ngân hàng, ví được hỗ trợ; '
        'thông báo khác bị bỏ qua. Bật MoMa trong màn hình sắp mở rồi quay lại.',
    confirmLabel: 'Mở cài đặt',
    cancelLabel: 'Để sau',
  );
  if (!open) return false;
  await access.openSettings();
  return true;
}

/// "Phát hiện trên máy: Vietcombank, Techcombank…" with logos, a one-tap "Bật tự ghi tất cả" and, unless
/// [compact], a switch per app. Hidden when nothing supported is installed (or, compact, when all is on).
class DetectedAppsCard extends ConsumerStatefulWidget {
  const DetectedAppsCard({super.key, this.compact = false});
  final bool compact;
  @override
  ConsumerState<DetectedAppsCard> createState() => _DetectedAppsCardState();
}

class _DetectedAppsCardState extends ConsumerState<DetectedAppsCard> {
  bool _busy = false;

  Future<void> _enable(List<String> packages, {bool all = false}) async {
    setState(() => _busy = true);
    try {
      final access = ref.read(notifyAccessProvider);
      await ensureNotifyAccess(context, access);
      final accounts = await ref.read(accountsProvider.future);
      final links = await ref
          .read(bankLinksProvider.future)
          .catchError((_) => <BankLink>[]);
      final created = await enableAutoCapture(
        packages,
        store: ref.read(notifySyncStoreProvider),
        api: ref.read(apiProvider),
        accounts: accounts,
        linked: {for (final l in links) l.accountId},
      );
      if (created > 0) refreshAll(ref);
      ref
        ..invalidate(notifySyncStateProvider)
        ..invalidate(detectedAppsProvider);
      if (mounted) {
        showSnack(
          context,
          all
              ? 'Đã bật tự ghi cho ${packages.length} ứng dụng'
              : 'Đã bật tự ghi cho ${bankNameOf(packages.first)}',
        );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable(DetectedApp a) async {
    await ref.read(notifySyncStoreProvider).unmapPackage(a.package);
    ref
      ..invalidate(notifySyncStateProvider)
      ..invalidate(detectedAppsProvider);
    if (mounted) showSnack(context, 'Đã tắt tự ghi cho ${a.name}');
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.watch(detectedAppsProvider).value ?? const [];
    final state = ref.watch(notifySyncStateProvider).value;
    if (apps.isEmpty) return const SizedBox.shrink();
    final off = [
      for (final a in apps)
        if (!a.on) a.package,
    ];
    final allOn =
        off.isEmpty && state?.granted == true && state?.autoRecord == true;
    if (widget.compact && allOn) return const SizedBox.shrink();
    final pal = context.pal;
    final names = apps.map((a) => a.name).join(', ');
    return Container(
      key: const ValueKey('detected-apps'),
      margin: EdgeInsets.only(bottom: widget.compact ? 12 : 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: widget.compact ? pal.tintSoft : pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Symbols.devices_rounded,
                color: MomaColors.emerald,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Phát hiện trên máy: $names',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: pal.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in apps)
                a.brand == null
                    ? CircleAvatar(
                        radius: 16,
                        child: Text(a.name.characters.first),
                      )
                    : BrandLogo(a.brand!, size: 32),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            allOn
                ? 'MoMa đang tự ghi giao dịch từ thông báo của các ứng dụng này.'
                : 'Bật một lần: MoMa tạo tài khoản cho từng ứng dụng (nếu chưa có) và tự ghi mỗi khi có biến động số dư.',
            style: TextStyle(fontSize: 13, height: 1.4, color: pal.muted),
          ),
          if (!allOn) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('enable-all-detected'),
              onPressed: _busy
                  ? null
                  : () => _enable([for (final a in apps) a.package], all: true),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.bolt_rounded),
              label: const Text('Bật tự ghi tất cả'),
            ),
          ],
          if (!widget.compact) ...[
            const SizedBox(height: 6),
            for (final a in apps)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    if (a.brand != null)
                      BrandLogo(a.brand!, size: 28)
                    else
                      const SizedBox(width: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        a.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    MomaSwitch(
                      key: ValueKey('detected-${a.package}'),
                      value: a.on,
                      onChanged: _busy
                          ? null
                          : (v) => v ? _enable([a.package]) : _disable(a),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
