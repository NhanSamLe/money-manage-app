import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/ui/category_style.dart';

class _Topic {
  const _Topic(this.icon, this.color, this.title, this.lines);
  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;
}

const _topics = <_Topic>[
  _Topic(Symbols.add_circle_rounded, Color(0xFF1B8A5A), 'Ghi một giao dịch', [
    'Bấm nút + ở Trang chủ hoặc Giao dịch.',
    'Gõ câu tự nhiên như "ăn trưa 65k" hoặc "nhận lương 15tr", MoMa tự điền số tiền và danh mục.',
    'Chọn tài khoản, kiểm tra lại rồi bấm Lưu. Sai thì mở giao dịch để sửa hoặc hủy, sổ cái luôn giữ lịch sử.',
  ]),
  _Topic(Symbols.auto_awesome_rounded, Color(0xFF8B5CF6), 'Trợ lý AI', [
    'Mở tab Trợ lý AI và nhắn như nhắn tin: "Hôm nay ăn tối 200k bằng tiền mặt".',
    'Trợ lý chỉ đề xuất. Bạn bấm Xác nhận ghi thì giao dịch mới được lưu.',
    'Hỏi "tháng này tiêu bao nhiêu" để xem nhanh thu chi, số liệu do hệ thống tính.',
  ]),
  _Topic(
    Symbols.filter_alt_rounded,
    Color(0xFF2F80ED),
    'Tìm và lọc giao dịch',
    [
      'Ở tab Giao dịch, gõ từ khóa không cần dấu vào ô tìm kiếm.',
      'Bấm các nút Loại, Thời gian, Danh mục, Tài khoản để lọc. Bảng chọn trượt từ dưới lên.',
    ],
  ),
  _Topic(Symbols.bar_chart_rounded, Color(0xFFFF8A3D), 'Xem báo cáo', [
    'Tab Báo cáo cho thấy tổng thu chi, tỷ trọng theo danh mục và chi tiêu theo ngày hoặc tuần.',
    'Đổi tháng bằng mũi tên hoặc bấm vào tên tháng để chọn nhanh.',
  ]),
  _Topic(
    Symbols.savings_rounded,
    Color(0xFF0E7490),
    'Mục tiêu, ngân sách, công nợ, định kỳ',
    [
      'Vào Cài đặt, mục Kế hoạch. Mục tiêu tiết kiệm chỉ là khoản dành riêng, không trừ vào số dư.',
      'Ngân sách giúp biết khi sắp chi vượt. Công nợ ghi ai nợ bạn hoặc bạn nợ ai. Định kỳ nhắc tiền nhà, hóa đơn, lương.',
    ],
  ),
  _Topic(Symbols.cloud_off_rounded, Color(0xFFE0A100), 'Khi mất mạng', [
    'Giao dịch bạn ghi lúc mất mạng được giữ trên máy và tự gửi khi có mạng lại, không bao giờ bị ghi trùng.',
  ]),
];

/// "How to use MoMa" cards, shared by the setup wizard's last step and the Guide screen.
class GuideCards extends StatelessWidget {
  const GuideCards({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Column(
      children: [
        for (final t in _topics)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: pal.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CategoryAvatar(iconData: t.icon, color: t.color, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: pal.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final l in t.lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 6,
                                  right: 8,
                                ),
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: t.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  l,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.45,
                                    color: pal.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
