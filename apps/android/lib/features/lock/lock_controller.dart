import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lock_services.dart';
import 'pin_hasher.dart';

/// How long the app may stay in the background before it asks for the PIN again.
enum LockDelay {
  m15(15, 'Sau 15 phút'),
  m30(30, 'Sau 30 phút'),
  h1(60, 'Sau 1 giờ'),
  h2(120, 'Sau 2 giờ');

  const LockDelay(this.minutes, this.label);
  final int minutes;
  final String label;
  Duration get duration => Duration(minutes: minutes);

  static LockDelay fromMinutes(int? m) =>
      values.firstWhere((d) => d.minutes == m, orElse: () => LockDelay.m30);
}

class LockConfig {
  const LockConfig({
    this.pinHash,
    this.biometric = false,
    this.delay = LockDelay.m30,
    this.hideRecents = false,
  });
  final String? pinHash;
  final bool biometric;
  final LockDelay delay;
  final bool hideRecents;

  bool get enabled => pinHash != null;

  LockConfig copyWith({
    String? pinHash,
    bool clearPin = false,
    bool? biometric,
    LockDelay? delay,
    bool? hideRecents,
  }) => LockConfig(
    pinHash: clearPin ? null : (pinHash ?? this.pinHash),
    biometric: biometric ?? this.biometric,
    delay: delay ?? this.delay,
    hideRecents: hideRecents ?? this.hideRecents,
  );

  String encode() => jsonEncode({
    'pin': pinHash,
    'bio': biometric,
    'delay': delay.minutes,
    'hide': hideRecents,
  });

  static LockConfig decode(String? s) {
    if (s == null || s.isEmpty) return const LockConfig();
    final m = jsonDecode(s) as Map<String, dynamic>;
    return LockConfig(
      pinHash: m['pin'] as String?,
      biometric: m['bio'] == true,
      delay: LockDelay.fromMinutes(m['delay'] as int?),
      hideRecents: m['hide'] == true,
    );
  }
}

class LockState {
  const LockState({
    this.loaded = false,
    this.config = const LockConfig(),
    this.locked = false,
    this.failures = 0,
    this.coolUntil,
  });
  final bool loaded;
  final LockConfig config;
  final bool locked;

  /// Consecutive wrong PINs (reset by a correct PIN or biometric).
  final int failures;

  /// While set and in the future, PIN entry is disabled.
  final DateTime? coolUntil;

  bool get enabled => config.enabled;

  LockState copyWith({
    bool? loaded,
    LockConfig? config,
    bool? locked,
    int? failures,
    DateTime? coolUntil,
    bool clearCool = false,
  }) => LockState(
    loaded: loaded ?? this.loaded,
    config: config ?? this.config,
    locked: locked ?? this.locked,
    failures: failures ?? this.failures,
    coolUntil: clearCool ? null : (coolUntil ?? this.coolUntil),
  );
}

/// Result of a PIN check.
class PinCheck {
  const PinCheck._(this.ok, this.remaining, this.waitUntil);
  const PinCheck.ok() : this._(true, 0, null);
  const PinCheck.wrong(int remaining) : this._(false, remaining, null);
  const PinCheck.cooling(DateTime until) : this._(false, 0, until);
  final bool ok;
  final int remaining;
  final DateTime? waitUntil;
}

const kLockConfigKey = 'app_lock';
const kLockAttemptsKey = 'app_lock_attempts';
const kLockLastActiveKey = 'app_lock_last_active';

final lockControllerProvider = NotifierProvider<LockController, LockState>(
  LockController.new,
);

/// App lock state machine: cold start locks, coming back after the chosen delay locks, PIN / biometric unlocks.
class LockController extends Notifier<LockState> {
  late LockStorage _store;
  late PinHasher _hasher;
  late DateTime Function() _now;
  late Future<void> _ready;
  DateTime? _backgroundSince;
  bool _bioInProgress = false;

  /// Completes once the stored settings are loaded.
  Future<void> get ready => _ready;

  @override
  LockState build() {
    _store = ref.read(lockStorageProvider);
    _hasher = ref.read(pinHasherProvider);
    _now = ref.read(lockClockProvider);
    _ready = _load();
    return const LockState();
  }

  Future<void> _load() async {
    var cfg = const LockConfig();
    var failures = 0;
    DateTime? until;
    try {
      cfg = LockConfig.decode(await _store.read(kLockConfigKey));
      final a = await _store.read(kLockAttemptsKey);
      if (a != null) {
        final m = jsonDecode(a) as Map<String, dynamic>;
        failures = (m['n'] as int?) ?? 0;
        final u = m['until'] as int?;
        if (u != null) until = DateTime.fromMillisecondsSinceEpoch(u);
      }
    } on Object {
      // Unreadable settings: run unlocked rather than locking the owner out.
      cfg = const LockConfig();
    }
    // Process start = cold start: lock when enabled and signed in.
    final locked = cfg.enabled && ref.read(lockSignedInProvider)();
    state = LockState(
      loaded: true,
      config: cfg,
      locked: locked,
      failures: failures,
      coolUntil: until,
    );
    unawaited(ref.read(secureWindowProvider).set(cfg.hideRecents));
  }

  // ---- lifecycle -------------------------------------------------------------------------------

  void onLifecycle(AppLifecycleState s) {
    if (_bioInProgress) return;
    switch (s) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_backgroundSince == null) {
          _backgroundSince = _now();
          if (state.enabled && !state.locked) unawaited(_markActive());
        }
      case AppLifecycleState.resumed:
        final since = _backgroundSince;
        _backgroundSince = null;
        if (since == null || !state.enabled || state.locked) return;
        if (!ref.read(lockSignedInProvider)()) return;
        if (_now().difference(since) >= state.config.delay.duration) {
          state = state.copyWith(locked: true);
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// A fresh password sign-in proves identity; signing out leaves nothing to guard.
  void onAuthChanged() {
    _backgroundSince = null;
    if (state.locked) state = state.copyWith(locked: false);
  }

  Future<void> _markActive() => _store
      .write(kLockLastActiveKey, '${_now().millisecondsSinceEpoch}')
      .catchError((Object _) {});

  /// The app was used (unlocked) within the chosen delay — used by the widget quick-entry sheet.
  Future<bool> recentlyActive() async {
    await _ready;
    if (!state.enabled) return true;
    try {
      final v = int.tryParse(await _store.read(kLockLastActiveKey) ?? '');
      if (v == null) return false;
      final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(v));
      return !age.isNegative && age < state.config.delay.duration;
    } on Object {
      return false;
    }
  }

  // ---- unlocking -------------------------------------------------------------------------------

  /// Checks the PIN against the stored hash with throttling. Does not change [LockState.locked].
  Future<PinCheck> checkPin(String pin) async {
    await _ready;
    final hash = state.config.pinHash;
    if (hash == null) return const PinCheck.ok();
    final until = state.coolUntil;
    if (until != null) {
      if (until.isAfter(_now())) return PinCheck.cooling(until);
      // The wait is over: a new round of tries.
      state = state.copyWith(failures: 0, clearCool: true);
    }
    if (await _hasher.verify(pin, hash)) {
      await _resetAttempts();
      return const PinCheck.ok();
    }
    final n = state.failures + 1;
    final wait = AttemptPolicy.cooldownAfter(n);
    final next = wait == null ? null : _now().add(wait);
    state = state.copyWith(failures: n, coolUntil: next);
    await _saveAttempts();
    return next != null
        ? PinCheck.cooling(next)
        : PinCheck.wrong(AttemptPolicy.remaining(n));
  }

  Future<PinCheck> unlockWithPin(String pin) async {
    final r = await checkPin(pin);
    if (r.ok) _unlock();
    return r;
  }

  /// System fingerprint / face prompt. True when unlocked.
  Future<bool> unlockWithBiometric() async {
    await _ready;
    if (!state.config.biometric || _bioInProgress) return false;
    _bioInProgress = true;
    bool ok;
    try {
      ok = await ref
          .read(biometricProvider)
          .authenticate('Xác thực để mở MoMa');
    } finally {
      _bioInProgress = false;
    }
    if (ok) {
      await _resetAttempts();
      _unlock();
    }
    return ok;
  }

  void _unlock() {
    _backgroundSince = null;
    state = state.copyWith(locked: false);
    unawaited(_markActive());
  }

  Future<void> _resetAttempts() async {
    state = state.copyWith(failures: 0, clearCool: true);
    try {
      await _store.delete(kLockAttemptsKey);
    } on Object {
      // best effort
    }
  }

  Future<void> _saveAttempts() async {
    try {
      await _store.write(
        kLockAttemptsKey,
        jsonEncode({
          'n': state.failures,
          'until': state.coolUntil?.millisecondsSinceEpoch,
        }),
      );
    } on Object {
      // best effort
    }
  }

  // ---- settings --------------------------------------------------------------------------------

  Future<void> _saveConfig(LockConfig c) async {
    await _store.write(kLockConfigKey, c.encode());
    state = state.copyWith(config: c);
  }

  /// Turns the lock on with a new PIN (already confirmed by the caller).
  Future<void> enable(String pin) async {
    await _ready;
    final h = await _hasher.hash(pin);
    await _saveConfig(state.config.copyWith(pinHash: h));
    await _resetAttempts();
    _unlock();
  }

  /// Replaces the PIN (caller verified the old one with [checkPin]).
  Future<void> changePin(String pin) async {
    await _ready;
    final h = await _hasher.hash(pin);
    await _saveConfig(state.config.copyWith(pinHash: h));
  }

  /// Turns the lock off (caller verified the PIN). Keeps the "hide in recents" choice.
  Future<void> disable() async {
    await _ready;
    await _saveConfig(state.config.copyWith(clearPin: true, biometric: false));
    await _resetAttempts();
    _unlock();
  }

  Future<void> setBiometric(bool on) async =>
      _saveConfig(state.config.copyWith(biometric: on));

  Future<void> setDelay(LockDelay d) async =>
      _saveConfig(state.config.copyWith(delay: d));

  Future<void> setHideRecents(bool on) async {
    await _saveConfig(state.config.copyWith(hideRecents: on));
    await ref.read(secureWindowProvider).set(on);
  }

  /// "Quên mã PIN?": clears the lock and signs out; the owner signs in again with the password.
  Future<void> forgotPin() async {
    await _ready;
    try {
      await _store.write(
        kLockConfigKey,
        LockConfig(hideRecents: state.config.hideRecents).encode(),
      );
      await _store.delete(kLockAttemptsKey);
      await _store.delete(kLockLastActiveKey);
    } on Object {
      // best effort
    }
    state = state.copyWith(
      config: LockConfig(hideRecents: state.config.hideRecents),
      locked: false,
      failures: 0,
      clearCool: true,
    );
    await ref.read(lockSignOutProvider)();
  }
}
