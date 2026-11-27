import os

os.chdir(r"D:\NhanSam\MoneyManage\moma\apps\android\lib")

# generic confirm dialog (same visual language as the error dialog)
p = "core/widgets.dart"
s = open(p, encoding="utf8", newline="").read()
if "showConfirmDialog" not in s:
    s += """
/// Confirmation before a destructive or irreversible action. Two equal buttons: safe action left, confirm right.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Đồng ý',
  String cancelLabel = 'Hủy',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = destructive ? MomaColors.expense : MomaColors.emerald;
      return Dialog(
        backgroundColor: context.pal.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.withValues(alpha: 0.1),
                ),
                child: Icon(
                  destructive ? Symbols.delete_rounded : Symbols.help_rounded,
                  color: c,
                  size: 40,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: context.pal.muted,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(cancelLabel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: c),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return ok ?? false;
}
"""
    open(p, "w", encoding="utf8", newline="").write(s)

p = "features/settings/categories_page.dart"
s = open(p, encoding="utf8", newline="").read()
a = s.index("        FilledButton(\n          onPressed: _run.busy ? null : _submit,\n          child: const Text('Lưu'),")
b = s.index("      ],\n    );\n  }\n}", a)
new = """        if (e != null && e.name != 'Khác')
          ActionButtons(
            primaryLabel: 'Lưu',
            onPrimary: _submit,
            secondaryLabel: 'Xóa danh mục',
            onSecondary: () async {
              final ok = await showConfirmDialog(
                context,
                title: 'Xóa danh mục "${e.name}"?',
                message:
                    'Danh mục sẽ được ẩn khỏi danh sách. Các giao dịch đã ghi trước đó vẫn giữ nguyên.',
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
"""
s = s[:a] + new + s[b:]
if "core/ui/actions.dart" not in s:
    s = s.replace("import '../../core/widgets.dart';", "import '../../core/ui/actions.dart';\nimport '../../core/widgets.dart';", 1)
open(p, "w", encoding="utf8", newline="").write(s)
print("ok")
