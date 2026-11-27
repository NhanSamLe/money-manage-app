import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import 'budgets_view.dart';
import 'debts_view.dart';
import 'goals_view.dart';
import 'recurring_view.dart';

/// "Kế hoạch": debts, savings goals, monthly budgets and recurring items.
class PlanningPage extends StatelessWidget {
  const PlanningPage({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      initialIndex: initialTab,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.transparent,
              labelColor: MomaColors.forest,
              unselectedLabelColor: MomaColors.muted,
              labelStyle: const TextStyle(fontWeight: FontWeight.w800),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: const Color(0xFFD7F0E1),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: MomaColors.mint),
              ),
              splashBorderRadius: BorderRadius.circular(22),
              labelPadding: const EdgeInsets.symmetric(horizontal: 18),
              tabs: const [
                Tab(height: 44, text: 'Công nợ'),
                Tab(height: 44, text: 'Tiết kiệm'),
                Tab(height: 44, text: 'Ngân sách'),
                Tab(height: 44, text: 'Định kỳ'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                DebtsView(),
                GoalsView(),
                BudgetsView(),
                RecurringView(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
