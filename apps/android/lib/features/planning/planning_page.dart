import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import 'budgets_view.dart';
import 'debts_view.dart';
import 'goals_view.dart';
import 'recurring_view.dart';

/// "Kế hoạch": debts, savings goals, monthly budgets and recurring items.
class PlanningPage extends StatelessWidget {
  const PlanningPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Kế hoạch',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MomaColors.forest,
                ),
              ),
            ),
          ),
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
