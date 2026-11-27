import 'package:material_ui/material_ui.dart';

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
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Công nợ'),
              Tab(text: 'Tiết kiệm'),
              Tab(text: 'Ngân sách'),
              Tab(text: 'Định kỳ'),
            ],
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
