import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/header.dart';
import 'widget_sync.dart';

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
  bool _canPin = false;

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
      if (mounted) {
        setState(() {
          _hide = hide;
          _canPin = canPin;
        });
      }
    });
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
                  trailing: _canPin
                      ? IconButton(
                          tooltip: 'Thêm vào màn hình chính',
                          icon: const Icon(Symbols.add_circle_rounded),
                          onPressed: () => WidgetSync.pin(w.$1),
                        )
                      : null,
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
