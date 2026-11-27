import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/ui/brand.dart';
import '../../core/ui/category_style.dart';
import '../../core/ui/header.dart';

const _owner = 'Lê Đào Nhân Sâm';
const _copyright = '© 2026 Lê Đào Nhân Sâm. Bảo lưu mọi quyền.';

/// "Giới thiệu MoMa": brand, version, what the app does, legal links and open-source licences.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((i) {
          if (mounted) setState(() => _info = i);
        })
        .catchError((Object _) {});
  }

  String get _version {
    final i = _info;
    if (i == null) return 'Phiên bản …';
    return 'Phiên bản ${i.version}';
  }

  void _openLicenses() {
    final i = _info;
    showLicensePage(
      context: context,
      applicationName: 'MoMa — MoneyManage',
      applicationVersion: i == null ? null : 'Phiên bản ${i.version}',
      applicationIcon: const Padding(
        padding: EdgeInsets.all(12),
        child: MomaAppIcon(size: 64),
      ),
      applicationLegalese:
          '$_copyright\nMoMa sử dụng các thư viện mã nguồn mở dưới đây. '
          'Xin cảm ơn cộng đồng đã đóng góp.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      body: MomaPage(
        title: 'Giới thiệu MoMa',
        showBack: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Center(child: const MomaAppIcon(size: 96)),
            const SizedBox(height: 16),
            Text(
              'MoMa — MoneyManage',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: pal.ink,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Quản lý tài chính cá nhân tự động, chính xác',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14.5, color: pal.muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: pal.tint,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _version,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? MomaColors.mint
                        : MomaColors.forest,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _Label('MoMa là gì'),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: _deco(context),
              child: Text(
                'MoMa là ứng dụng quản lý tài chính cá nhân giúp bạn biết chính xác '
                'tiền của mình đang ở đâu. Giao dịch ngân hàng được ghi lại tự động, '
                'trợ lý AI giúp nhập liệu và trả lời câu hỏi bằng tiếng Việt, còn ngân '
                'sách, mục tiêu và công nợ giúp bạn chủ động kế hoạch chi tiêu.',
                style: TextStyle(fontSize: 14.5, height: 1.55, color: pal.ink),
              ),
            ),
            const SizedBox(height: 16),
            const _Label('Tính năng chính'),
            const _Feature(
              icon: Symbols.account_balance_rounded,
              color: Color(0xFF2F80ED),
              title: 'Ghi chép tự động từ ngân hàng',
              body: 'Biến động số dư được nhận và ghi thành giao dịch ngay, không cần nhập tay.',
            ),
            const _Feature(
              icon: Symbols.smart_toy_rounded,
              color: Color(0xFF8B5CF6),
              title: 'Trợ lý tài chính AI',
              body: 'Nhắn tin tự nhiên để ghi chi tiêu, hỏi tình hình tài chính, nhận gợi ý.',
            ),
            const _Feature(
              icon: Symbols.savings_rounded,
              color: Color(0xFF1B8A5A),
              title: 'Ngân sách & mục tiêu',
              body: 'Đặt hạn mức chi theo danh mục và theo dõi tiến độ các mục tiêu tiết kiệm.',
            ),
            const _Feature(
              icon: Symbols.handshake_rounded,
              color: Color(0xFFFF8A3D),
              title: 'Công nợ',
              body: 'Theo dõi khoản cho vay, đi vay và các lần trả nợ rõ ràng.',
            ),
            const _Feature(
              icon: Symbols.shield_lock_rounded,
              color: Color(0xFF0C6A54),
              title: 'Bảo mật — dữ liệu của riêng bạn',
              body: 'Dữ liệu nằm trong cơ sở dữ liệu riêng của bạn, không quảng cáo, không theo dõi.',
            ),
            const SizedBox(height: 16),
            const _Label('Thông tin'),
            Container(
              decoration: _deco(context),
              child: Column(
                children: [
                  const _InfoRow(
                    icon: Symbols.person_rounded,
                    color: Color(0xFF2F80ED),
                    title: 'Nhà phát triển',
                    subtitle: _owner,
                  ),
                  _divider(context),
                  const _InfoRow(
                    icon: Symbols.copyright_rounded,
                    color: Color(0xFF64748B),
                    title: 'Bản quyền',
                    subtitle: _copyright,
                  ),
                  _divider(context),
                  _InfoRow(
                    icon: Symbols.gavel_rounded,
                    color: const Color(0xFF8B5CF6),
                    title: 'Điều khoản sử dụng',
                    onTap: () =>
                        _showDoc(context, 'Điều khoản sử dụng', _termsSections),
                  ),
                  _divider(context),
                  _InfoRow(
                    icon: Symbols.privacy_tip_rounded,
                    color: const Color(0xFF1B8A5A),
                    title: 'Chính sách quyền riêng tư',
                    onTap: () => _showDoc(
                      context,
                      'Chính sách quyền riêng tư',
                      _privacySections,
                    ),
                  ),
                  _divider(context),
                  _InfoRow(
                    icon: Symbols.code_rounded,
                    color: const Color(0xFFFF8A3D),
                    title: 'Giấy phép mã nguồn mở',
                    onTap: _openLicenses,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Làm tại Việt Nam',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: pal.hint),
            ),
          ],
        ),
      ),
    );
  }
}

BoxDecoration _deco(BuildContext context) => BoxDecoration(
  color: context.pal.surface,
  borderRadius: BorderRadius.circular(20),
);

Widget _divider(BuildContext context) =>
    Divider(height: 1, indent: 68, color: context.pal.lineSoft);

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
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

class _Feature extends StatelessWidget {
  const _Feature({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: _deco(context),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CategoryAvatar(iconData: icon, color: color, size: 42),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: context.pal.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
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
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: const TextStyle(fontSize: 12.5)),
    trailing: onTap == null
        ? null
        : Icon(Symbols.chevron_right_rounded, color: context.pal.muted),
  );
}

const _termsSections = <(String, String)>[
  (
    'Phạm vi',
    'MoMa là công cụ ghi chép và theo dõi tài chính cá nhân. Ứng dụng không phải '
        'ngân hàng, không giữ tiền và không thực hiện thanh toán thay bạn.',
  ),
  (
    'Tài khoản của bạn',
    'Bạn chịu trách nhiệm bảo mật thông tin đăng nhập và thiết bị. Hãy đăng xuất '
        'khi dùng chung máy và báo ngay nếu nghi ngờ bị truy cập trái phép.',
  ),
  (
    'Tính chính xác',
    'Số liệu được tính từ giao dịch bạn ghi và dữ liệu ngân hàng nhận được. Hãy đối '
        'chiếu với sao kê chính thức trước khi đưa ra quyết định tài chính quan trọng.',
  ),
  (
    'Trợ lý AI',
    'Gợi ý của Trợ lý tài chính chỉ mang tính tham khảo, không phải tư vấn tài chính, '
        'đầu tư hay pháp lý.',
  ),
  (
    'Sử dụng hợp lệ',
    'Không dùng MoMa cho mục đích trái pháp luật, không can thiệp hay khai thác lỗi '
        'của hệ thống.',
  ),
  (
    'Thay đổi',
    'Điều khoản có thể được cập nhật theo phiên bản ứng dụng. Tiếp tục sử dụng nghĩa '
        'là bạn đồng ý với phiên bản mới nhất.',
  ),
];

const _privacySections = <(String, String)>[
  (
    'Nơi lưu dữ liệu',
    'Toàn bộ dữ liệu tài chính được lưu trong cơ sở dữ liệu Supabase riêng của chủ '
        'sở hữu ứng dụng, được bảo vệ bằng phân quyền theo từng tài khoản.',
  ),
  (
    'Dữ liệu ngân hàng',
    'Biến động số dư được nhận qua dịch vụ SePay. MoMa chỉ nhận thông tin giao dịch '
        '(số tiền, thời gian, nội dung) và không bao giờ biết mật khẩu ngân hàng của bạn.',
  ),
  (
    'Trợ lý AI',
    'Khi bạn trò chuyện với Trợ lý tài chính, nội dung cần thiết được gửi tới DeepSeek '
        'chỉ để tạo câu trả lời và không được lưu trữ lại.',
  ),
  (
    'Không quảng cáo, không theo dõi',
    'MoMa không hiển thị quảng cáo, không bán dữ liệu và không tích hợp công cụ theo '
        'dõi hay phân tích hành vi của bên thứ ba.',
  ),
  (
    'Quyền của bạn',
    'Bạn có toàn quyền với dữ liệu của mình: xem, chỉnh sửa hoặc yêu cầu xóa bất cứ lúc nào.',
  ),
];

Future<void> _showDoc(
  BuildContext context,
  String title,
  List<(String, String)> sections,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (ctx) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    maxChildSize: 0.92,
    minChildSize: 0.4,
    builder: (ctx, scroll) => ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: ctx.pal.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Cập nhật lần cuối: 2026',
          style: TextStyle(fontSize: 12.5, color: ctx.pal.muted),
        ),
        const SizedBox(height: 12),
        for (final (i, s) in sections.indexed) ...[
          Text(
            '${i + 1}. ${s.$1}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: ctx.pal.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.$2,
            style: TextStyle(fontSize: 14, height: 1.5, color: ctx.pal.muted),
          ),
          const SizedBox(height: 14),
        ],
      ],
    ),
  ),
);
