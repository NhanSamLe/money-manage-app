import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/theme_mode.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';
import '../auth/auth_service.dart';
import '../lock/lock_settings_page.dart';
import '../notify_capture/notify_capture_page.dart';
import '../profile/avatar.dart';
import '../update/update_sheet.dart';
import '../widgets/widget_settings_page.dart';
import 'capacity_page.dart';
import 'offline_data_page.dart';

/// Settings only contain things a person uses the app for (plans, data, appearance, help). Server, API and
/// provider configuration is deliberately not user-editable: this is a finance app, not an admin console.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final profile = ref.watch(profileProvider).value;
    final name = (profile?['display_name'] as String?)?.trim() ?? '';
    final shown = name.isNotEmpty ? name : 'Chủ sở hữu';
    return MomaPage(
      title: 'Cài đặt',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Material(
            color: context.pal.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => context.push('/profile'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const OwnerAvatar(size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            shown,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            user?.email ?? '',
                            style: TextStyle(
                              color: context.pal.muted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Symbols.chevron_right_rounded,
                      color: context.pal.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _Label('Kế hoạch'),
          _Group(
            children: [
              _Item(
                icon: Symbols.handshake_rounded,
                color: const Color(0xFF8B5CF6),
                title: 'Công nợ',
                subtitle: 'Phải thu, phải trả',
                onTap: () => context.push('/planning?tab=0'),
              ),
              _Item(
                icon: Symbols.savings_rounded,
                color: const Color(0xFF1B8A5A),
                title: 'Mục tiêu tiết kiệm',
                subtitle: 'Dành tiền cho kế hoạch của bạn',
                onTap: () => context.push('/planning?tab=1'),
              ),
              _Item(
                icon: Symbols.pie_chart_rounded,
                color: const Color(0xFFFF8A3D),
                title: 'Ngân sách',
                subtitle: 'Hạn mức chi tiêu theo tháng',
                onTap: () => context.push('/planning?tab=2'),
              ),
              _Item(
                icon: Symbols.event_repeat_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Thu chi định kỳ',
                subtitle: 'Tiền nhà, hóa đơn, lương',
                onTap: () => context.push('/planning?tab=3'),
              ),
            ],
          ),
          const _Label('Dữ liệu'),
          _Group(
            children: [
              _Item(
                icon: Symbols.account_balance_rounded,
                color: const Color(0xFF0E7490),
                title: 'Kết nối ngân hàng',
                subtitle: 'Tự động lấy số dư và giao dịch từ tài khoản thật',
                onTap: () => context.push('/banks'),
              ),
              _Item(
                icon: Symbols.notifications_active_rounded,
                color: const Color(0xFFE0A100),
                title: 'Thông báo ngân hàng trên máy',
                subtitle:
                    'Tự ghi giao dịch từ thông báo ứng dụng ngân hàng, ví',
                onTap: () => openNotifyCaptureSettings(context),
              ),
              _Item(
                icon: Symbols.qr_code_2_rounded,
                color: const Color(0xFF1B8A5A),
                title: 'Nhận tiền bằng mã QR',
                subtitle: 'Tạo mã VietQR cho tài khoản của bạn',
                onTap: () => context.push('/receive'),
              ),
              _Item(
                icon: Symbols.account_balance_wallet_rounded,
                color: const Color(0xFF1B8A5A),
                title: 'Tài khoản',
                subtitle: 'Ngân hàng, ví, tiền mặt',
                onTap: () => context.push('/accounts'),
              ),
              _Item(
                icon: Symbols.category_rounded,
                color: const Color(0xFFFF8A3D),
                title: 'Danh mục',
                subtitle: 'Thêm, sửa, lưu trữ danh mục thu chi',
                onTap: () => context.push('/categories'),
              ),
              _Item(
                icon: Symbols.upload_file_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Nhập sao kê CSV',
                subtitle: 'Đưa giao dịch từ file sao kê vào MoMa',
                onTap: () => context.push('/import'),
              ),
              _Item(
                icon: Symbols.download_rounded,
                color: const Color(0xFF1B8A5A),
                title: 'Xuất dữ liệu',
                subtitle: 'Lưu giao dịch ra file Excel hoặc CSV',
                onTap: () => context.push('/export'),
              ),
            ],
          ),
          const _Label('Ứng dụng'),
          _Group(
            children: [
              _Item(
                icon: Symbols.notifications_rounded,
                color: const Color(0xFF21896E),
                title: 'Nhắc nhở & thông báo',
                subtitle: 'Bữa ăn, kiểm tra tiền mặt, tổng kết, ngân sách',
                onTap: () => context.push('/reminders'),
              ),
              _Item(
                icon: Symbols.lock_rounded,
                color: const Color(0xFF0E7490),
                title: 'Khóa ứng dụng',
                subtitle: 'Mã PIN, vân tay / khuôn mặt',
                onTap: () => openLockSettings(context),
              ),
              _Item(
                icon: Symbols.widgets_rounded,
                color: const Color(0xFF14B8A6),
                title: 'Tiện ích màn hình chính',
                subtitle: 'Thêm tiện ích, ẩn số tiền trên tiện ích',
                onTap: () => openWidgetSettings(context),
              ),
              _Item(
                icon: Symbols.cloud_download_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Dữ liệu ngoại tuyến',
                subtitle: 'Dùng khi không có mạng, tự đồng bộ lại',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OfflineDataPage(),
                  ),
                ),
              ),
              _Item(
                icon: Symbols.database_rounded,
                color: const Color(0xFF8B5CF6),
                title: 'Dung lượng & chi phí',
                subtitle: 'Dữ liệu, ảnh và chi phí AI tháng này',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const CapacityPage()),
                ),
              ),
              _Item(
                icon: Symbols.brightness_6_rounded,
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
                icon: Symbols.menu_book_rounded,
                color: const Color(0xFF1B8A5A),
                title: 'Hướng dẫn sử dụng',
                subtitle: 'Các bước thiết lập và cách dùng MoMa',
                onTap: () => context.push('/guide'),
              ),
              _Item(
                icon: Symbols.info_rounded,
                color: const Color(0xFF2F80ED),
                title: 'Giới thiệu MoMa',
                subtitle: 'Phiên bản và thông tin ứng dụng',
                onTap: () => context.push('/about'),
              ),
              _Item(
                icon: Symbols.system_update_rounded,
                color: const Color(0xFF0E7490),
                title: 'Kiểm tra cập nhật',
                subtitle: 'Tải và cài phiên bản MoMa mới nhất',
                onTap: () => checkForUpdateManually(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => AuthService(ref.read(apiProvider)).signOut(),
            icon: const Icon(Symbols.logout_rounded),
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
          icon: Symbols.light_mode_rounded,
        ),
        ChoiceOption(
          value: ThemeMode.dark,
          label: 'Tối',
          icon: Symbols.dark_mode_rounded,
        ),
        ChoiceOption(
          value: ThemeMode.system,
          label: 'Hệ thống',
          icon: Symbols.brightness_6_rounded,
        ),
      ],
      footnote: 'Chế độ Sáng dễ nhìn ngoài trời, chế độ Tối dịu mắt khi ở nơi ít ánh sáng.',
    );
    if (v != null) await ref.read(themeModeProvider.notifier).set(v);
  }
}

BoxDecoration _deco(BuildContext context) => BoxDecoration(
  color: context.pal.surface,
  borderRadius: BorderRadius.circular(20),
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
        fontWeight: FontWeight.w700,
        fontSize: 13,
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
            Divider(height: 1, indent: 68, color: context.pal.lineSoft),
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
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    leading: CategoryAvatar(iconData: icon, color: color, size: 40),
    title: Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
    ),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
    trailing: onTap == null
        ? null
        : Icon(Symbols.chevron_right_rounded, color: context.pal.muted),
  );
}
