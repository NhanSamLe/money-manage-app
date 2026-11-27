import 'package:material_ui/material_ui.dart';

import '../../core/ui/header.dart';
import 'guide_content.dart';

/// "Hướng dẫn sử dụng": always reachable from Settings.
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MomaPage(
      title: 'Hướng dẫn sử dụng',
      showBack: true,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: const [GuideCards()],
      ),
    ),
  );
}
