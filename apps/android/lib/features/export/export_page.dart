import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/header.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'export_format.dart';
import 'export_service.dart';

/// "Xuất dữ liệu": transactions of a period as Excel (with accounts, debts, budgets and goals sheets) or CSV.
/// The file is built in memory, then saved through the system "save as" dialog or shared.
class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});
  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  ExportRange _range = ExportRange.thisMonth;
  DateTimeRange? _custom;
  ExportFormat _format = ExportFormat.xlsx;
  bool _busy = false;
  String _step = '';
  int _fetched = 0;
  ExportResult? _result;
  String? _resultKey;
  String? _done;

  String get _key =>
      '${_range.name}|${_format.name}|${_custom?.start}|${_custom?.end}';

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _tag(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  String get _rangeTag {
    final now = DateTime.now();
    return switch (_range) {
      ExportRange.thisMonth =>
        '${now.year}-${now.month.toString().padLeft(2, '0')}',
      ExportRange.lastMonth => () {
        final d = DateTime(now.year, now.month - 1);
        return '${d.year}-${d.month.toString().padLeft(2, '0')}';
      }(),
      ExportRange.thisYear => '${now.year}',
      ExportRange.all => 'tat-ca-${_tag(now)}',
      ExportRange.custom =>
        _custom == null
            ? _tag(now)
            : '${_tag(_custom!.start)}-${_tag(_custom!.end)}',
    };
  }

  Future<void> _pickRange(ExportRange? v) async {
    if (v == null) return;
    if (v == ExportRange.custom) {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2015),
        lastDate: DateTime(now.year, now.month, now.day),
        initialDateRange:
            _custom ??
            DateTimeRange(start: DateTime(now.year, now.month), end: now),
        helpText: 'Chọn khoảng ngày',
        saveText: 'Xong',
      );
      if (!mounted) return;
      if (picked == null) {
        // Nothing picked: keep the previous choice (rebuild resets the field).
        setState(() {});
        return;
      }
      setState(() {
        _custom = picked;
        _range = v;
      });
      return;
    }
    setState(() => _range = v);
  }

  Future<ExportResult?> _build() async {
    if (_result != null && _resultKey == _key) return _result;
    final key = _key;
    setState(() {
      _busy = true;
      _step = 'Đang chuẩn bị';
      _fetched = 0;
      _done = null;
    });
    try {
      final bounds = exportBounds(
        _range,
        DateTime.now().toUtc(),
        customStart: _custom?.start,
        customEnd: _custom?.end,
      );
      final res = await buildExport(
        ref.read(apiProvider),
        bounds: bounds,
        format: _format,
        rangeTag: _rangeTag,
        onProgress: (step, n) {
          if (mounted) {
            setState(() {
              _step = step;
              _fetched = n;
            });
          }
        },
      );
      _result = res;
      _resultKey = key;
      return res;
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
      return null;
    } catch (_) {
      if (mounted) {
        await showErrorDialog(
          context,
          'Không tạo được file xuất. Bạn thử lại sau ít phút nhé.',
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final res = await _build();
    if (res == null || !mounted) return;
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Lưu file xuất dữ liệu',
        fileName: res.fileName,
        bytes: res.bytes,
        mimeType: res.mimeType,
      );
      if (!mounted || uri == null) return;
      setState(
        () => _done =
            'Đã lưu ${res.fileName} với ${res.transactionCount} giao dịch.',
      );
    } catch (_) {
      if (mounted) {
        await showErrorDialog(
          context,
          'Không lưu được file. Bạn thử chọn thư mục khác hoặc dùng "Chia sẻ".',
        );
      }
    }
  }

  Future<void> _share() async {
    final res = await _build();
    if (res == null || !mounted) return;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              res.bytes,
              name: res.fileName,
              mimeType: res.mimeType,
            ),
          ],
          fileNameOverrides: [res.fileName],
          subject: 'Dữ liệu MoMa',
        ),
      );
      if (!mounted) return;
      setState(
        () => _done =
            'Đã tạo ${res.fileName} với ${res.transactionCount} giao dịch.',
      );
    } catch (_) {
      if (mounted) {
        await showErrorDialog(context, 'Không mở được bảng chia sẻ.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      body: MomaPage(
        title: 'Xuất dữ liệu',
        showBack: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            PickField<ExportRange>(
              key: ValueKey('range-${_range.name}-${_custom?.start}'),
              initialValue: _range,
              decoration: const InputDecoration(labelText: 'Khoảng thời gian'),
              icon: Symbols.date_range_rounded,
              items: [
                for (final r in ExportRange.values)
                  DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: _busy ? null : _pickRange,
            ),
            if (_range == ExportRange.custom && _custom != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Từ ${_fmt(_custom!.start)} đến ${_fmt(_custom!.end)}',
                        style: TextStyle(color: pal.muted, fontSize: 13.5),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _pickRange(ExportRange.custom),
                      child: const Text('Đổi'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            const HelpLabel(
              'Định dạng',
              help:
                  'Excel (.xlsx) gồm các trang Giao dịch, Tài khoản, Công nợ, Ngân sách và Mục tiêu. '
                  'CSV chỉ gồm giao dịch, mở được bằng Excel, Google Sheets và hầu hết phần mềm kế toán.',
            ),
            const SizedBox(height: 6),
            PillTabs<ExportFormat>(
              segments: const [
                ButtonSegment(value: ExportFormat.xlsx, label: Text('Excel')),
                ButtonSegment(value: ExportFormat.csv, label: Text('CSV')),
              ],
              selected: {_format},
              onSelectionChanged: (s) {
                if (!_busy) setState(() => _format = s.first);
              },
            ),
            const SizedBox(height: 18),
            _ContentCard(format: _format),
            const SizedBox(height: 18),
            if (_busy) ...[
              LinearProgressIndicator(
                borderRadius: BorderRadius.circular(8),
                color: MomaColors.emerald,
              ),
              const SizedBox(height: 8),
              Text(
                _fetched > 0 ? '$_step: $_fetched giao dịch' : _step,
                style: TextStyle(color: pal.muted, fontSize: 13.5),
              ),
              const SizedBox(height: 18),
            ],
            if (_done != null && !_busy) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: pal.tintSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Symbols.check_circle_rounded,
                      color: MomaColors.emerald,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_done!, style: TextStyle(color: pal.ink)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],
            ActionButtons(
              primaryLabel: 'Lưu file',
              onPrimary: _save,
              secondaryLabel: 'Chia sẻ',
              onSecondary: _share,
              busy: _busy,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContentCard extends StatelessWidget {
  const _ContentCard({required this.format});
  final ExportFormat format;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final lines = format == ExportFormat.xlsx
        ? const [
            (Symbols.receipt_long_rounded, 'Giao dịch trong khoảng đã chọn'),
            (Symbols.account_balance_wallet_rounded, 'Tài khoản và số dư'),
            (Symbols.handshake_rounded, 'Công nợ phải thu, phải trả'),
            (Symbols.pie_chart_rounded, 'Ngân sách của tháng cuối khoảng'),
            (Symbols.savings_rounded, 'Mục tiêu tiết kiệm'),
          ]
        : const [
            (Symbols.receipt_long_rounded, 'Giao dịch trong khoảng đã chọn'),
          ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nội dung file',
            style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
          ),
          const SizedBox(height: 10),
          for (final (icon, text) in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: MomaColors.emerald),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(text, style: TextStyle(color: pal.ink)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'Mỗi giao dịch có ngày giờ (giờ Việt Nam), loại, số tiền (thu dương, chi âm), phí, danh mục, '
            'tài khoản, nơi giao dịch, ghi chú và trạng thái.',
            style: TextStyle(color: pal.muted, fontSize: 12.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}
