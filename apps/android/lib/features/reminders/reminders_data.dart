import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/providers.dart';
import '../../core/push.dart';

/// Meal kinds used by reminders, push actions (`skip_<meal>`) and POST /v1/reminders/skip.
const mealKinds = ['breakfast', 'lunch', 'dinner'];

const mealLabels = {
  'breakfast': 'Bữa sáng',
  'lunch': 'Bữa trưa',
  'dinner': 'Bữa tối',
};

TimeOfDay parseHm(Object? v, TimeOfDay fallback) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
  if (m == null) return fallback;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return fallback;
  return TimeOfDay(hour: h, minute: mi);
}

String formatHm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One reminder slot: on/off plus a time of day.
class TimedReminder {
  TimedReminder({required this.enabled, required this.time});
  bool enabled;
  TimeOfDay time;

  factory TimedReminder.fromJson(Object? j, TimeOfDay fallback) {
    final m = j is Map ? j : const {};
    return TimedReminder(
      enabled: m['enabled'] == true,
      time: parseHm(m['time'], fallback),
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'time': formatHm(time)};
}

/// Mirror of GET/PUT /v1/reminders/settings. Mutable so the settings form edits it in place.
class ReminderSettings {
  ReminderSettings({
    required this.meals,
    required this.cashCheck,
    required this.dailyReview,
    required this.weeklyReview,
    required this.weeklyWeekday,
    required this.monthlyReview,
    required this.budgetAlerts,
  });
  final Map<String, TimedReminder> meals;
  final TimedReminder cashCheck;
  final TimedReminder dailyReview;
  final TimedReminder weeklyReview;

  /// 1 = Monday ... 7 = Sunday.
  int weeklyWeekday;
  final TimedReminder monthlyReview;
  bool budgetAlerts;

  static const _defaults = {
    'breakfast': TimeOfDay(hour: 7, minute: 30),
    'lunch': TimeOfDay(hour: 12, minute: 0),
    'dinner': TimeOfDay(hour: 19, minute: 0),
  };

  factory ReminderSettings.fromJson(Map<String, dynamic> j) {
    final meals = j['meals'] is Map ? j['meals'] as Map : const {};
    final weekly = j['weekly_review'] is Map ? j['weekly_review'] as Map : const {};
    final wd = weekly['weekday'];
    final weekday = wd is int ? wd : int.tryParse('${wd ?? ''}') ?? 7;
    return ReminderSettings(
      meals: {
        for (final k in mealKinds)
          k: TimedReminder.fromJson(meals[k], _defaults[k]!),
      },
      cashCheck: TimedReminder.fromJson(
        j['cash_check'],
        const TimeOfDay(hour: 21, minute: 0),
      ),
      dailyReview: TimedReminder.fromJson(
        j['daily_review'],
        const TimeOfDay(hour: 21, minute: 30),
      ),
      weeklyReview: TimedReminder.fromJson(
        weekly,
        const TimeOfDay(hour: 20, minute: 0),
      ),
      weeklyWeekday: weekday.clamp(1, 7),
      monthlyReview: TimedReminder.fromJson(
        j['monthly_review'],
        const TimeOfDay(hour: 20, minute: 0),
      ),
      budgetAlerts: (j['budget_alerts'] is Map)
          ? (j['budget_alerts'] as Map)['enabled'] == true
          : false,
    );
  }

  Map<String, dynamic> toJson() => {
    'meals': {for (final k in mealKinds) k: meals[k]!.toJson()},
    'cash_check': cashCheck.toJson(),
    'daily_review': dailyReview.toJson(),
    'weekly_review': {...weeklyReview.toJson(), 'weekday': weeklyWeekday},
    'monthly_review': monthlyReview.toJson(),
    'budget_alerts': {'enabled': budgetAlerts},
  };
}

final reminderSettingsProvider = FutureProvider.autoDispose<ReminderSettings>((
  ref,
) async {
  final data = await ref.watch(apiProvider).get('/reminders/settings');
  return ReminderSettings.fromJson(
    data is Map<String, dynamic> ? data : const {},
  );
});

/// State of today's meals from GET /v1/reminders/today.
class TodayReminders {
  TodayReminders({required this.date, required this.skipped, required this.done});
  final String date;
  final Set<String> skipped;
  final Map<String, bool> done;

  factory TodayReminders.fromJson(Map<String, dynamic> j) {
    final done = j['done'] is Map ? j['done'] as Map : const {};
    return TodayReminders(
      date: '${j['date'] ?? ''}',
      skipped: {
        for (final s in (j['skipped'] as List? ?? const [])) '$s',
      },
      done: {for (final k in mealKinds) k: done[k] == true},
    );
  }
}

class TodayRemindersNotifier extends AsyncNotifier<TodayReminders> {
  @override
  Future<TodayReminders> build() async {
    // A "skip" tapped on a push notification changes today's state outside this provider.
    void reload() => ref.invalidateSelf();
    Push.remindersChanged.addListener(reload);
    ref.onDispose(() => Push.remindersChanged.removeListener(reload));
    final data = await ref.watch(apiProvider).get('/reminders/today');
    return TodayReminders.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }

  /// Marks (or unmarks) [kind] as "Hôm nay không ăn"; the server answers with today's payload.
  Future<void> skip(String kind, bool skip) async {
    final data = await ref.read(apiProvider).post('/reminders/skip', {
      'kind': kind,
      'skip': skip,
    });
    state = AsyncData(
      TodayReminders.fromJson(data is Map<String, dynamic> ? data : const {}),
    );
  }
}

final todayRemindersProvider =
    AsyncNotifierProvider.autoDispose<TodayRemindersNotifier, TodayReminders>(
      TodayRemindersNotifier.new,
    );
