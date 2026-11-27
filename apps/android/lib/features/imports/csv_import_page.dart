import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/csv_statement.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/sheets.dart';
import '../../app/theme/palette.dart';

class _Line {
  _Line(this.row, this.kind, this.categoryId, this.categoryName);
  final StatementRow row;
  final String kind;
  final String? categoryId;
  final String? categoryName;
  bool selected = true;
}

/// Statement import (CSV). Parsing is local; every row is posted through the normal idempotent TX_CREATE command.
/// Unmatched rows go to suspense (UNKNOWN_*), never guessed. Limitation: no cross-source dedup yet (Gate 3).
class CsvImportPage extends ConsumerStatefulWidget {
  const CsvImportPage({super.key});
  @override
  ConsumerState<CsvImportPage> createState() => _CsvImportPageState();
}

class _CsvImportPageState extends ConsumerState<CsvImportPage> {
  final _paste = TextEditingController();
  String? _accountId;
  DateTime? _from;
  StatementResult? _result;
  List<_Line> _lines = const [];
  bool _busy = false;
  String? _error;
  String? _summary;
  int _done = 0;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    _paste.text = utf8.decode(bytes, allowMalformed: true);
    _parse();
  }

  void _parse() {
    final cats = ref.read(categoriesProvider).value ?? <Category>[];
    final result = parseStatementCsv(_paste.text);
    final lines = <_Line>[];
    for (final r in result.rows) {
      if (_from != null && r.date.isBefore(_from!)) continue;
      final q = parseQuickText(r.description);
      // Only classify on a keyword match; otherwise the row posts to suspense (BR-16/17).
      final cat = q.categoryName == null
          ? null
          : cats
                .where(
                  (c) =>
                      c.name == q.categoryName &&
                      c.type == (r.isCredit ? 'INCOME' : 'EXPENSE'),
                )
                .firstOrNull;
      final kind = cat != null
          ? (r.isCredit ? 'INCOME' : 'EXPENSE')
          : (r.isCredit ? 'UNKNOWN_CREDIT' : 'UNKNOWN_DEBIT');
      lines.add(_Line(r, kind, cat?.id, cat?.name));
    }
    setState(() {
      _result = result;
      _lines = lines;
      _summary = null;
      _error = result.rows.isEmpty && result.skipped.isNotEmpty
          ? result.skipped.first
          : null;
    });
  }

  Future<void> _import() async {
    final accountId = _accountId;
    final result = _result;
    if (accountId == null || result == null) return;
    final chosen = _lines.where((l) => l.selected).toList();
    setState(() {
      _busy = true;
      _done = 0;
      _error = null;
      _summary = null;
    });
    var ok = 0;
    var replayed = 0;
    final failed = <String>[];
    final api = ref.read(apiProvider);
    for (final l in chosen) {
      try {
        final res = await api.command('TX_CREATE', {
          'kind': l.kind,
          'account_id': accountId,
          'amount': l.row.amount.abs().toString(),
          'effective_at': l.row.date.toUtc().toIso8601String(),
          'category_id': ?l.categoryId,
          if (l.row.description.isNotEmpty)
            'note': l.row.description.length > 1000
                ? l.row.description.substring(0, 1000)
                : l.row.description,
        }, commandId: importCommandId(accountId, result.fingerprint, l.row));
        if (res['status'] == 'REPLAYED') {
          replayed++;
        } else {
          ok++;
        }
      } on ApiException catch (e) {
        failed.add('Dòng ${l.row.rowNo}: ${e.message}');
        if (!e.retryable && e.code != 'VALIDATION_FAILED') continue;
      }
      if (mounted) setState(() => _done++);
    }
    refreshAll(ref);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _summary =
          'Đã ghi $ok giao dịch mới, $replayed dòng đã nhập trước đó, ${failed.length} lỗi.'
          '${failed.isEmpty ? '' : '\n${failed.take(5).join('\n')}'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final accounts = (ref.watch(accountsProvider).value ?? <Account>[])
        .where((a) => !a.isCard)
        .toList();
    final selected = _lines.where((l) => l.selected).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhập sao kê CSV'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            color: Color(0xFFFFF4D6),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Nếu tài khoản đã có số dư đầu kỳ, chỉ nhập các dòng phát sinh SAU ngày đó '
                '(chọn "Từ ngày"). Dòng không nhận diện được danh mục sẽ vào mục "chưa phân loại".',
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _accountId,
            decoration: const InputDecoration(
              labelText: 'Tài khoản nhận dữ liệu',
            ),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
          const SizedBox(height: 12),
          ListTile(
            tileColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: const Icon(Icons.event_rounded),
            title: Text(
              _from == null ? 'Từ ngày (tùy chọn)' : 'Từ ${dateLabel(_from!)}',
            ),
            trailing: _from == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () => setState(() => _from = null),
                  ),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 1)),
              );
              if (d != null) setState(() => _from = d);
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickFile,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('Chọn tệp CSV'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _paste,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Hoặc dán nội dung CSV (có dòng tiêu đề: Ngày, Diễn giải, Ghi nợ, Ghi có)',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _parse,
            child: const Text('Đọc dữ liệu'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(color: MomaColors.expense),
              ),
            ),
          if (_result != null && _lines.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Tìm thấy ${_lines.length} dòng'
              '${_result!.skipped.isEmpty ? '' : ', bỏ qua ${_result!.skipped.length} dòng không đọc được'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final l in _lines)
              CheckboxListTile(
                value: l.selected,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => l.selected = v ?? false),
                dense: true,
                title: Text(
                  l.row.description.isEmpty
                      ? '(không có diễn giải)'
                      : l.row.description,
                ),
                subtitle: Text(
                  '${dateLabel(l.row.date)} · ${l.categoryName ?? 'Chưa phân loại'}',
                ),
                secondary: Text(
                  '${l.row.isCredit ? '+' : '-'}${formatVnd(l.row.amount.abs())}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: l.row.isCredit
                        ? MomaColors.income
                        : MomaColors.expense,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || _accountId == null || selected == 0
                  ? null
                  : _import,
              child: Text(
                _busy
                    ? 'Đang ghi $_done/$selected...'
                    : 'Ghi $selected giao dịch',
              ),
            ),
            if (_accountId == null)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Chọn tài khoản trước khi ghi.',
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
          ],
          if (_summary != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _summary!,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
