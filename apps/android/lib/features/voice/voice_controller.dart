import 'dart:async';

import 'package:flutter/foundation.dart';

import 'speech_service.dart';

enum VoicePhase { idle, listening }

/// Why a listening session ended without a sentence (each has a short Vietnamese message).
enum VoiceIssue {
  noMatch,
  network,
  busy,
  audio,
  permission,
  noRecognizer,
  languageUnavailable,
  unknown,
}

String voiceIssueMessage(VoiceIssue i) => switch (i) {
  VoiceIssue.noMatch => 'Mình chưa nghe rõ. Bạn bấm micro và nói lại nhé.',
  VoiceIssue.network => 'Nhận dạng giọng nói trên điện thoại này cần mạng. Bạn kiểm tra kết nối rồi thử lại.',
  VoiceIssue.busy => 'Dịch vụ giọng nói đang bận. Bạn thử lại sau giây lát.',
  VoiceIssue.audio =>
    'Không mở được micro. Có thể ứng dụng khác đang dùng micro.',
  VoiceIssue.permission => 'MoMa chưa được phép dùng micro.',
  VoiceIssue.noRecognizer => 'Điện thoại chưa có dịch vụ nhận dạng giọng nói. Bạn cài hoặc bật ứng dụng Google (Gõ bằng giọng nói của Google) rồi thử lại.',
  VoiceIssue.languageUnavailable => 'Điện thoại chưa hỗ trợ nhận dạng tiếng Việt. Bạn thêm Tiếng Việt trong Gõ bằng giọng nói của Google rồi thử lại.',
  VoiceIssue.unknown => 'Không nhận dạng được giọng nói. Bạn thử lại nhé.',
};

/// One listening session at a time: picks the Vietnamese recognizer (falls back to the device locale), streams
/// partial text, ends after [silence] without new words, and reports exactly one outcome per session:
/// [onFinal] with the sentence, or [onIssue].
class VoiceController extends ChangeNotifier {
  VoiceController(
    this.speech, {
    this.silence = const Duration(milliseconds: 1500),
    this.finalGrace = const Duration(milliseconds: 2500),
  });

  final SpeechService speech;

  /// Quiet time after the last new words before listening ends by itself.
  final Duration silence;

  /// How long to wait for the recognizer's final result after stopping.
  final Duration finalGrace;

  void Function(String words)? onPartial;
  void Function(String words)? onFinal;
  void Function(VoiceIssue issue)? onIssue;

  /// The recognizer has no Vietnamese: listening uses the device locale (tell the owner once).
  VoidCallback? onLocaleFallback;

  VoicePhase phase = VoicePhase.idle;
  bool get listening => phase == VoicePhase.listening;

  /// Microphone input level, 0..1 (drives the waveform).
  final level = ValueNotifier<double>(0);

  String _words = '';
  bool _closed = true;
  Timer? _silenceTimer;
  Timer? _graceTimer;
  String? _locale;
  bool _localeResolved = false;
  bool _fellBack = false;

  /// True when the device locale is used because Vietnamese is not available.
  bool get fellBack => _fellBack;

  /// Initializes the recognizer (asks for the microphone permission when needed).
  Future<bool> prepare() =>
      speech.initialize(onError: _onError, onStatus: _onStatus);

  Future<void> _resolveLocale() async {
    if (_localeResolved) return;
    _localeResolved = true;
    final ids = await speech.localeIds();
    String norm(String s) => s.replaceAll('-', '_').toLowerCase();
    final vi = ids.where((l) => norm(l).startsWith('vi')).toList();
    if (vi.isNotEmpty) {
      _locale = vi.firstWhere((l) => norm(l) == 'vi_vn', orElse: () => vi[0]);
    } else if (ids.isEmpty) {
      _locale =
          'vi_VN'; // the list is empty on some phones: try Vietnamese anyway
    } else {
      await _fallBack();
    }
  }

  Future<void> _fallBack() async {
    _fellBack = true;
    _locale = await speech.systemLocaleId();
    onLocaleFallback?.call();
  }

  /// Starts a session (call [prepare] first).
  Future<void> start() async {
    if (listening) return;
    await _resolveLocale();
    _words = '';
    _closed = false;
    phase = VoicePhase.listening;
    notifyListeners();
    try {
      await speech.listen(
        localeId: _locale,
        onResult: _onResult,
        onLevel: (l) => level.value = ((l + 2) / 12).clamp(0.0, 1.0),
      );
    } catch (e) {
      debugPrint('MoMa voice: listen failed: $e');
      _fail(VoiceIssue.unknown);
    }
  }

  /// Ends listening; the words heard so far become the final sentence.
  Future<void> stop() async {
    if (_closed) return;
    _silenceTimer?.cancel();
    _graceTimer?.cancel();
    _graceTimer = Timer(finalGrace, () => _finish(_words));
    await speech.stop();
  }

  /// Ends listening and drops the words (leaving the page, sending by hand).
  Future<void> cancel() async {
    final wasOpen = !_closed;
    _close();
    if (wasOpen) await speech.cancel();
  }

  void _onResult(String words, bool isFinal) {
    if (_closed) return;
    if (words.trim().isNotEmpty && words != _words) {
      _words = words;
      onPartial?.call(words);
      _silenceTimer?.cancel();
      if (!isFinal) _silenceTimer = Timer(silence, stop);
    }
    if (isFinal) _finish(words.trim().isEmpty ? _words : words);
  }

  void _onStatus(String status) {
    if (_closed) return;
    if (status == 'notListening') {
      level.value = 0;
      _graceTimer ??= Timer(finalGrace, () => _finish(_words));
    } else if (status == 'done' || status == 'doneNoResult') {
      _finish(_words);
    }
  }

  void _onError(String code, bool permanent) {
    debugPrint('MoMa voice: error $code (permanent: $permanent)');
    if (_closed) return; // late errors after a finished session are noise
    if (code == 'error_no_match' || code == 'error_speech_timeout') {
      _finish(_words);
      return;
    }
    if ((code == 'error_language_not_supported' ||
            code == 'error_language_unavailable') &&
        !_fellBack) {
      _close();
      _fallBack().then((_) => start());
      return;
    }
    _fail(switch (code) {
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' => VoiceIssue.network,
      'error_busy' || 'error_too_many_requests' => VoiceIssue.busy,
      'error_audio_error' => VoiceIssue.audio,
      'error_permission' => VoiceIssue.permission,
      'error_language_not_supported' ||
      'error_language_unavailable' => VoiceIssue.languageUnavailable,
      _ => VoiceIssue.unknown,
    });
  }

  void _finish(String words) {
    if (_closed) return;
    _close();
    if (words.trim().isEmpty) {
      onIssue?.call(VoiceIssue.noMatch);
    } else {
      onFinal?.call(words.trim());
    }
  }

  void _fail(VoiceIssue issue) {
    if (_closed) return;
    _close();
    onIssue?.call(issue);
  }

  void _close() {
    _closed = true;
    _silenceTimer?.cancel();
    _graceTimer?.cancel();
    _silenceTimer = null;
    _graceTimer = null;
    level.value = 0;
    if (phase != VoicePhase.idle) {
      phase = VoicePhase.idle;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _graceTimer?.cancel();
    level.dispose();
    super.dispose();
  }
}
