import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/brand.dart';
import '../../core/ui/motion.dart';
import '../auth/welcome_hero.dart';

class _Slide {
  const _Slide(this.title, this.body, this.art);
  final String title;
  final String body;
  final Widget art;
}

/// First-run introduction (design 01 "Splash & Chào mừng"): three slides, dots, skip, then the welcome screen.
class IntroPage extends ConsumerStatefulWidget {
  const IntroPage({super.key});
  @override
  ConsumerState<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends ConsumerState<IntroPage> {
  final _page = PageController();
  int _index = 0;

  static const _slides = <_Slide>[
    _Slide(
      'Quản lý tài chính thông minh, đơn giản',
      'Ghi chép thu chi, theo dõi số dư các tài khoản và xem bức tranh tài chính của bạn trong một ứng dụng.',
      WelcomeHero(height: 260),
    ),
    _Slide(
      'Ghi nhanh bằng câu nói tự nhiên',
      'Gõ "ăn trưa 65k" hoặc nhờ Trợ lý AI. Trợ lý chỉ đề xuất, bạn xác nhận thì mới ghi vào sổ.',
      _IconArt(Icons.auto_awesome_rounded, Icons.chat_bubble_outline_rounded),
    ),
    _Slide(
      'Mục tiêu, ngân sách và công nợ trong tầm tay',
      'Đặt hạn mức chi tiêu, tiết kiệm cho mục tiêu và nhớ ai đang nợ bạn, bạn đang nợ ai.',
      _IconArt(Icons.savings_rounded, Icons.pie_chart_rounded),
    ),
  ];

  Future<void> _finish() async {
    await ref.read(storeProvider).setIntroSeen();
    if (mounted) context.go('/welcome');
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _slides.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: [
                  const MomaWordmark(size: 34, dark: true),
                  const Spacer(),
                  TextButton(
                    onPressed: _finish,
                    child: Text(
                      'Bỏ qua',
                      style: TextStyle(color: context.pal.muted),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _page,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _slides[i].art,
                      const SizedBox(height: 28),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 120),
                        child: Text(
                          _slides[i].title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 260),
                        child: Text(
                          _slides[i].body,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: context.pal.muted, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _index
                          ? MomaColors.emerald
                          : context.pal.line,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: ActionButtons(
                primaryLabel: last ? 'Bắt đầu' : 'Tiếp tục',
                onPrimary: last
                    ? _finish
                    : () => _page.nextPage(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOut,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconArt extends StatefulWidget {
  const _IconArt(this.main, this.side);
  final IconData main;
  final IconData side;
  @override
  State<_IconArt> createState() => _IconArtState();
}

class _IconArtState extends State<_IconArt> with TickerProviderStateMixin {
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.loops(context)) {
      if (!_orbit.isAnimating) _orbit.repeat();
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _orbit.stop();
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _orbit.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return SizedBox(
      height: 260,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: Listenable.merge([_orbit, _pulse]),
        builder: (context, _) {
          final r = 100.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(260, 260),
                painter: PulseRings(_pulse.value, color: MomaColors.emerald),
              ),
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pal.tintSoft,
                ),
              ),
              // orbiting satellites
              for (var i = 0; i < 3; i++)
                Transform.translate(
                  offset: Offset(
                    math.cos((_orbit.value + i / 3) * 2 * math.pi) * r,
                    math.sin((_orbit.value + i / 3) * 2 * math.pi) * r * 0.55,
                  ),
                  child: Container(
                    width: i == 0 ? 52 : 40,
                    height: i == 0 ? 52 : 40,
                    decoration: BoxDecoration(
                      color: pal.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22073D33),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      i == 0
                          ? widget.side
                          : (i == 1
                                ? Icons.trending_up_rounded
                                : Icons.verified_user_outlined),
                      color: MomaColors.emerald,
                      size: i == 0 ? 28 : 22,
                    ),
                  ),
                ),
              Transform.scale(
                scale: 1 + 0.04 * math.sin(_pulse.value * 2 * math.pi),
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [MomaColors.emerald, MomaColors.forest],
                    ),
                  ),
                  child: Icon(widget.main, color: Colors.white, size: 64),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
