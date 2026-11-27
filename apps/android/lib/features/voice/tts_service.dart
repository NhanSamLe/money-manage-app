import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsOutcome { ok, noVietnamese, failed }

/// Reads the assistant's replies aloud (Vietnamese voice of the phone's text-to-speech engine).
abstract class TtsService {
  /// Called when the current utterance ends, is stopped or fails.
  VoidCallback? onDone;

  Future<TtsOutcome> speak(String text);
  Future<void> stop();
}

/// Text the engine reads well: currency sign spelled out, whitespace collapsed.
String speakableText(String text) =>
    text.replaceAll('₫', ' đồng').replaceAll(RegExp(r'\s+'), ' ').trim();

class DeviceTtsService implements TtsService {
  @override
  VoidCallback? onDone;

  FlutterTts? _tts;
  bool? _vietnamese;

  Future<FlutterTts> _engine() async {
    final existing = _tts;
    if (existing != null) return existing;
    final t = FlutterTts();
    t.setCompletionHandler(() => onDone?.call());
    t.setCancelHandler(() => onDone?.call());
    t.setErrorHandler((_) => onDone?.call());
    await t.awaitSpeakCompletion(false);
    return _tts = t;
  }

  @override
  Future<TtsOutcome> speak(String text) async {
    try {
      final t = await _engine();
      _vietnamese ??= (await t.isLanguageAvailable('vi-VN')) == true;
      if (_vietnamese != true) return TtsOutcome.noVietnamese;
      await t.setLanguage('vi-VN');
      await t.setSpeechRate(0.5);
      final r = await t.speak(speakableText(text));
      return r == 1 ? TtsOutcome.ok : TtsOutcome.failed;
    } catch (e) {
      debugPrint('MoMa tts: $e');
      return TtsOutcome.failed;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

final ttsServiceProvider = Provider<TtsService>((_) => DeviceTtsService());
