import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import '../auth/auth_service.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cài đặt',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800, color: MomaColors.forest),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: MomaColors.emerald,
              child: Icon(Icons.person_rounded, color: Colors.white),
            ),
            title: const Text(
              'Chủ sở hữu',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(user?.email ?? ''),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: const Text('Địa chỉ máy chủ'),
            subtitle: FutureBuilder<String>(
              future: ref.read(storeProvider).apiBase(),
              builder: (_, s) => Text(s.data ?? '...'),
            ),
            onTap: () => _editApiBase(context, ref),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('Nhập sao kê CSV'),
            subtitle: const Text(
              'Đưa giao dịch từ file sao kê ngân hàng vào MoMa',
            ),
            onTap: () => context.push('/import'),
          ),
        ),
        const Card(
          child: ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('Bảo mật'),
            subtitle: Text('Phiên đăng nhập lưu trong Android Keystore.'),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Giới thiệu MoMa'),
            subtitle: const Text('MoneyManage · Bảo lưu mọi quyền'),
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
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => AuthService(ref.read(apiProvider)).signOut(),
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Đăng xuất'),
        ),
      ],
    );
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
