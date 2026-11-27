import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';

/// Vector hero for the welcome screen: phone with growth chart, floating feature tiles and coins
/// (stylised version of the design's illustration, drawn in code so it stays crisp on every density).
class WelcomeHero extends StatelessWidget {
  const WelcomeHero({super.key, this.height = 250});
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return Stack(
            alignment: Alignment.center,
            children: [
              // platform
              Positioned(
                bottom: 8,
                child: Container(
                  width: w * 0.62,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(40),
                  ),
                ),
              ),
              // leaves
              Positioned(
                left: w * 0.24,
                bottom: 22,
                child: _leaf(const Color(0xFF2F9E6E), -0.5),
              ),
              Positioned(
                right: w * 0.24,
                bottom: 22,
                child: _leaf(const Color(0xFF1F8A5F), 0.5),
              ),
              // phone
              Transform.rotate(
                angle: -0.12,
                child: Container(
                  width: w * 0.36,
                  height: height * 0.8,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: MomaColors.forest,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33073D33),
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1FAF5),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFD8F1E3),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: CustomPaint(
                              painter: _ChartPainter(),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          flex: 4,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 34,
                                height: 34,
                                child: CircularProgressIndicator(
                                  value: 0.7,
                                  strokeWidth: 6,
                                  color: MomaColors.emerald,
                                  backgroundColor: MomaColors.mint.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final f in [1.0, 0.8, 0.6])
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 2.5,
                                        ),
                                        child: FractionallySizedBox(
                                          widthFactor: f,
                                          child: Container(
                                            height: 5,
                                            decoration: BoxDecoration(
                                              color: MomaColors.mint,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // coins
              Positioned(right: w * 0.2, bottom: 20, child: _coins()),
              // floating tiles
              Positioned(
                left: w * 0.08,
                top: height * 0.12,
                child: _tile(Icons.savings_rounded, const Color(0xFF1F7A5C)),
              ),
              Positioned(
                right: w * 0.08,
                top: height * 0.06,
                child: _tile(Icons.bar_chart_rounded, const Color(0xFF2FBF8F)),
              ),
              Positioned(
                left: w * 0.04,
                bottom: height * 0.22,
                child: _tile(Icons.restaurant_rounded, const Color(0xFF1F7A5C)),
              ),
              Positioned(
                right: w * 0.04,
                bottom: height * 0.3,
                child: _tile(
                  Icons.account_balance_wallet_rounded,
                  const Color(0xFF1F7A5C),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(IconData icon, Color color) => Container(
    width: 54,
    height: 54,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [
        BoxShadow(
          color: Color(0x22073D33),
          blurRadius: 10,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Icon(icon, color: color, size: 30),
  );

  Widget _leaf(Color color, double angle) => Transform.rotate(
    angle: angle,
    child: Container(
      width: 46,
      height: 96,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(46),
          topRight: Radius.circular(8),
          bottomLeft: Radius.circular(8),
          bottomRight: Radius.circular(46),
        ),
      ),
    ),
  );

  Widget _coins() => SizedBox(
    width: 64,
    height: 56,
    child: Stack(
      children: [
        for (var i = 0; i < 4; i++)
          Positioned(
            left: 4.0 + (i % 2) * 6,
            bottom: i * 9.0,
            child: Container(
              width: 44,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFFF5C542),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE0A800), width: 1.5),
              ),
            ),
          ),
      ],
    ),
  );
}

class _ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(s.width * 0.08, s.height * 0.78)
      ..lineTo(s.width * 0.28, s.height * 0.5)
      ..lineTo(s.width * 0.45, s.height * 0.62)
      ..lineTo(s.width * 0.68, s.height * 0.32)
      ..lineTo(s.width * 0.9, s.height * 0.18);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = MomaColors.emerald,
    );
  }

  @override
  bool shouldRepaint(_ChartPainter old) => false;
}
