import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/header.dart';
import '../../core/widgets.dart';

/// Settings → "Dung lượng & chi phí" (migration 022, D-028). Free tiers only: Supabase Free (500 MB database),
/// Cloudflare R2 free (10 GB pictures); the only paid item is AI (DeepSeek), shown per feature.
class CapacityReport {
  const CapacityReport({
    required this.dbBytes,
    required this.dbLimit,
    required this.r2Bytes,
    required this.r2Limit,
    required this.attachments,
    required this.txCount,
    required this.label,
    required this.pct,
    required this.monthsTo80,
    required this.aiThisMonthMicro,
    required this.aiCalls,
    required this.aiByFeature,
    required this.aiMonths,
    required this.lastRunAt,
    required this.top,
  });

  factory CapacityReport.fromJson(Map<String, dynamic> j) {
    final p = (j['projection'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ai = (j['ai'] as Map?)?.cast<String, dynamic>() ?? const {};
    num n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
    return CapacityReport(
      dbBytes: n(j['db_bytes']).toInt(),
      dbLimit: n(j['db_limit_bytes']).toInt(),
      r2Bytes: n(j['r2_bytes']).toInt(),
      r2Limit: n(j['r2_limit_bytes']).toInt(),
      attachments: n(j['attachments']).toInt(),
      txCount: n(j['tx_count']).toInt(),
      label: '${p['label'] ?? ''}',
      pct: n(p['pct']).toDouble(),
      monthsTo80: p['months_to_80'] == null
          ? null
          : n(p['months_to_80']).toDouble(),
      aiThisMonthMicro: n(ai['this_month_micro_usd']).toInt(),
      aiCalls: n(ai['this_month_calls']).toInt(),
      aiByFeature: [
        for (final f in (ai['by_feature'] as List? ?? const []))
          (
            feature: '${(f as Map)['feature']}',
            calls: n(f['calls']).toInt(),
            micro: n(f['micro_usd']).toInt(),
          ),
      ],
      aiMonths: [
        for (final m in (ai['months'] as List? ?? const []))
          (period: '${(m as Map)['period']}', micro: n(m['micro_usd']).toInt()),
      ],
      lastRunAt: DateTime.tryParse('${j['last_run_at']}')?.toLocal(),
      top: [
        for (final t in (j['top'] as List? ?? const []))
          (table: '${(t as Map)['table']}', bytes: n(t['bytes']).toInt()),
      ],
    );
  }

  final int dbBytes;
  final int dbLimit;
  final int r2Bytes;
  final int r2Limit;
  final int attachments;
  final int txCount;
  final String label;
  final double pct;
  final double? monthsTo80;
  final int aiThisMonthMicro;
  final int aiCalls;
  final List<({String feature, int calls, int micro})> aiByFeature;
  final List<({String period, int micro})> aiMonths;
  final DateTime? lastRunAt;
  final List<({String table, int bytes})> top;

  /// Average AI cost of the previous full months (micro-USD), null when there is no history yet.
  int? get aiMonthlyAverage {
    final now = DateTime.now();
    final cur = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final past = aiMonths.where((m) => !m.period.startsWith(cur)).toList();
    if (past.isEmpty) return null;
    return (past.fold<int>(0, (s, m) => s + m.micro) / past.length).round();
  }
}

final capacityProvider = FutureProvider.autoDispose<CapacityReport>((
  ref,
) async {
  final r = await ref.watch(apiProvider).get('/system/capacity');
  return CapacityReport.fromJson((r as Map).cast<String, dynamic>());
});

const _featureNames = {
  'agent': 'Trợ lý (chat)',
  'assistant': 'Trợ lý (nhập nhanh)',
  'classify': 'Tự phân loại',
  'bill': 'Đọc hóa đơn',
  'insight': 'Nhận xét chi tiêu',
  'reflect': 'Ghi nhớ thói quen',
  'plan': 'Kế hoạch & dự toán',
  'knowledge': 'Tin tức & tri thức',
  'other': 'Khác',
};

String featureLabel(String f) => _featureNames[f] ?? f;

String bytesLabel(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// micro-USD → "≈ 1.234đ ($0,05)" at a fixed reference rate (display only).
String aiCostLabel(int micro) {
  const vndPerUsd = 26000;
  final usd = micro / 1e6;
  final vnd = (usd * vndPerUsd).round();
  final v = vnd.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => '.',
  );
  return '≈ $vđ (\$${usd.toStringAsFixed(usd < 0.1 ? 3 : 2)})';
}

class CapacityPage extends ConsumerStatefulWidget {
  const CapacityPage({super.key});
  @override
  ConsumerState<CapacityPage> createState() => _CapacityPageState();
}

class _CapacityPageState extends ConsumerState<CapacityPage> {
  bool _busy = false;

  Future<void> _cleanup() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(apiProvider).post('/system/cleanup', const {});
      final totals = ((r as Map)['totals'] as Map?) ?? const {};
      final n = totals.values.fold<num>(0, (s, v) => s + (v is num ? v : 0));
      ref.invalidate(capacityProvider);
      if (mounted) {
        showSnack(
          context,
          n == 0
              ? 'Không có gì cần dọn, dữ liệu đã gọn.'
              : 'Đã dọn $n dòng dữ liệu phụ.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ref.watch(capacityProvider);
    return Scaffold(
      body: MomaPage(
        title: 'Dung lượng & chi phí',
        showBack: true,
        child: r.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(capacityProvider),
          ),
          data: (c) => RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(capacityProvider);
              await ref.read(capacityProvider.future);
            },
            child: _content(context, c),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, CapacityReport c) {
    final pal = context.pal;
    final dbFrac = c.dbLimit > 0
        ? (c.dbBytes / c.dbLimit).clamp(0.0, 1.0)
        : 0.0;
    final r2Frac = c.r2Limit > 0
        ? (c.r2Bytes / c.r2Limit).clamp(0.0, 1.0)
        : 0.0;
    final avg = c.aiMonthlyAverage;
    Widget card(List<Widget> children) => Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
    Text title(String s) => Text(
      s,
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 15.5,
        color: pal.ink,
      ),
    );
    Text muted(String s) =>
        Text(s, style: TextStyle(color: pal.muted, fontSize: 13, height: 1.4));
    Widget bar(double frac) {
      final color = frac >= 0.8
          ? MomaColors.expense
          : (frac >= 0.6 ? pal.warnInk : MomaColors.emerald);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: frac,
          minHeight: 10,
          color: color,
          backgroundColor: pal.surfaceAlt,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        card([
          Row(
            children: [
              Icon(Symbols.database_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(child: title('Dữ liệu (miễn phí 500 MB)')),
              Text(
                '${c.pct.toStringAsFixed(c.pct < 10 ? 1 : 0)}%',
                style: TextStyle(fontWeight: FontWeight.w800, color: pal.ink),
              ),
            ],
          ),
          const SizedBox(height: 10),
          bar(dbFrac),
          const SizedBox(height: 8),
          muted(
            '${bytesLabel(c.dbBytes)} / ${bytesLabel(c.dbLimit)} · ${c.txCount} giao dịch',
          ),
          const SizedBox(height: 6),
          Text(
            c.label,
            key: const Key('capacity-label'),
            style: TextStyle(fontWeight: FontWeight.w700, color: pal.accentInk),
          ),
        ]),
        card([
          Row(
            children: [
              Icon(Symbols.photo_library_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(child: title('Ảnh chứng từ (miễn phí 10 GB)')),
            ],
          ),
          const SizedBox(height: 10),
          bar(r2Frac),
          const SizedBox(height: 8),
          muted('${bytesLabel(c.r2Bytes)} · ${c.attachments} ảnh'),
        ]),
        card([
          Row(
            children: [
              Icon(Symbols.auto_awesome_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(child: title('Chi phí AI tháng này')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            aiCostLabel(c.aiThisMonthMicro),
            key: const Key('ai-cost'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: pal.ink,
            ),
          ),
          muted(
            '${c.aiCalls} lượt gọi${avg != null ? ' · trung bình ${aiCostLabel(avg)}/tháng' : ''}',
          ),
          if (c.aiByFeature.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final f in c.aiByFeature)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        featureLabel(f.feature),
                        style: TextStyle(color: pal.ink),
                      ),
                    ),
                    Text(
                      '${f.calls} lượt · ${aiCostLabel(f.micro)}',
                      style: TextStyle(color: pal.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
          muted(
            'AI là khoản duy nhất có phí; mọi thứ khác dùng gói miễn phí. MoMa ưu tiên quy tắc và lịch sử của bạn, '
            'chỉ gọi AI khi cần, tắt chế độ "suy nghĩ" và tận dụng bộ nhớ đệm của DeepSeek để giảm chi phí.',
          ),
        ]),
        card([
          Row(
            children: [
              Icon(Symbols.mop_rounded, color: pal.accentInk),
              const SizedBox(width: 10),
              Expanded(child: title('Tự dọn dữ liệu phụ')),
            ],
          ),
          const SizedBox(height: 6),
          muted(
            'Mỗi đêm MoMa tự dọn những thứ đã hết tác dụng (nhật ký đồng bộ, khóa chống trùng, thông báo đã đọc lâu ngày…) '
            'và gộp chi tiết cũ thành số liệu theo tháng. Sổ cái, tài khoản, công nợ, mục tiêu và những gì Trợ lý đã học '
            'luôn được giữ nguyên.',
          ),
          const SizedBox(height: 6),
          muted(
            c.lastRunAt == null
                ? 'Chưa chạy lần nào.'
                : 'Lần dọn gần nhất: ${_when(c.lastRunAt!)}',
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _cleanup,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.cleaning_services_rounded),
            label: const Text('Dọn dẹp ngay'),
          ),
        ]),
        if (c.pct >= 60)
          card([
            title('Khi gần đầy'),
            const SizedBox(height: 6),
            muted(
              'Vẫn hoàn toàn miễn phí: MoMa siết thời gian giữ dữ liệu phụ, lưu trữ các năm cũ đã khóa sổ sang kho ảnh R2 '
              '(nén, đọc lại khi cần) hoặc chuyển sang một máy chủ Postgres miễn phí khác.',
            ),
          ]),
      ],
    );
  }
}

String _when(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)} ${two(t.day)}/${two(t.month)}/${t.year}';
}
