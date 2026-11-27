import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lock/lock_controller.dart';

/// Owner preferences for talking to the assistant, kept on the device (Keystore-backed storage, like LocalStore).
class VoicePrefs {
  const VoicePrefs({this.autoSend = true, this.autoRead = false});

  /// "Tự gửi sau khi nói": send the recognized sentence as soon as the owner stops talking.
  final bool autoSend;

  /// "Tự đọc câu trả lời": read every reply aloud.
  final bool autoRead;

  VoicePrefs copyWith({bool? autoSend, bool? autoRead}) => VoicePrefs(
    autoSend: autoSend ?? this.autoSend,
    autoRead: autoRead ?? this.autoRead,
  );
}

final voiceStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

const _kAutoSend = 'voice_auto_send';
const _kAutoRead = 'voice_auto_read';
const _kMicDenials = 'voice_mic_denials';
const _kLocaleWarned = 'voice_locale_warned';

class VoicePrefsNotifier extends Notifier<VoicePrefs> {
  bool _changed = false;

  @override
  VoicePrefs build() {
    _load();
    return const VoicePrefs();
  }

  FlutterSecureStorage get _s => ref.read(voiceStorageProvider);

  Future<void> _load() async {
    try {
      final send = await _s.read(key: _kAutoSend);
      final read = await _s.read(key: _kAutoRead);
      if (_changed) return; // the owner toggled before storage answered
      state = VoicePrefs(autoSend: send != '0', autoRead: read == '1');
    } catch (_) {}
  }

  Future<void> setAutoSend(bool v) async {
    _changed = true;
    state = state.copyWith(autoSend: v);
    await _write(_kAutoSend, v ? '1' : '0');
  }

  Future<void> setAutoRead(bool v) async {
    _changed = true;
    state = state.copyWith(autoRead: v);
    await _write(_kAutoRead, v ? '1' : '0');
  }

  Future<void> _write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {}
  }

  /// How many times in a row the microphone permission was refused (reset once granted).
  Future<int> micDenials() async {
    try {
      return int.tryParse(await _s.read(key: _kMicDenials) ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> setMicDenials(int n) => _write(_kMicDenials, '$n');

  /// Whether the owner was already told that Vietnamese recognition is missing on this phone.
  Future<bool> localeWarned() async {
    try {
      return await _s.read(key: _kLocaleWarned) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setLocaleWarned() => _write(_kLocaleWarned, '1');
}

final voicePrefsProvider = NotifierProvider<VoicePrefsNotifier, VoicePrefs>(
  VoicePrefsNotifier.new,
);

/// Set when the assistant is opened with `/ai?voice=1` (home-screen widget mic): the page starts listening once.
class VoiceLaunch extends Notifier<bool> {
  @override
  bool build() => false;
  void request() => state = true;

  /// Returns true (and clears the flag) when a launch request is pending. Never while the app lock is still
  /// loading or shown: the microphone must not open behind the PIN screen. The request then stays pending and
  /// AssistantPage consumes it once the app is unlocked.
  bool consume() {
    if (!state) return false;
    final lock = ref.read(lockControllerProvider);
    if (!lock.loaded || lock.locked) return false;
    state = false;
    return true;
  }
}

final voiceLaunchProvider = NotifierProvider<VoiceLaunch, bool>(
  VoiceLaunch.new,
);
