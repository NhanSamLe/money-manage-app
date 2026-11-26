import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 300,
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [MomaColors.forest, MomaColors.emerald],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(36)),
            ),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.show_chart_rounded,
                    size: 72,
                    color: MomaColors.mint,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'MoMa',
                    style: text.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'MoneyManage',
                    style: text.titleMedium?.copyWith(color: MomaColors.mint),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Chào mừng đến với MoMa',
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: MomaColors.forest,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ứng dụng quản lý tài chính cá nhân thông minh, giúp bạn theo dõi chi tiêu, tiết kiệm và đạt mục tiêu tài chính dễ dàng hơn.',
                    style: text.bodyMedium?.copyWith(color: MomaColors.muted),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    color: const Color(0xFFE9F6EE),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.person_outline_rounded,
                            color: MomaColors.emerald,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'MoMa được thiết kế cho 1 chủ sở hữu duy nhất, giúp bạn quản lý tài chính cá nhân an toàn và riêng tư.',
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Tôi đã có tài khoản'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => context.go('/setup'),
                    child: const Text('Thiết lập mới'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
