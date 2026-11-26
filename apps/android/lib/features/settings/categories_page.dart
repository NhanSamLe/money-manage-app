import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';

/// Category management: add, rename, archive. System ledger accounts back each category; the class never changes.
class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(categoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh mục'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            showFormSheet<void>(context, (_) => const _CategorySheet()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Thêm'),
      ),
      body: cats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(categoriesProvider),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            for (final type in const ['EXPENSE', 'INCOME']) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text(
                  type == 'EXPENSE' ? 'Chi tiêu' : 'Thu nhập',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: MomaColors.forest,
                  ),
                ),
              ),
              for (final c in list.where((c) => c.type == type))
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: MomaColors.mint.withValues(alpha: 0.4),
                      child: Icon(
                        categoryIcon(c.icon),
                        color: MomaColors.forest,
                      ),
                    ),
                    title: Text(c.name),
                    subtitle: c.parentId == null
                        ? null
                        : Text(
                            'Thuộc: ${list.where((p) => p.id == c.parentId).map((p) => p.name).firstOrNull ?? ''}',
                          ),
                    onTap: () => showFormSheet<void>(
                      context,
                      (_) => _CategorySheet(existing: c),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategorySheet extends ConsumerStatefulWidget {
  const _CategorySheet({this.existing});
  final Category? existing;
  @override
  ConsumerState<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends ConsumerState<_CategorySheet> {
  late final FormRunner _run = FormRunner(setState);
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _type = widget.existing?.type ?? 'EXPENSE';
  late String? _parentId = widget.existing?.parentId;
  final String _id = ApiClient.newId();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit({bool archive = false}) async {
    if (_name.text.trim().isEmpty) {
      setState(() => _run.error = 'Nhập tên danh mục.');
      return;
    }
    final e = widget.existing;
    final ok = await _run.run(
      () => ref.read(apiProvider).command('CATEGORY_UPSERT', {
        'name': _name.text.trim(),
        'type': _type,
        'category_id': ?e?.id,
        'parent_id': ?_parentId,
        'expected_version': ?e?.version,
        if (archive) 'archived': true,
      }, commandId: _id),
    );
    if (ok && mounted) {
      ref.invalidate(categoriesProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.existing;
    final parents = (ref.watch(categoriesProvider).value ?? <Category>[])
        .where((c) => c.type == _type && c.id != e?.id && c.parentId == null)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          e == null ? 'Thêm danh mục' : 'Sửa danh mục',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        if (e == null)
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'EXPENSE', label: Text('Chi tiêu')),
              ButtonSegment(value: 'INCOME', label: Text('Thu nhập')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _parentId = null;
            }),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.label_outline_rounded),
            hintText: 'Tên danh mục',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _parentId,
          decoration: const InputDecoration(
            labelText: 'Danh mục cha (tùy chọn)',
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Không')),
            for (final p in parents)
              DropdownMenuItem<String?>(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() => _parentId = v),
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _run.busy ? null : _submit,
          child: const Text('Lưu'),
        ),
        if (e != null && e.name != 'Khác')
          TextButton(
            onPressed: _run.busy ? null : () => _submit(archive: true),
            child: const Text('Lưu trữ danh mục này'),
          ),
      ],
    );
  }
}
