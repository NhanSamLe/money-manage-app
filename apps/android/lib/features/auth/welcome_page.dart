import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/ui/brand.dart';
import 'welcome_hero.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.white,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  MomaColors.forest,
                  MomaColors.emerald,
                  Color(0xFFEAF7F0),
                ],
                stops: [0, 0.55, 1],
              ),
            ),
            child: CustomPaint(
              painter: _Waves(),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: Column(
                    children: [
                      const MomaWordmark(size: 50),
                      const SizedBox(height: 14),
                      const WelcomeHero(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Chào mừng đến với MoMa 👋',
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: MomaColors.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Ứng dụng quản lý tài chính cá nhân thông minh, giúp bạn theo dõi chi tiêu, tiết kiệm và đạt mục tiêu tài chính dễ dàng hơn.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: MomaColors.muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF7F0),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: MomaColors.mint.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.person_outline_rounded,
                          color: MomaColors.emerald,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ứng dụng dành cho cá nhân',
                              style: text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'MoMa được thiết kế cho 1 chủ sở hữu duy nhất, giúp bạn quản lý toàn bộ tài chính an toàn và riêng tư.',
                              style: text.bodySmall?.copyWith(
                                color: MomaColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _ActionButton(
                  filled: true,
                  icon: Icons.person_outline_rounded,
                  label: 'Tôi đã có tài khoản',
                  onTap: () => context.go('/login'),
                ),
                const SizedBox(height: 12),
                _ActionButton(
                  filled: false,
                  icon: Icons.add_circle_outline_rounded,
                  label: 'Tạo tài khoản mới',
                  onTap: () => context.go('/register'),
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.verified_user_outlined,
                      color: MomaColors.emerald,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Dữ liệu của bạn được mã hóa, bảo mật và chỉ phục vụ cho tài khoản của bạn.',
                        style: text.bodySmall?.copyWith(
                          color: MomaColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.filled,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final bool filled;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : MomaColors.forest;
    return Material(
      color: filled ? MomaColors.emerald : const Color(0xFFF1FAF5),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: MomaColors.mint, width: 1.5),
                ),
          child: Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}

class _Waves extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()..moveTo(0, s.height * 0.5);
    for (var x = 0.0; x <= s.width; x += 4) {
      p.lineTo(x, s.height * 0.45 + math.sin(x / s.width * math.pi * 1.6) * 26);
    }
    p
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(p, Paint()..color = Colors.white.withValues(alpha: 0.08));
  }

  @override
  bool shouldRepaint(_Waves old) => false;
}
