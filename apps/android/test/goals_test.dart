import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/app/theme/moma_theme.dart';
import 'package:moma/core/planning_models.dart';
import 'package:moma/features/goals/goal_insights.dart';
import 'package:moma/features/goals/goal_widgets.dart';

GoalItem item(
  String name,
  int target,
  int allocated, {
  String state = 'ACTIVE',
  DateTime? due,
}) => GoalItem(
  goal: Goal(
    id: name,
    name: name,
    target: target,
    allocated: allocated,
    state: state,
    version: 1,
  ),
  due: due,
);

void main() {
  final now = DateTime(2026, 11, 28);

  group('goal style', () {
    test('picks an icon from name keywords, with or without diacritics', () {
      expect(goalStyleFor('Du lịch Đà Lạt').icon, Symbols.flight_rounded);
      expect(goalStyleFor('Mua MacBook').icon, Symbols.laptop_rounded);
      expect(goalStyleFor('Máy tính mới').icon, Symbols.laptop_rounded);
      expect(goalStyleFor('Mua xe máy').icon, Symbols.directions_car_rounded);
      expect(goalStyleFor('Ô tô').icon, Symbols.directions_car_rounded);
      expect(goalStyleFor('Mua nhà').icon, Symbols.home_rounded);
      expect(
        goalStyleFor('Quỹ khẩn cấp').icon,
        Symbols.health_and_safety_rounded,
      );
      expect(goalStyleFor('Đám cưới').icon, Symbols.favorite_rounded);
      expect(goalStyleFor('Học phí').icon, Symbols.school_rounded);
      expect(goalStyleFor('Điện thoại').icon, Symbols.smartphone_rounded);
      expect(goalStyleFor('Xem phim').icon, Symbols.savings_rounded);
      expect(goalStyleFor('Quỹ riêng').icon, Symbols.savings_rounded);
    });
  });

  group('goal mood and deadline', () {
    test('completed goals', () {
      final g = item('A', 100, 100);
      expect(g.done, isTrue);
      expect(goalMood(g, now), GoalMood.done);
      expect(
        goalMood(item('B', 100, 20, state: 'COMPLETED'), now),
        GoalMood.done,
      );
    });

    test('progress bands without a due date', () {
      expect(goalMood(item('A', 100, 80), now), GoalMood.near);
      expect(goalMood(item('A', 100, 40), now), GoalMood.good);
      expect(goalMood(item('A', 100, 10), now), GoalMood.persist);
      expect(goalDeadlineLabel(item('A', 100, 10), now), 'Chưa đặt hạn');
    });

    test('behind the straight-line schedule or past due needs speeding up', () {
      // 2 months left of an assumed 12-month runway: ~83% expected.
      final soon = item('A', 100, 30, due: DateTime(2027, 1, 28));
      expect(goalMood(soon, now), GoalMood.behind);
      expect(goalDeadlineLabel(soon, now), 'Còn 2 tháng (28/01/2027)');
      final late = item('A', 100, 90, due: DateTime(2026, 11, 1));
      expect(goalMood(late, now), GoalMood.behind);
      expect(goalDeadlineLabel(late, now), 'Quá hạn (01/11/2026)');
      // Far away: on track.
      final far = item('A', 100, 30, due: DateTime(2027, 11, 28));
      expect(goalMood(far, now), GoalMood.good);
      expect(goalDeadlineLabel(far, now), 'Còn 12 tháng (28/11/2027)');
      expect(
        goalDeadlineLabel(item('A', 100, 0, due: DateTime(2026, 12, 8)), now),
        'Còn 10 ngày (08/12/2026)',
      );
    });

    test('board parses due dates and totals', () {
      final b = GoalsBoard.fromJson({
        'goals': [
          {
            'id': 'g1',
            'name': 'A',
            'target': '1000',
            'allocated': '250',
            'state': 'ACTIVE',
            'due_date': '2027-03-01',
            'version': 1,
          },
          {
            'id': 'g2',
            'name': 'B',
            'target': '1000',
            'allocated': '1000',
            'state': 'ACTIVE',
            'due_date': null,
            'version': 1,
          },
        ],
        'accounts': [],
      });
      expect(b.items.first.due, DateTime(2027, 3, 1));
      expect(b.items.last.due, isNull);
      expect(b.target, 2000);
      expect(b.saved, 1250);
      expect(b.progress, 0.625);
    });
  });

  group('goal card', () {
    Future<void> pumpAt360(
      WidgetTester tester,
      Widget child, {
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMomaTheme(brightness),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [child],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('in progress with a due date and a tap action', (tester) async {
      var taps = 0;
      await pumpAt360(
        tester,
        GoalCard(
          item: item(
            'Mua laptop MacBook Pro cho công việc thiết kế đồ họa',
            1250000000,
            937500000,
            due: DateTime(2027, 11, 28),
          ),
          now: now,
          onTap: () => taps++,
        ),
      );
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('Còn 12 tháng (28/11/2027)'), findsOneWidget);
      expect(find.text('Sắp đạt mục tiêu'), findsOneWidget);
      expect(find.byIcon(Symbols.laptop_rounded), findsWidgets);
      await tester.tap(find.byType(GoalCard));
      expect(taps, 1);
    });

    testWidgets('completed and behind states, dark mode, no overflow', (
      tester,
    ) async {
      await pumpAt360(
        tester,
        Column(
          children: [
            GoalCard(item: item('Quỹ khẩn cấp', 5000000, 5000000), now: now),
            GoalCard(
              item: item(
                'Du lịch Nhật Bản',
                80000000,
                8000000,
                due: DateTime(2027, 1, 15),
              ),
              now: now,
            ),
          ],
        ),
        brightness: Brightness.dark,
      );
      expect(find.text('Đã hoàn thành'), findsOneWidget);
      expect(find.text('Đã đạt mục tiêu'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Cần tăng tốc'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('summary card shows totals', (tester) async {
      final board = GoalsBoard(
        data: GoalsData(goals: [], accounts: []),
        items: [item('A', 4000000, 1000000), item('B', 6000000, 6000000)],
      );
      await pumpAt360(tester, GoalsSummaryCard(board: board));
      expect(find.text('2 mục tiêu'), findsOneWidget);
      expect(find.text('10.000.000 ₫'), findsOneWidget);
      expect(find.text('70%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
