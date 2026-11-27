import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/theme_mode.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../auth/auth_service.dart';
import '../../app/theme/palette.dart';

/// AI status for the settings row (enabled flag and this month's spend). Failure just hides the numbers.
final aiStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((
  ref,
) async {
  try {
    return await ref.watch(apiProvider).get('/ai/status')
        as Map<String, dynamic>;
  } on Object {
    return null;
  }
});

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final name = (user?.userMetadata?['display_name'] as String?)?.trim();
    final ai = ref.watch(aiStatusProvider).value;
    final aiOn = ai?['enabled'] == true;
    final usage = ai?['usage'] as Map<String, dynamic>?;
    final spent = ((usage?['spent_micro'] as num?) ?? 0) / 1000000;
    final cap = ((ai?['cap_micro'] as num?) ?? 0) / 1000000;
    return MomaPage(
      title: 'Cài đặt',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _deco(context),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: MomaColors.mint,
                  child: Text(
                    ((name != null && name.isNotEmpty)
                            ? name
                            : (user?.email ?? 'M'))
                        .characters
                        .first
                        .toUpperCase(),
                    style: const TextStyle(
                      color: MomaColors.forest,
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (name != null && name.isNotEmpty) ? name : 'Chủ sở hữu',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        user?.email ?? '',
                        style: TextStyle(color: context.pal.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _Label('Dữ liệu'),
          _Group(
            children: [
              _Item(
                icon: Icons.account_balance_wallet_outlined,
                color: const Color(0xFF1B8A5A),
                title: 'Tài khoản',
                subtitle: 'Ngân hàng, ví, tiền mặt',
                onTap: () => context.push('/accounts'),
              ),
              _Item(
                icon: Icons.category_outlined,
                color: const Color(0xFFFF8A3D),
                title: 'Danh mục',
                subtitle: 'Thêm, sửa, lưu trữ danh mục thu chi',
                onTap: () => context.push('/categories'),
              ),
              _Item(
                icon: Icons.upload_file_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Nhập sao kê CSV',
                subtitle: 'Đưa giao dịch từ file sao kê vào MoMa',
                onTap: () => context.push('/import'),
              ),
            ],
          ),
          const _Label('Trợ lý AI'),
          _Group(
            children: [
              _Item(
                icon: Icons.auto_awesome_outlined,
                color: const Color(0xFF8B5CF6),
                title: 'DeepSeek Flash',
                subtitle: aiOn
                    ? 'Đang bật · tháng này \$${spent.toStringAsFixed(3)} / \$${cap.toStringAsFixed(2)}'
                    : (ai == null
                          ? 'Chưa kiểm tra được trạng thái'
                          : 'Đang tắt'),
              ),
            ],
          ),
          const _Label('Hệ thống'),
          _Group(
            children: [
              _Item(
                icon: Icons.brightness_6_outlined,
                color: const Color(0xFF8B5CF6),
                title: 'Giao diện',
                subtitle: switch (ref.watch(themeModeProvider)) {
                  ThemeMode.light => 'Sáng',
                  ThemeMode.dark => 'Tối',
                  ThemeMode.system => 'Theo hệ thống',
                },
                onTap: () => _pickTheme(context, ref),
              ),
              _Item(
                icon: Icons.dns_outlined,
                color: const Color(0xFF64748B),
                title: 'Địa chỉ máy chủ',
                subtitle: 'Máy chủ MoMa API',
                onTap: () => _editApiBase(context, ref),
              ),
              const _Item(
                icon: Icons.shield_outlined,
                color: Color(0xFF1B8A5A),
                title: 'Bảo mật',
                subtitle: 'Phiên đăng nhập lưu trong Android Keystore',
              ),
              _Item(
                icon: Icons.info_outline_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Giới thiệu MoMa',
                subtitle: 'MoneyManage · Bảo lưu mọi quyền',
                onTap: () async {
                  final info = await PackageInfo.fromPlatform();
                  if (!context.mounted) return;
                  showLicensePage(
                    context: context,
                    applicationName: 'MoMa',
                    applicationVersion: '${info.version}+${info.buildNumber}',
                    applicationLegalese:
                        '© 2026 Lê Đào Nhân Sâm. Bảo lưu mọi quyền.',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => AuthService(ref.read(apiProvider)).signOut(),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTheme(BuildContext context, WidgetRef ref) async {
    final v = await showChoiceSheet<ThemeMode>(
      context,
      title: 'Giao diện',
      selected: ref.read(themeModeProvider),
      options: const [
        ChoiceOption(
          value: ThemeMode.light,
          label: 'Sáng',
          icon: Icons.light_mode_outlined,
        ),
        ChoiceOption(
          value: ThemeMode.dark,
          label: 'Tối',
          icon: Icons.dark_mode_outlined,
        ),
        ChoiceOption(
          value: ThemeMode.system,
          label: 'Hệ thống',
          icon: Icons.brightness_6_outlined,
        ),
      ],
      footnote: 'Chế độ Sáng dễ nhìn ngoài trời, chế độ Tối dịu mắt khi ở nơi ít ánh sáng.',
    );
    if (v != null) await ref.read(themeModeProvider.notifier).set(v);
  }

  Future<void> _editApiBase(BuildContext context, WidgetRef ref) async {
    final store = ref.read(storeProvider);
    final c = TextEditingController(text: await store.apiBase());
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Địa chỉ máy chủ'),
        content: TextField(controller: c, keyboardType: TextInputType.url),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    final url = c.text.trim();
    if (ok == true && url.startsWith('https://')) await store.setApiBase(url);
  }
}

BoxDecoration _deco(BuildContext context) => BoxDecoration(
  color: context.pal.surface,
  borderRadius: BorderRadius.circular(22),
);

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 15,
        color: context.pal.muted,
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: _deco(context),
    child: Column(
      children: [
        for (final (i, c) in children.indexed) ...[
          c,
          if (i < children.length - 1)
            Divider(height: 1, indent: 70, color: context.pal.lineSoft),
        ],
      ],
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    leading: CategoryAvatar(iconData: icon, color: color),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: onTap == null
        ? null
        : Icon(Icons.chevron_right_rounded, color: context.pal.muted),
  );
}
