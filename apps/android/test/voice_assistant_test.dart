import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/assistant/assistant_page.dart';
import 'package:moma/features/voice/speech_service.dart';
import 'package:moma/features/voice/tts_service.dart';
import 'package:moma/features/voice/voice_prefs.dart';
import 'package:moma/features/voice/voice_widgets.dart';

import 'support/fake_api.dart';

/// Scripted recognizer: the test "says" words through [say].
class _FakeSpeech implements SpeechService {
  bool permission = true;

  /// Whether the system prompt grants the permission when [initialize] asks.
  bool grantOnPrompt = true;
  List<String> locales = ['en_US', 'vi_VN'];
  int listens = 0, stops = 0, cancels = 0, prompts = 0;
  String? listenedLocale;
  void Function(String words, bool isFinal)? _onResult;
  void Function(String status)? _onStatus;
  String _last = '';

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> initialize({
    required void Function(String code, bool permanent) onError,
    required void Function(String status) onStatus,
  }) async {
    _onStatus = onStatus;
    if (!permission) {
      prompts++;
      permission = grantOnPrompt;
    }
    return permission;
  }

  @override
  Future<List<String>> localeIds() async => locales;

  @override
  Future<String?> systemLocaleId() async => 'en_US';

  @override
  Future<void> listen({
    String? localeId,
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
  }) async {
    listens++;
    listenedLocale = localeId;
    _onResult = onResult;
    _last = '';
    _onStatus?.call('listening');
  }

  @override
  Future<void> stop() async {
    stops++;
    _onResult?.call(_last, true);
    _onStatus?.call('done');
  }

  @override
  Future<void> cancel() async => cancels++;

  void say(String words, {bool isFinal = false}) {
    _last = words;
    _onResult?.call(words, isFinal);
  }
}

class _FakeTts implements TtsService {
  @override
  VoidCallback? onDone;
  final spoken = <String>[];
  int stops = 0;

  @override
  Future<TtsOutcome> speak(String text) async {
    spoken.add(text);
    return TtsOutcome.ok;
  }

  @override
  Future<void> stop() async => stops++;
}

class _AgentApi extends FakeApi {
  final sent = <String>[];

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    if (path != '/ai/agent') return <String, dynamic>{};
    sent.add('${(body as Map)['text']}');
    return {'reply': 'Đã ghi ăn tối 200.000 ₫.', 'actions': [], 'plan': []};
  }
}

class _Env {
  _Env(this.speech, this.tts, this.api);
  final _FakeSpeech speech;
  final _FakeTts tts;
  final _AgentApi api;
}

Future<_Env> _open(
  WidgetTester tester, {
  _FakeSpeech? speech,
  _FakeTts? tts,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final env = _Env(speech ?? _FakeSpeech(), tts ?? _FakeTts(), _AgentApi());
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(env.api),
        speechServiceProvider.overrideWithValue(env.speech),
        ttsServiceProvider.overrideWithValue(env.tts),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(body: AssistantPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return env;
}

String _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byType(VoiceMicButton));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('mic shows when the field is empty and toggles listening', (
    tester,
  ) async {
    final env = await _open(tester);
    expect(find.byType(VoiceMicButton), findsOneWidget);
    expect(find.byTooltip('Gửi'), findsNothing);

    await _tapMic(tester);
    expect(env.speech.listens, 1);
    expect(env.speech.listenedLocale, 'vi_VN');
    expect(find.byType(ListeningBar), findsOneWidget);
    expect(find.text('Đang nghe…'), findsWidgets);

    await _tapMic(tester); // tap again: stop
    expect(env.speech.stops, 1);
    expect(find.byType(ListeningBar), findsNothing);
    // Nothing was heard: a short message, never silence.
    expect(find.textContaining('chưa nghe rõ'), findsOneWidget);
    expect(env.api.sent, isEmpty);

    await tester.enterText(find.byType(TextField), 'xin chào');
    await tester.pump();
    expect(find.byTooltip('Gửi'), findsOneWidget);
    expect(find.byType(VoiceMicButton), findsNothing);
  });

  testWidgets('partial words fill the field while listening', (tester) async {
    final env = await _open(tester);
    await _tapMic(tester);
    env.speech.say('hôm nay');
    await tester.pump();
    expect(_field(tester), 'hôm nay');
    env.speech.say('hôm nay ăn tối');
    await tester.pump();
    expect(_field(tester), 'hôm nay ăn tối');
    expect(find.byType(ListeningBar), findsOneWidget);
    expect(env.api.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byType(VoiceMicButton));
    await tester.pumpAndSettle();
  });

  testWidgets('final result is sent to the assistant automatically', (
    tester,
  ) async {
    final env = await _open(tester);
    await _tapMic(tester);
    env.speech.say('Hôm nay ăn tối 200k', isFinal: true);
    await tester.pumpAndSettle();
    expect(env.api.sent, ['Hôm nay ăn tối 200k']);
    expect(find.text('Hôm nay ăn tối 200k'), findsOneWidget); // user bubble
    expect(find.text('Đã ghi ăn tối 200.000 ₫.'), findsOneWidget);
    expect(_field(tester), isEmpty);
    expect(env.tts.spoken, isEmpty); // "Tự đọc câu trả lời" is off by default
  });

  testWidgets('1.5 s of silence ends listening and sends', (tester) async {
    final env = await _open(tester);
    await _tapMic(tester);
    env.speech.say('Nhận lương 15 triệu');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(env.api.sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(env.speech.stops, 1);
    expect(env.api.sent, ['Nhận lương 15 triệu']);
  });

  testWidgets('falls back to the device locale without Vietnamese', (
    tester,
  ) async {
    final env = await _open(tester, speech: _FakeSpeech()..locales = ['en_US']);
    await _tapMic(tester);
    await tester.pump();
    expect(env.speech.listenedLocale, 'en_US');
    expect(find.textContaining('chưa có nhận dạng tiếng Việt'), findsOneWidget);
    await env.speech.cancel();
    await tester.tap(find.byType(VoiceMicButton));
    await tester.pumpAndSettle();
  });

  testWidgets('rationale comes before the system prompt; refusals lead to '
      'the Settings dialog', (tester) async {
    final speech = _FakeSpeech()
      ..permission = false
      ..grantOnPrompt = false;
    final env = await _open(tester, speech: speech);

    await _tapMic(tester);
    await tester.pumpAndSettle();
    expect(find.text('Cho phép dùng micro'), findsOneWidget);
    expect(find.textContaining('MoMa không lưu âm thanh'), findsOneWidget);
    expect(env.speech.prompts, 0); // nothing asked before the owner agrees
    await tester.tap(find.text('Tiếp tục'));
    await tester.pumpAndSettle();
    expect(env.speech.prompts, 1);
    expect(find.textContaining('Bạn chưa cho phép micro'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // let the snack bar go
    await tester.pumpAndSettle();

    // Second refusal: Android stops asking, so MoMa points to Settings.
    await _tapMic(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tiếp tục'));
    await tester.pumpAndSettle();
    expect(find.text('Chưa có quyền micro'), findsOneWidget);
    expect(find.text('Mở Cài đặt'), findsOneWidget);
    expect(env.speech.listens, 0);
    await tester.tap(find.text('Để sau'));
    await tester.pumpAndSettle();
  });

  testWidgets('granting the permission starts listening', (tester) async {
    final env = await _open(tester, speech: _FakeSpeech()..permission = false);
    await _tapMic(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tiếp tục'));
    await tester.pump();
    await tester.pump();
    expect(env.speech.listens, 1);
    expect(find.byType(ListeningBar), findsOneWidget);
    await tester.tap(find.byType(VoiceMicButton));
    await tester.pumpAndSettle();
  });

  testWidgets('/ai?voice=1 (widget mic) starts listening', (tester) async {
    final env = await _open(tester);
    ProviderScope.containerOf(tester.element(find.byType(AssistantPage)))
        .read(voiceLaunchProvider.notifier)
        .request();
    await tester.pump();
    await tester.pump();
    expect(env.speech.listens, 1);
    expect(find.byType(ListeningBar), findsOneWidget);
    await tester.tap(find.byType(VoiceMicButton));
    await tester.pumpAndSettle();
  });

  testWidgets('"Tự đọc câu trả lời" persists and reads replies', (
    tester,
  ) async {
    var env = await _open(tester);
    await tester.tap(find.byTooltip('Giọng nói'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<String>>(
            find.widgetWithText(
              CheckedPopupMenuItem<String>,
              'Tự đọc câu trả lời',
            ),
          )
          .checked,
      isFalse,
    );
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Tự đọc câu trả lời'),
    );
    await tester.pumpAndSettle();
    expect(
      await const FlutterSecureStorage().read(key: 'voice_auto_read'),
      '1',
    );

    // A fresh app start reads the stored choice.
    await tester.pumpWidget(const SizedBox());
    env = await _open(tester);
    await tester.tap(find.byTooltip('Giọng nói'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckedPopupMenuItem<String>>(
            find.widgetWithText(
              CheckedPopupMenuItem<String>,
              'Tự đọc câu trả lời',
            ),
          )
          .checked,
      isTrue,
    );
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Hôm nay ăn tối 200k');
    await tester.pump();
    await tester.tap(find.byTooltip('Gửi'));
    await tester.pumpAndSettle();
    expect(env.tts.spoken, ['Đã ghi ăn tối 200.000 ₫.']);
    expect(find.text('Dừng'), findsOneWidget);

    // Starting to talk stops the reading.
    final stopsBefore = env.tts.stops;
    await _tapMic(tester);
    expect(env.tts.stops, greaterThan(stopsBefore));
    expect(find.text('Đọc'), findsOneWidget);
    await tester.tap(find.byType(VoiceMicButton));
    await tester.pumpAndSettle();
  });
}
