import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/header.dart';
import 'widget_sync.dart';
import '../../core/ui/actions.dart';
import '../../core/widgets.dart';

/// Opens "Tiện ích màn hình chính" (privacy option + add-widget buttons).
Future<void> openWidgetSettings(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const WidgetSettingsPage()));

class WidgetSettingsPage extends ConsumerStatefulWidget {
  const WidgetSettingsPage({super.key});
  @override
  ConsumerState<WidgetSettingsPage> createState() => _WidgetSettingsPageState();
}

class _WidgetSettingsPageState extends ConsumerState<WidgetSettingsPage> {
  bool? _hide;
  bool? _quickBar;
  bool _canPin = false;

  Future<void> _toggleQuickBar(bool v) async {
    setState(() => _quickBar = v);
    final shown = await WidgetSync.setQuickBar(v);
    if (!mounted || !v || shown) return;
    setState(() => _quickBar = false);
    await WidgetSync.setQuickBar(false);
    if (!mounted) return;
    showSnack(context, 'Hãy bật thông báo cho MoMa để dùng thanh ghi nhanh.');
    await WidgetSync.openNotificationSettings();
  }

  Future<void> _addTile() async {
    final asked = await WidgetSync.requestQuickTile();
    if (!mounted || asked) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Thêm ô "Ghi chi nhanh"'),
        content: const Text(
          'Vuốt xuống thanh thông báo → bấm biểu tượng chỉnh sửa (bút chì hoặc ⋮ → Sửa) → tìm "Ghi chi nhanh" '
          'của MoMa → kéo lên khu vực ô đang dùng.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Đã hiểu'),
          ),
        ],
      ),
    );
  }

  static const _widgets = [
    (
      'quick',
      Symbols.bolt_rounded,
      'Thao tác nhanh',
      'Ghi chi, ghi thu, QR, Trợ lý AI · 2x1 đến 4x2',
    ),
    (
      'spend',
      Symbols.donut_large_rounded,
      'Chi tiêu hôm nay',
      'Hôm nay, tháng này, ngân sách · 2x1 đến 4x2',
    ),
    (
      'qr',
      Symbols.qr_code_2_rounded,
      'QR nhận tiền',
      'Mã VietQR của tài khoản đã liên kết · 2x1 đến 4x2',
    ),
    (
      'ai',
      Symbols.auto_awesome_rounded,
      'Trợ lý tài chính',
      'Thanh hỏi nhanh Trợ lý AI · 2x1 đến 4x1',
    ),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final hide = await WidgetSync.privacy();
      final canPin = await WidgetSync.canPin();
      final bar = await WidgetSync.quickBar();
      if (mounted) {
        setState(() {
          _hide = hide;
          _canPin = canPin;
          _quickBar = bar;
        });
      }
    });
  }

  /// Requests the launcher pin, then always explains what to expect: some launchers (Xiaomi/MIUI) drop the
  /// request silently until MoMa may create home-screen shortcuts.
  Future<void> _add(String kind, String title) async {
    final sent = _canPin && await WidgetSync.pin(kind);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sent
                    ? 'Đã gửi yêu cầu thêm "$title"'
                    : 'Thêm "$title" vào màn hình chính',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                sent
                    ? 'Nếu điện thoại hiện hộp thoại, bấm "Thêm". Nếu không thấy hộp thoại nào, '
                          'máy đang chặn MoMa tạo lối tắt: bật quyền "Lối tắt màn hình chính" rồi thử lại, '
                          'hoặc thêm bằng tay như bên dưới.'
                    : 'Máy này không cho ứng dụng tự thêm tiện ích. Bạn thêm bằng tay như bên dưới.',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 12),
              const Text(
                'Thêm bằng tay: nhấn giữ chỗ trống trên màn hình chính → Tiện ích → tìm MoMa → kéo "'
                'tiện ích muốn dùng" ra màn hình.',
                style: TextStyle(fontSize: 13.5, height: 1.45),
              ),
              const SizedBox(height: 18),
              ActionButtons(
                primaryLabel: 'Mở quyền của MoMa',
                onPrimary: () async {
                  Navigator.pop(ctx);
                  final ok = await WidgetSync.openPermissions();
                  if (!ok && mounted) {
                    showSnack(
                      context,
                      'Mở Cài đặt điện thoại → Ứng dụng → MoMa → Quyền',
                    );
                  }
                },
                secondaryLabel: 'Đóng',
                onSecondary: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MomaPage(
        title: 'Tiện ích màn hình chính',
        showBack: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Card(
              child: SwitchListTile(
                secondary: const Icon(Symbols.visibility_off_rounded),
                title: const Text('Ẩn số tiền trên tiện ích'),
                subtitle: const Text(
                  'Hiện •••••• thay cho số tiền, phù hợp khi người khác nhìn thấy màn hình chính.',
                ),
                value: _hide ?? false,
                onChanged: _hide == null
                    ? null
                    : (v) async {
                        setState(() => _hide = v);
                        await WidgetSync.setPrivacy(v);
                      },
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Ghi nhanh ngoài ứng dụng',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                secondary: const Icon(Symbols.notifications_active_rounded),
                title: const Text('Thanh ghi nhanh trên thông báo'),
                subtitle: const Text(
                  'Ghi chi, Ghi thu, Nhận tiền và món quen (vd Bánh mì 20k) ngay trên thanh thông báo, '
                  'kèm số còn tiêu được hôm nay. Màn hình khóa không hiện số tiền.',
                ),
                value: _quickBar ?? false,
                onChanged: _quickBar == null ? null : _toggleQuickBar,
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Symbols.add_box_rounded),
                title: const Text('Ô "Ghi chi nhanh" trong Cài đặt nhanh'),
                subtitle: const Text(
                  'Vuốt xuống từ đỉnh màn hình, chạm ô là mở khung ghi chi.',
                ),
                trailing: TextButton(
                  onPressed: _addTile,
                  child: const Text('Thêm'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Thêm tiện ích',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            const SizedBox(height: 8),
            for (final w in _widgets)
              Card(
                child: ListTile(
                  leading: Icon(w.$2),
                  title: Text(w.$3),
                  subtitle: Text(w.$4),
                  trailing: IconButton(
                    tooltip: 'Thêm vào màn hình chính',
                    icon: const Icon(Symbols.add_circle_rounded),
                    onPressed: () => _add(w.$1, w.$3),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Hoặc nhấn giữ trên màn hình chính → Tiện ích → MoMa. Số liệu được cập nhật mỗi khi bạn mở MoMa, '
                'ghi giao dịch, hoặc nhấn nút làm mới trên tiện ích Chi tiêu.',
                style: TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
