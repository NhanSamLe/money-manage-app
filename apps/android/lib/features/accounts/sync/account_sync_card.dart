import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/moma_theme.dart';
import '../../../app/theme/palette.dart';
import '../../../core/account_presets.dart';
import '../../../core/models.dart';
import '../../../core/money/money.dart';
import '../../../core/sheets.dart';
import '../../../core/ui/moma_switch.dart';
import '../../../core/widgets.dart';
import '../../notify_capture/parser.dart' show bankNameOf;
import 'sync_sources.dart';

const _amber = Color(0xFFB7791F);

const syncOverviewHelp =
    'Đồng bộ ngân hàng: ngân hàng gửi biến động số dư qua SePay thẳng về máy chủ MoMa, nên giao dịch được ghi '
    'cả khi điện thoại tắt hoặc không mở MoMa. Số tiền, thời gian và số dư lấy đúng từ ngân hàng. Chỉ dùng cho '
    'tài khoản ngân hàng đã thêm trên my.sepay.vn rồi kết nối trong MoMa.\n\n'
    'Thông báo Android: MoMa đọc thông báo biến động số dư của ứng dụng ngân hàng, ví trên chính điện thoại này '
    '(cần cấp quyền đọc thông báo). Điện thoại phải nhận được thông báo; giao dịch được ghi khi bạn mở MoMa. '
    'Thông báo có thể thiếu nội dung hoặc bị ứng dụng gộp lại, nên độ chính xác thấp hơn.\n\n'
    'Nên ưu tiên đồng bộ ngân hàng. Mỗi tài khoản chỉ dùng một trong hai cách để không bị ghi trùng.';

const _bankHelp =
    'Ngân hàng báo từng giao dịch qua SePay về MoMa ngay khi phát sinh, kể cả khi điện thoại tắt. '
    'Để liên kết: thêm tài khoản trên my.sepay.vn (xác minh bằng OTP của ngân hàng), rồi kết nối trong MoMa.';

const _androidHelp =
    'MoMa đọc thông báo biến động số dư của ứng dụng bạn chọn trên điện thoại này và tự ghi vào tài khoản này '
    'khi bạn mở MoMa. Cần quyền đọc thông báo và ứng dụng ngân hàng, ví phải bật thông báo. '
    'Không dùng cho tài khoản đã đồng bộ ngân hàng để tránh ghi trùng.';

const _manualHelp =
    'Tiền mặt không có ngân hàng hay ứng dụng nào báo biến động. Hãy ghi tay hoặc nói với Trợ lý, '
    'ví dụ "ăn sáng 30k tiền mặt".';

/// One account with its two auto-record channels (bank sync and Android notifications).
class AccountSyncCard extends ConsumerWidget {
  const AccountSyncCard({
    super.key,
    required this.account,
    required this.link,
    required this.linksFailed,
    required this.notify,
    required this.onOpen,
  });
  final Account account;
  final BankLink? link;

  /// GET /banks/links failed: whether the account is bank-linked is unknown.
  final bool linksFailed;
  final NotifySyncState? notify;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final a = account;
    final last4 = link?.last4 ?? a.last4;
    final sub = last4 == null || last4.isEmpty
        ? a.institution
        : 'STK: *** $last4';
    final kind = syncKindOf(a);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 8, 12),
              child: Row(
                children: [
                  AccountBadge(institution: a.institution, kind: a.kind),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: pal.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: pal.muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 128),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          a.isCard ? 'Dư nợ' : 'Số dư hiện tại',
                          style: TextStyle(color: pal.muted, fontSize: 13),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            a.balance == null
                                ? 'Chưa biết'
                                : formatVnd(
                                    a.isCard ? -a.balance! : a.balance!,
                                  ),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: pal.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Symbols.chevron_right_rounded, color: pal.muted),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: pal.lineSoft, indent: 14, endIndent: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Column(
              children: [
                _SyncRow(
                  icon: Symbols.swap_horiz_rounded,
                  label: 'Đồng bộ ngân hàng',
                  help: kind == SyncKind.manual ? _manualHelp : _bankHelp,
                  helper: kind == SyncKind.manual
                      ? 'Ghi tay hoặc nhờ Trợ lý'
                      : null,
                  trailing: kind == SyncKind.manual
                      ? null
                      : _bankTrailing(context, ref),
                ),
                _SyncRow(
                  icon: Symbols.notifications_rounded,
                  label: 'Thông báo Android',
                  help: kind == SyncKind.manual ? _manualHelp : _androidHelp,
                  helper: _androidHelper(),
                  trailing: kind == SyncKind.manual
                      ? null
                      : _androidTrailing(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _androidHelper() {
    if (syncKindOf(account) == SyncKind.manual) {
      return 'Ghi tay hoặc nhờ Trợ lý';
    }
    if (link != null) return 'Đã đồng bộ ngân hàng, không cần';
    final pkgs = notify?.packagesOf(account.id) ?? const [];
    if (pkgs.isEmpty) return null;
    return 'Từ ứng dụng ${pkgs.map(bankNameOf).join(', ')}';
  }

  Widget _bankTrailing(BuildContext context, WidgetRef ref) {
    if (link != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Đã liên kết',
            style: TextStyle(
              color: MomaColors.income,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 6),
          MomaSwitch(
            key: ValueKey('bank-sync-${account.id}'),
            value: true,
            onChanged: (_) => showInfoDialog(
              context,
              title: 'Đang đồng bộ ngân hàng',
              message: 'Giao dịch của tài khoản này do ngân hàng báo qua SePay. Muốn dừng, hãy gỡ tài khoản trên my.sepay.vn.',
            ),
          ),
        ],
      );
    }
    if (linksFailed) {
      return _Pill(
        label: 'Thử lại',
        color: _amber,
        onTap: () => ref.invalidate(bankLinksProvider),
      );
    }
    if (syncKindOf(account) == SyncKind.bank) {
      return _Pill(
        key: ValueKey('bank-link-${account.id}'),
        label: 'Liên kết',
        color: MomaColors.emerald,
        onTap: () async {
          await context.push('/banks');
          ref.invalidate(bankLinksProvider);
        },
      );
    }
    return _Pill(
      key: ValueKey('bank-unsupported-${account.id}'),
      label: 'Chưa hỗ trợ',
      color: _amber,
      onTap: () => showInfoDialog(
        context,
        title: 'Chưa hỗ trợ đồng bộ',
        message:
            'Ví điện tử và thẻ không có kết nối ngân hàng qua SePay. Hãy bật Thông báo Android để MoMa tự ghi '
            'từ thông báo biến động số dư của ứng dụng trên điện thoại.',
      ),
    );
  }

  Widget _androidTrailing(BuildContext context, WidgetRef ref) {
    final on = (notify?.packagesOf(account.id) ?? const []).isNotEmpty;
    return MomaSwitch(
      key: ValueKey('android-sync-${account.id}'),
      value: link == null && on,
      onChanged: link != null || notify == null
          ? null
          : (v) => setAndroidSync(context, ref, account, v),
    );
  }
}

/// Turns notification capture on or off for [account]. On: checks the permission, asks which app sends the
/// notifications and saves the mapping (also turning on automatic recording). Off: removes the mapping.
Future<void> setAndroidSync(
  BuildContext context,
  WidgetRef ref,
  Account account,
  bool on,
) async {
  final store = ref.read(notifySyncStoreProvider);
  if (!on) {
    await store.unmapAccount(account.id);
    ref.invalidate(notifySyncStateProvider);
    if (context.mounted) {
      showSnack(context, 'Đã tắt tự ghi từ thông báo cho ${account.name}');
    }
    return;
  }
  final links = ref.read(bankLinksProvider);
  if (links.hasError || !links.hasValue) {
    await showErrorDialog(
      context,
      'Chưa kiểm tra được tài khoản này có đồng bộ ngân hàng không. Bạn thử lại sau để tránh ghi trùng.',
    );
    return;
  }
  final access = ref.read(notifyAccessProvider);
  if (!await access.isGranted()) {
    if (!context.mounted) return;
    final open = await showConfirmDialog(
      context,
      title: 'Cần quyền đọc thông báo',
      message:
          'Android cần bạn cho phép MoMa đọc thông báo. MoMa chỉ đọc thông báo của ứng dụng ngân hàng, ví bạn chọn; '
          'thông báo khác bị bỏ qua. Bật MoMa trong màn hình sắp mở rồi quay lại.',
      confirmLabel: 'Mở cài đặt',
      cancelLabel: 'Để sau',
    );
    if (!open) return;
    await access.openSettings();
  }
  if (!context.mounted) return;
  final apps = notifySourceApps(institution: account.institution);
  final pkg = await showChoiceSheet<String>(
    context,
    title: 'Ứng dụng gửi thông báo',
    options: [
      for (final (p, name) in apps)
        ChoiceOption(
          value: p,
          label: name,
          icon: Symbols.notifications_rounded,
        ),
    ],
    footnote: 'Mỗi ứng dụng chỉ ghi vào một tài khoản. Chọn ứng dụng đang ghi vào tài khoản khác sẽ chuyển sang tài khoản này.',
  );
  if (pkg == null) return;
  await store.mapPackage(pkg, account.id);
  if (!await store.autoRecord()) await store.setAutoRecord(true);
  ref.invalidate(notifySyncStateProvider);
  if (context.mounted) {
    showSnack(
      context,
      'Thông báo từ ${bankNameOf(pkg)} sẽ tự ghi vào ${account.name}',
    );
  }
}

class _SyncRow extends StatelessWidget {
  const _SyncRow({
    required this.icon,
    required this.label,
    required this.help,
    this.helper,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final String help;
  final String? helper;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Icon(icon, size: 20, color: MomaColors.emerald),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    InkResponse(
                      radius: 16,
                      onTap: () =>
                          showInfoDialog(context, title: label, message: help),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Symbols.info_rounded,
                          size: 16,
                          color: pal.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                if (helper != null)
                  Text(
                    helper!,
                    style: TextStyle(fontSize: 13, color: pal.muted),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
