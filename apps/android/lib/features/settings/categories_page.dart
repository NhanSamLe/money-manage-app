import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ui/labeled_field.dart';

import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';

import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme/palette.dart';

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
          icon: const Icon(Symbols.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            showFormSheet<void>(context, (_) => const _CategorySheet()),
        icon: const Icon(Symbols.add_rounded),
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
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: context.pal.accentInk,
                  ),
                ),
              ),
              for (final c in list.where((c) => c.type == type))
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: context.pal.tint,
                      child: Icon(
                        categoryIcon(c.icon),
                        color: context.pal.accentInk,
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
          PillTabs<String>(
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
        LabeledField(
          label: 'Tên danh mục',
          hint: 'Nhập tên danh mục',
          controller: _name,
        ),
        const SizedBox(height: 12),
        PickField<String?>(
          isExpanded: true,
          initialValue: _parentId,
          decoration: const InputDecoration(labelText: 'Danh mục cha'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Không')),
            for (final p in parents)
              DropdownMenuItem<String?>(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() => _parentId = v),
        ),
        FormError(_run.error),
        const SizedBox(height: 16),
        if (e != null && e.name != 'Khác')
          ActionButtons(
            primaryLabel: 'Lưu',
            onPrimary: _submit,
            secondaryLabel: 'Xóa danh mục',
            onSecondary: () async {
              final ok = await showConfirmDialog(
                context,
                title: 'Xóa danh mục "${e.name}"?',
                message: 'Danh mục sẽ được ẩn khỏi danh sách. Các giao dịch đã ghi trước đó vẫn giữ nguyên.',
                confirmLabel: 'Xóa',
                destructive: true,
              );
              if (ok) await _submit(archive: true);
            },
            busy: _run.busy,
          )
        else
          ActionButtons(
            primaryLabel: 'Lưu',
            onPrimary: _submit,
            busy: _run.busy,
          ),
      ],
    );
  }
}
