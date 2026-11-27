import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/planning_models.dart';
import '../../core/providers.dart';
import '../../core/quick_parse.dart';
import '../../core/sheets.dart';

/// A goal plus the fields the shared [Goal] model does not carry yet (the API already returns `due_date`).
class GoalItem {
  const GoalItem({required this.goal, this.due});
  final Goal goal;
  final DateTime? due;

  bool get done =>
      goal.state == 'COMPLETED' ||
      (goal.target > 0 && goal.allocated >= goal.target);
}

/// `/goals` read once, keeping `due_date` next to the typed [GoalsData].
class GoalsBoard {
  GoalsBoard({required this.data, required this.items});

  factory GoalsBoard.fromJson(Map<String, dynamic> j) {
    final data = GoalsData.fromJson(j);
    final due = <String, DateTime?>{
      for (final raw in (j['goals'] as List<dynamic>).cast<Map>())
        raw['id'] as String: DateTime.tryParse('${raw['due_date'] ?? ''}'),
    };
    return GoalsBoard(
      data: data,
      items: [for (final g in data.goals) GoalItem(goal: g, due: due[g.id])],
    );
  }

  final GoalsData data;
  final List<GoalItem> items;

  int get target => items.fold(0, (s, i) => s + i.goal.target);
  int get saved => items.fold(0, (s, i) => s + i.goal.allocated);
  double get progress =>
      target <= 0 ? 0 : (saved / target).clamp(0.0, 1.0).toDouble();
}

final goalsBoardProvider = FutureProvider.autoDispose<GoalsBoard>((ref) async {
  final data = await ref.watch(apiProvider).get('/goals');
  return GoalsBoard.fromJson(data as Map<String, dynamic>);
});

/// Visual identity of a goal, picked from keywords in its name.
class GoalStyle {
  const GoalStyle(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const _styles = <(List<String>, GoalStyle)>[
  (
    ['du lich', 'travel', 'chuyen bay', 'phuot', 'nghi duong'],
    GoalStyle(Symbols.flight_rounded, Color(0xFF3B82F6)),
  ),
  (
    ['laptop', 'macbook', 'may tinh', 'pc', 'computer'],
    GoalStyle(Symbols.laptop_rounded, Color(0xFF6366F1)),
  ),
  (
    ['dien thoai', 'iphone', 'smartphone', 'phone'],
    GoalStyle(Symbols.smartphone_rounded, Color(0xFF14B8A6)),
  ),
  (
    ['xe', 'o to', 'oto', 'xe may', 'car'],
    GoalStyle(Symbols.directions_car_rounded, Color(0xFFF59E0B)),
  ),
  (
    ['khan cap', 'du phong', 'emergency', 'y te', 'benh'],
    GoalStyle(Symbols.health_and_safety_rounded, Color(0xFFEF4444)),
  ),
  (
    ['cuoi', 'dam cuoi', 'wedding'],
    GoalStyle(Symbols.favorite_rounded, Color(0xFFEC4899)),
  ),
  (
    ['hoc', 'hoc phi', 'du hoc', 'school', 'khoa hoc'],
    GoalStyle(Symbols.school_rounded, Color(0xFF8B5CF6)),
  ),
  (
    ['nha', 'can ho', 'chung cu', 'home', 'house'],
    GoalStyle(Symbols.home_rounded, Color(0xFF21896E)),
  ),
];

const _fallbackStyle = GoalStyle(Symbols.savings_rounded, Color(0xFF21896E));

GoalStyle goalStyleFor(String name) {
  final folded = foldVietnamese(name);
  for (final (words, style) in _styles) {
    for (final w in words) {
      if (RegExp('(^|[^a-z0-9])${RegExp.escape(w)}(\$|[^a-z0-9])')
          .hasMatch(folded)) {
        return style;
      }
    }
  }
  return _fallbackStyle;
}

/// Encouragement shown on each card.
enum GoalMood {
  done('Đã hoàn thành', Symbols.verified_rounded, Color(0xFF1B8A5A)),
  behind('Cần tăng tốc', Symbols.speed_rounded, Color(0xFFD64545)),
  near('Sắp đạt mục tiêu', Symbols.flag_rounded, Color(0xFF21896E)),
  good('Đang tiến tốt', Symbols.trending_up_rounded, Color(0xFF3B82F6)),
  persist('Kiên trì để chạm đích', Symbols.hiking_rounded, Color(0xFFD08700));

  const GoalMood(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whole calendar months from [now] until [due] (0 when less than a month remains).
int monthsLeft(DateTime due, DateTime now) {
  var m = (due.year - now.year) * 12 + due.month - now.month;
  if (due.day < now.day) m--;
  return m < 0 ? 0 : m;
}

/// The API has no start date for goals, so "on schedule" assumes a 12-month runway ending at the due date:
/// the goal is behind when its progress trails that straight line by more than 10 points, or the date has passed.
GoalMood goalMood(GoalItem item, DateTime now) {
  if (item.done) return GoalMood.done;
  final p = item.goal.progress;
  final due = item.due;
  if (due != null) {
    final daysLeft = _day(due).difference(_day(now)).inDays;
    if (daysLeft < 0) return GoalMood.behind;
    final expected = (1 - daysLeft / 365).clamp(0.0, 1.0);
    if (p < expected - 0.1) return GoalMood.behind;
  }
  if (p >= 0.75) return GoalMood.near;
  if (p >= 0.3) return GoalMood.good;
  return GoalMood.persist;
}

/// Footer line: time left until the due date.
String goalDeadlineLabel(GoalItem item, DateTime now) {
  final due = item.due;
  if (item.done) {
    return due == null ? 'Đã đạt mục tiêu' : 'Đã đạt (hạn ${dateLabel(due)})';
  }
  if (due == null) return 'Chưa đặt hạn';
  final days = _day(due).difference(_day(now)).inDays;
  if (days < 0) return 'Quá hạn (${dateLabel(due)})';
  final months = monthsLeft(due, now);
  if (months == 0) {
    return days == 0 ? 'Hết hạn hôm nay' : 'Còn $days ngày (${dateLabel(due)})';
  }
  return 'Còn $months tháng (${dateLabel(due)})';
}
