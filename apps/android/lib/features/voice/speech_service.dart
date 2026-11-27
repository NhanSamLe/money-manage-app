import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech recognition behind an interface, so the assistant can be tested with a fake recognizer.
///
/// On Android the device's own recognition service (usually Google) does the work; MoMa never records or keeps
/// audio. Error codes are the plugin's (`error_no_match`, `error_network`, `error_language_not_supported`, ...).
abstract class SpeechService {
  /// Whether RECORD_AUDIO is already granted (never prompts).
  Future<bool> hasPermission();

  /// Prepares the recognizer, asking for the microphone permission when it is not granted yet.
  /// False: permission denied or no recognition service on the device.
  Future<bool> initialize({
    required void Function(String code, bool permanent) onError,
    required void Function(String status) onStatus,
  });

  /// Locale ids the recognizer reports (`vi_VN`, `en_US`, ...). May be empty on some devices.
  Future<List<String>> localeIds();

  /// The device's default recognition locale id.
  Future<String?> systemLocaleId();

  Future<void> listen({
    String? localeId,
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
  });

  /// Ends listening; the recognizer still delivers a final result.
  Future<void> stop();

  /// Ends listening and drops any result.
  Future<void> cancel();
}

/// Android SpeechRecognizer through the `speech_to_text` plugin.
class DeviceSpeechService implements SpeechService {
  final SpeechToText _stt = SpeechToText();
  void Function(String code, bool permanent)? _onError;
  void Function(String status)? _onStatus;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _stt.hasPermission;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> initialize({
    required void Function(String code, bool permanent) onError,
    required void Function(String status) onStatus,
  }) async {
    // The plugin keeps the listeners of its first successful initialize: forward through fields so a rebuilt
    // page receives the callbacks.
    _onError = onError;
    _onStatus = onStatus;
    try {
      return await _stt.initialize(
        onError: (SpeechRecognitionError e) =>
            _onError?.call(e.errorMsg, e.permanent),
        onStatus: (s) => _onStatus?.call(s),
        // No Bluetooth headset routing: avoids an extra "Nearby devices" permission prompt.
        options: [SpeechToText.androidNoBluetooth],
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> localeIds() async {
    try {
      return [for (final l in await _stt.locales()) l.localeId];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> systemLocaleId() async {
    try {
      return (await _stt.systemLocale())?.localeId;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> listen({
    String? localeId,
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
  }) => _stt.listen(
    onResult: (SpeechRecognitionResult r) =>
        onResult(r.recognizedWords, r.finalResult),
    onSoundLevelChange: onLevel,
    listenOptions: SpeechListenOptions(
      localeId: localeId,
      partialResults: true,
      cancelOnError: true,
      listenMode: ListenMode.dictation,
      // Long enough for the first word; once words arrive MoMa ends after 1.5 s of silence itself.
      pauseFor: const Duration(seconds: 6),
      listenFor: const Duration(seconds: 60),
    ),
  );

  @override
  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _stt.cancel();
    } catch (_) {}
  }
}

final speechServiceProvider = Provider<SpeechService>(
  (_) => DeviceSpeechService(),
);
