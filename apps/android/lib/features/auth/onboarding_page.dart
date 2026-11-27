import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/ui/brand.dart';
import '../accounts/accounts_page.dart';

/// First-run "Thiết lập ban đầu" (design 03): account created -> add a money account -> transaction sources.
class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final hasAccount = accounts.isNotEmpty;
    return Scaffold(
      backgroundColor: MomaColors.cloud,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Center(child: MomaWordmark(size: 44, dark: true)),
            const SizedBox(height: 28),
            Text(
              'Thiết lập ban đầu',
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: MomaColors.ink,
              ),
            ),
            Text(
              'Hoàn tất vài bước để bắt đầu',
              style: text.bodyMedium?.copyWith(color: MomaColors.muted),
            ),
            const SizedBox(height: 20),
            const _Step(
              index: 1,
              done: true,
              title: 'Tài khoản của bạn',
              hint: 'Đã tạo xong.',
            ),
            _Step(
              index: 2,
              done: hasAccount,
              title: 'Thêm tài khoản tài chính',
              hint: hasAccount
                  ? 'Đã có ${accounts.length} tài khoản.'
                  : 'Tiền mặt, ngân hàng hoặc ví điện tử của bạn.',
              actionLabel: hasAccount ? 'Thêm nữa' : 'Thêm tài khoản',
              onAction: () async {
                await showAddAccountSheet(context);
                ref.invalidate(accountsProvider);
              },
            ),
            const _Step(
              index: 3,
              done: false,
              title: 'Thiết lập nguồn giao dịch',
              hint: 'Tự động đọc thông báo ngân hàng sẽ có ở bản sau. Hiện tại bạn ghi giao dịch bằng tay hoặc nhờ Trợ lý AI.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/home'),
              child: Text(hasAccount ? 'Vào MoMa' : 'Để sau, vào MoMa'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.index,
    required this.done,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.onAction,
  });
  final int index;
  final bool done;
  final String title;
  final String hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: done
                ? MomaColors.emerald
                : const Color(0xFFE5ECE9),
            child: done
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                : Text(
                    '$index',
                    style: const TextStyle(
                      color: MomaColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(hint, style: const TextStyle(color: MomaColors.muted)),
                if (actionLabel != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: onAction,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
