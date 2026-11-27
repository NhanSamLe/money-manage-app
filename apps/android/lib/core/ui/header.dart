import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'money_pattern.dart';

import '../../app/theme/moma_theme.dart';
import '../../features/notifications/notifications.dart';
import '../../features/profile/avatar.dart';
import 'brand.dart';
import '../../app/theme/palette.dart';

import 'package:material_symbols_icons/symbols.dart';

/// Green gradient header with soft wave decoration, logo lockup, bell and avatar (design: every main screen).
/// The body is drawn on a rounded cloud sheet that overlaps the header, as in the mock-ups.
class MomaPage extends StatelessWidget {
  const MomaPage({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.titleIcon,
    this.action,
    this.onBell,
    this.showBack = false,
    this.hero = false,
  });
  final String title;
  final String? subtitle;
  final IconData? titleIcon;
  final Widget? action;
  final VoidCallback? onBell;
  final bool showBack;
  final Widget child;

  /// Only the Home tab uses the branded green hero header. Every other screen gets a normal app bar.
  final bool hero;

  Widget _plain(BuildContext context) {
    final pal = context.pal;
    return ColoredBox(
      color: pal.bg,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: pal.surface,
              border: Border(bottom: BorderSide(color: pal.lineSoft)),
            ),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    if (showBack)
                      IconButton(
                        tooltip: 'Quay lại',
                        onPressed: () => Navigator.maybePop(context),
                        icon: Icon(Symbols.arrow_back_rounded, color: pal.ink),
                      )
                    else
                      const SizedBox(width: 20),
                    if (titleIcon != null) ...[
                      Icon(titleIcon, color: MomaColors.emerald, size: 22),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    if (action != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: action,
                      )
                    else
                      const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: MoneyBackground(child: child)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!hero) return _plain(context);
    return ColoredBox(
      color: MomaColors.emerald,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [MomaColors.forest, MomaColors.emerald],
              ),
            ),
            child: CustomPaint(
              painter: _WavePainter(),
              child: MoneyPattern(
                opacity: 0.09,
                lotus: false,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (showBack)
                              IconButton(
                                tooltip: 'Quay lại',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => Navigator.maybePop(context),
                                icon: const Icon(
                                  Symbols.arrow_back_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            const MomaWordmark(size: 34),
                            const Spacer(),
                            _Bell(onTap: onBell),
                            const SizedBox(width: 10),
                            const _Avatar(),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      if (titleIcon != null) ...[
                                        Icon(
                                          titleIcon,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Flexible(
                                        child: Text(
                                          title,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (subtitle != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        subtitle!,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            ?action,
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: MoneyBackground(child: child),
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    for (final (i, a) in [0.07, 0.05].indexed) {
      final p = Path()..moveTo(0, s.height);
      for (var x = 0.0; x <= s.width; x += 4) {
        final y =
            s.height * (0.55 + 0.12 * i) +
            math.sin(x / s.width * math.pi * (1.4 + i) + i) * 18;
        p.lineTo(x, y);
      }
      p
        ..lineTo(s.width, s.height)
        ..close();
      canvas.drawPath(p, Paint()..color = Colors.white.withValues(alpha: a));
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => false;
}

class _Bell extends ConsumerWidget {
  const _Bell({this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNoticesProvider);
    return InkResponse(
      onTap: onTap ?? () => context.push('/notifications'),
      radius: 24,
      child: Semantics(
        label: unread > 0 ? 'Thông báo, $unread chưa xem' : 'Thông báo',
        button: true,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(
                Symbols.notifications_rounded,
                color: Colors.white,
                size: 26,
              ),
              if (unread > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF5A4F),
                      shape: BoxShape.circle,
                      border: Border.all(color: MomaColors.forest, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Owner photo (or a person silhouette) in the hero header; opens "Hồ sơ".
class _Avatar extends StatelessWidget {
  const _Avatar();

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: () => context.push('/profile'),
    radius: 24,
    child: Semantics(
      label: 'Hồ sơ',
      button: true,
      child: const OwnerAvatar(borderColor: Colors.white),
    ),
  );
}
