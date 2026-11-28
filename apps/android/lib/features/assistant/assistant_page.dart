import '../collect/collect.dart' show RemindActionCard;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/category_style.dart';
import '../../core/widgets.dart';
import '../lock/lock_controller.dart' show lockControllerProvider;
import '../voice/speech_service.dart';
import '../voice/tts_service.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_prefs.dart';
import '../voice/voice_widgets.dart';
import '../transactions/tx_attachments.dart'
    show sniffImageType, txAttachmentsProvider, uploadQueueProvider;
import 'memory_page.dart';
import 'routine_chips.dart';

/// The finance assistant ("Trợ lý tài chính"), the owner's finance assistant: an agent, not a chat. One sentence becomes concrete steps (record,
/// transfer, lend, repay, budget, cancel, answer). Low-risk steps run by themselves when "Tự động ghi" is on;
/// everything else is one tap away. The model only plans: every step is validated by the server and executed
/// through the normal idempotent commands. Photos are read on the device (OCR) and only the text is sent.

enum _St { pending, running, done, failed, skipped }

class _Step {
  _Step(this.json) : commandId = ApiClient.newId();
  final Map<String, dynamic> json;
  final String commandId;
  _St status = _St.pending;
  String? error;
  String? txId;
  bool undone = false;

  /// Command result (ids used by later steps' `$sN.field` and by Hoàn tác's `$result.field`).
  Map<String, dynamic>? result;
  bool photoAttached = false;

  String get id => '${json['id'] ?? ''}';
  String get type => '${json['type']}';
  bool get isCommand => type == 'COMMAND' || type == 'CALL';
  bool get low => json['risk'] == 'low';
  Map<String, dynamic>? get undoSpec =>
      (json['undo'] as Map?)?.cast<String, dynamic>();
  bool get undoable => undoSpec != null || json['undoable'] == true;
  bool get attachPhoto => json['attach_photo'] == true;
  String get title => '${json['title'] ?? ''}';
  List<String> get lines => [
    for (final l in (json['lines'] as List? ?? const [])) '$l',
  ];
  String get commandType =>
      '${(json['command'] as Map?)?['command_type'] ?? (type == 'CALL' ? 'CALL' : '')}';
}

/// Fills `"$sN.field"` placeholders (results of earlier steps of the same turn) inside a JSON payload.
String fillStepRefs(
  String payloadJson,
  Map<String, Map<String, dynamic>> results,
) => payloadJson.replaceAllMapped(
  RegExp(r'"\$(s\d{1,2}[a-z]?)\.([a-z_]+)"'),
  (m) => jsonEncode(results[m[1]]?[m[2]]),
);

/// Undo ops with `$result.field` filled from the executed command's result.
List<Map<String, dynamic>> fillUndoOps(
  List<dynamic> ops,
  Map<String, dynamic> result,
) => [
  for (final op in ops)
    {
      for (final e in (op as Map).cast<String, dynamic>().entries)
        e.key: e.value is String && (e.value as String).startsWith(r'$result.')
            ? result[(e.value as String).substring(8)]
            : e.value,
    },
];

class _Turn {
  _Turn.user(this.text, {this.image})
    : isUser = true,
      steps = const [],
      reply = '',
      plan = const [],
      at = DateTime.now();
  _Turn.agent(this.reply, this.steps, [this.plan = const []])
    : isUser = false,
      text = '',
      image = null,
      at = DateTime.now();
  final List<Map<String, dynamic>> plan;
  final bool isUser;
  final String text;
  final String reply;
  final List<_Step> steps;
  final DateTime at;

  /// Photo the request was read from (kept in memory for the bubble only, never uploaded).
  final Uint8List? image;

  /// The server answered this user message.
  bool delivered = false;
}

class _Chat extends Notifier<List<_Turn>> {
  @override
  List<_Turn> build() => [];
  void add(_Turn t) => state = [...state, t];
  void touch() => state = [...state];
}

final _chatProvider = NotifierProvider<_Chat, List<_Turn>>(_Chat.new);

class _Busy extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final _busyProvider = NotifierProvider<_Busy, bool>(_Busy.new);

/// Owner preference: let the agent record low-risk steps without asking (default on, every step can be undone).
class _Auto extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) => state = v;
}

final aiAutoProvider = NotifierProvider<_Auto, bool>(_Auto.new);

/// Upper bound of `text` accepted by POST /v1/ai/agent (server `MAX_INPUT_CHARS`).
const _maxRequestChars = 1600;

/// Cap for the OCR part of a photo request (the server limit above wins while it is smaller).
const _maxOcrChars = 1500;

const _photoPrefix = 'Ảnh hóa đơn/chuyển khoản:\n';

/// Request text for a receipt / transfer screenshot: the OCR lines, whitespace-normalised and truncated.
String _photoRequest(String ocr) {
  final lines = ocr
      .split('\n')
      .map((l) => l.trim().replaceAll(RegExp(r'\s+'), ' '))
      .where((l) => l.isNotEmpty)
      .join('\n');
  final room = math.min(_maxOcrChars, _maxRequestChars - _photoPrefix.length);
  return '$_photoPrefix${lines.length > room ? lines.substring(0, room) : lines}';
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class AssistantPage extends ConsumerStatefulWidget {
  const AssistantPage({super.key});
  @override
  ConsumerState<AssistantPage> createState() => _AssistantPageState();
}

/// Text of an agent turn read aloud: the reply and any question it asks.
String _spoken(_Turn t) => [
  t.reply.trim(),
  for (final s in t.steps)
    if (s.type == 'ASK') '${s.json['question'] ?? ''}'.trim(),
].where((s) => s.isNotEmpty).join('. ');

class _AssistantPageState extends ConsumerState<AssistantPage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// Bill photo sent in this conversation, attached to the transaction it ends up in (then cleared).
  Uint8List? _pendingPhoto;
  final _scroll = ScrollController();

  /// Waiting for the agent's plan (drives the staged loading bubble).
  bool _waiting = false;

  /// Picking a photo / running OCR.
  bool _reading = false;

  /// Voice input (speech recognizer behind [speechServiceProvider]).
  late final VoiceController _voice;

  /// Text-to-speech for replies; [_speaking] is the turn being read.
  late final TtsService _tts;
  _Turn? _speaking;

  /// Preparing the microphone (permission / recognizer) so taps during that time are ignored.
  bool _arming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tts = ref.read(ttsServiceProvider);
    _tts.onDone = () {
      if (mounted && _speaking != null) setState(() => _speaking = null);
    };
    _voice = VoiceController(ref.read(speechServiceProvider))
      ..onPartial = _onVoiceText
      ..onFinal = _onVoiceFinal
      ..onIssue = _onVoiceIssue
      ..onLocaleFallback = _onLocaleFallback
      ..addListener(_onVoicePhase);
    // Opened from the home-screen widget mic (moma://app/ai?voice=1): start listening at once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(voiceLaunchProvider.notifier).consume()) {
        _startVoice();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.cancel();
    _voice.dispose();
    _tts.onDone = null;
    _tts.stop();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Not `inactive`: the microphone permission prompt makes the app inactive while it is still in front.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _quiet();
    }
  }

  /// Leaving the assistant (tab switch, app in background): stop listening and speaking.
  void _quiet() {
    _voice.cancel();
    _stopSpeaking();
  }

  void _onVoicePhase() {
    if (mounted) setState(() {});
  }

  void _onVoiceText(String words) {
    _input.value = TextEditingValue(
      text: words,
      selection: TextSelection.collapsed(offset: words.length),
    );
  }

  void _onVoiceFinal(String words) {
    _onVoiceText(words);
    if (ref.read(voicePrefsProvider).autoSend) _send();
  }

  void _onVoiceIssue(VoiceIssue issue) {
    if (!mounted) return;
    if (issue == VoiceIssue.permission) {
      showMicSettingsDialog(context);
    } else if (issue == VoiceIssue.languageUnavailable ||
        issue == VoiceIssue.noRecognizer) {
      showErrorDialog(context, voiceIssueMessage(issue));
    } else {
      showSnack(context, voiceIssueMessage(issue));
    }
  }

  Future<void> _onLocaleFallback() async {
    final prefs = ref.read(voicePrefsProvider.notifier);
    if (await prefs.localeWarned()) return;
    await prefs.setLocaleWarned();
    if (mounted) {
      showSnack(
        context,
        'Điện thoại chưa có nhận dạng tiếng Việt, MoMa dùng ngôn ngữ mặc định của máy. Bạn có thể thêm Tiếng Việt trong Gõ bằng giọng nói của Google.',
      );
    }
  }

  /// Mic tap: start listening, or stop (the words heard so far are kept / sent).
  Future<void> _toggleVoice() async {
    if (_voice.listening) {
      await _voice.stop();
    } else {
      await _startVoice();
    }
  }

  Future<void> _startVoice() async {
    if (_arming || _voice.listening || ref.read(_busyProvider)) return;
    _stopSpeaking();
    _arming = true;
    try {
      final ready = await ensureVoiceReady(
        context,
        speech: _voice.speech,
        prepare: _voice.prepare,
        prefs: ref.read(voicePrefsProvider.notifier),
      );
      if (!ready || !mounted) return;
      FocusScope.of(context).unfocus();
      await _voice.start();
    } finally {
      _arming = false;
    }
  }

  void _stopSpeaking() {
    if (_speaking != null && mounted) setState(() => _speaking = null);
    _tts.stop();
  }

  /// "Đọc" on a reply (tap again to stop).
  Future<void> _speak(_Turn t) async {
    if (_speaking == t) {
      _stopSpeaking();
      return;
    }
    final text = _spoken(t);
    if (text.isEmpty) return;
    await _tts.stop();
    if (!mounted) return;
    setState(() => _speaking = t);
    final r = await _tts.speak(text);
    if (r == TtsOutcome.ok || !mounted) return;
    setState(() => _speaking = null);
    showSnack(
      context,
      r == TtsOutcome.noVietnamese
          ? 'Điện thoại chưa có giọng đọc tiếng Việt. Bạn cài "Dịch vụ giọng nói của Google" và tải giọng Tiếng Việt.'
          : 'Không đọc được câu trả lời. Bạn thử lại nhé.',
    );
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  void _setWaiting(bool v) {
    if (mounted && _waiting != v) setState(() => _waiting = v);
  }

  /// The agent's last plan with the status of each step, so the next sentence can continue the same task
  /// ("50k" after "which amount?") instead of starting over.
  Map<String, dynamic>? _previousPlan() {
    final turns = ref.read(_chatProvider);
    final last = turns.lastWhere(
      (t) => !t.isUser,
      orElse: () => _Turn.user(''),
    );
    if (last.isUser || last.plan.isEmpty) return null;
    String status(_Step s) {
      if (s.type == 'ASK' || s.type == 'CHOICES') return 'ASKED';
      if (s.type == 'ANSWER' || s.type == 'REMIND') return 'DONE';
      return switch (s.status) {
        _St.done => 'DONE',
        _St.pending || _St.running || _St.failed => 'PENDING',
        _St.skipped => 'DONE',
      };
    }

    // One plan step may become several cards (a bill split) or a question (CHOICES); a pending bill split is
    // always "waiting for the owner's answer".
    final steps = <Map<String, dynamic>>[];
    for (var i = 0; i < last.plan.length; i++) {
      final p = last.plan[i];
      final step = i < last.steps.length ? last.steps[i] : null;
      steps.add({
        'do': '${p['do']}',
        'status': p['do'] == 'SPLIT_PENDING'
            ? 'ASKED'
            : (step == null ? 'DONE' : status(step)),
        'data': p,
      });
    }
    if (steps.length > 12) steps.removeRange(0, steps.length - 12);
    final ask = last.steps
        .where((s) => s.type == 'ASK')
        .map((s) => '${s.json['question']}')
        .firstOrNull;
    return {'steps': steps, 'question': ?ask};
  }

  List<Map<String, String>> _history() {
    final turns = ref.read(_chatProvider);
    final tail = turns.length > 6 ? turns.sublist(turns.length - 6) : turns;
    return [
      for (final t in tail)
        {
          'role': t.isUser ? 'user' : 'agent',
          'text': (t.isUser ? t.text : t.reply).length > 280
              ? (t.isUser ? t.text : t.reply).substring(0, 280)
              : (t.isUser ? t.text : t.reply),
        },
    ];
  }

  Future<void> _send([String? preset, Uint8List? image]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || ref.read(_busyProvider)) return;
    _voice.cancel(); // sent by hand while listening: the field text wins
    _stopSpeaking();
    if (preset == null) _input.clear();
    final chat = ref.read(_chatProvider.notifier);
    final history = _history();
    final mine = _Turn.user(text, image: image);
    chat.add(mine);
    ref.read(_busyProvider.notifier).set(true);
    _setWaiting(true);
    _toEnd();
    try {
      final previous = _previousPlan();
      final data = await ref.read(apiProvider).post('/ai/agent', {
        'text': text,
        'auto': ref.read(aiAutoProvider),
        if (history.isNotEmpty) 'history': history,
        'previous': ?previous,
      }) as Map<String, dynamic>;
      mine.delivered = true;
      final steps = [
        for (final a in (data['actions'] as List))
          _Step(Map<String, dynamic>.from(a as Map)),
      ];
      final turn = _Turn.agent('${data['reply'] ?? ''}', steps, [
        for (final p in (data['plan'] as List? ?? const []))
          Map<String, dynamic>.from(p as Map),
      ]);
      _setWaiting(false);
      chat.add(turn);
      _toEnd();
      if (ref.read(voicePrefsProvider).autoRead && mounted) {
        _speak(turn).ignore();
      }
      if (ref.read(aiAutoProvider)) {
        for (final s in steps.where((s) => s.isCommand && s.low)) {
          await _run(s);
        }
      }
    } on ApiException catch (e) {
      _setWaiting(false);
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      _setWaiting(false);
      ref.read(_busyProvider.notifier).set(false);
      _toEnd();
    }
  }

  /// "+" button: take or pick a photo of a receipt / transfer screenshot, read it on the device and send the text.
  Future<void> _attach() async {
    if (_reading || ref.read(_busyProvider)) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Symbols.photo_camera_rounded),
                title: const Text('Chụp ảnh'),
                onTap: () => Navigator.pop(c, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Symbols.photo_library_rounded),
                title: const Text('Chọn từ thư viện'),
                onTap: () => Navigator.pop(c, ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    setState(() => _reading = true);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 88,
      );
      if (file == null) return;
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final String ocr;
      try {
        ocr = (await recognizer.processImage(
          InputImage.fromFilePath(file.path),
        )).text;
      } finally {
        await recognizer.close();
      }
      if (ocr.trim().isEmpty) {
        if (mounted) showSnack(context, 'Không đọc được chữ trong ảnh');
        return;
      }
      final bytes = await file.readAsBytes();
      _pendingPhoto = bytes;
      if (!mounted) return;
      setState(() => _reading = false);
      await _send(_photoRequest(ocr), bytes);
    } on PlatformException catch (e) {
      // Visible in `adb logcat` (I/flutter) even in release builds.
      debugPrint('MoMa photo: PlatformException ${e.code}: ${e.message}');
      if (mounted) {
        final denied =
            e.code.contains('denied') || e.code.contains('permission');
        await showErrorDialog(
          context,
          denied
              ? 'MoMa chưa có quyền dùng máy ảnh hoặc thư viện ảnh. Bạn bật quyền trong Cài đặt điện thoại rồi thử lại.'
              : 'Không đọc được ảnh này (${e.code}). Bạn thử chọn ảnh khác hoặc chụp lại rõ hơn.',
        );
      }
    } catch (e) {
      debugPrint('MoMa photo: ${e.runtimeType}: $e');
      if (mounted) {
        await showErrorDialog(
          context,
          'Không đọc được ảnh này. Bạn thử chọn ảnh khác hoặc chụp lại rõ hơn.',
        );
      }
    } finally {
      if (mounted && _reading) setState(() => _reading = false);
    }
  }

  Future<void> _run(_Step s) async {
    if (s.status == _St.running || s.status == _St.done) return;
    s.status = _St.running;
    s.error = null;
    ref.read(_chatProvider.notifier).touch();
    final api = ref.read(apiProvider);
    try {
      if (s.type == 'CALL') {
        final call = (s.json['call'] as Map).cast<String, dynamic>();
        final path = '${call['path']}';
        s.result = call['method'] == 'DELETE'
            ? ((await api.delete(path)) as Map?)?.cast<String, dynamic>()
            : ((await api.post(
                path,
                (call['body'] as Map?) ?? const {},
              )) as Map?)?.cast<String, dynamic>();
        s.status = _St.done;
        ref.read(_chatProvider.notifier).touch();
        return;
      }
      // Results of the earlier steps of the same answer fill `$sN.field` (e.g. the bill's tx id for the split).
      final results = <String, Map<String, dynamic>>{
        for (final t in ref.read(_chatProvider))
          if (t.steps.contains(s))
            for (final o in t.steps)
              if (o.result != null) o.id: o.result!,
      };
      var payload = fillStepRefs(
        jsonEncode((s.json['command'] as Map)['payload']),
        results,
      );
      final pre = s.json['pre'] as Map?;
      if (pre != null) {
        final r = await api.command(
          '${pre['command_type']}',
          Map<String, dynamic>.from(pre['payload'] as Map),
          commandId: ApiClient.newId(),
        );
        payload = payload.replaceAll(
          '\$${pre['bind']}',
          '${r['${pre['bind']}']}',
        );
      }
      final res = await api.command(
        s.commandType,
        jsonDecode(payload) as Map<String, dynamic>,
        commandId: s.commandId,
      );
      s.result = res;
      s.txId =
          res['tx_id'] as String? ??
          (jsonDecode(payload) as Map<String, dynamic>)['tx_id'] as String?;
      s.status = _St.done;
      refreshAll(ref);
      ref.invalidate(profileProvider);
      if (s.attachPhoto) await _attachPhoto(s);
    } on ApiException catch (e) {
      s.status = _St.failed;
      s.error = e.message;
    }
    ref.read(_chatProvider.notifier).touch();
  }

  /// The bill photo of this conversation goes to the transaction it was recorded in (queued when offline).
  Future<void> _attachPhoto(_Step s) async {
    final photo = _pendingPhoto;
    final txId = s.txId;
    if (photo == null || txId == null || s.photoAttached) return;
    final type = sniffImageType(photo) ?? 'image/jpeg';
    try {
      await ref
          .read(apiProvider)
          .postBytes(
            '/transactions/$txId/attachments',
            photo,
            contentType: type,
          );
      ref.invalidate(txAttachmentsProvider(txId));
    } on ApiException catch (e) {
      // e.g. 10 pictures already: the record itself is fine, only offline is worth queueing.
      if (e.code != 'OFFLINE') return;
      await ref.read(uploadQueueProvider.notifier).add(txId, photo, type);
    }
    s.photoAttached = true;
    _pendingPhoto = null;
  }

  Future<void> _undo(_Step s) async {
    if (s.undone) return;
    try {
      final spec = s.undoSpec;
      if (spec != null && s.result != null) {
        // The server reads the current versions, so Hoàn tác works even after the item changed since.
        await ref.read(apiProvider).post('/ai/undo', {
          'step_command_id': s.commandId,
          'ops': fillUndoOps(spec['ops'] as List, s.result!),
          if (spec['habit'] != null) 'habit': spec['habit'],
        });
      } else if (s.txId != null) {
        await ref.read(apiProvider).command('TX_REVERSE', {
          'tx_id': s.txId,
          'reason': 'Hoàn tác từ Trợ lý AI',
          'expected_version': 1,
        }, commandId: ApiClient.newId());
      } else {
        return;
      }
      s.undone = true;
      refreshAll(ref);
      ref.read(_chatProvider.notifier).touch();
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    }
  }

  /// A quick answer of a CHOICES card: a ready action runs at once, a text is sent as the next message,
  /// an empty text pre-fills the input for the owner to finish ("Chia với …").
  Future<void> _choose(_Turn turn, Map<String, dynamic> option) async {
    final action = (option['action'] as Map?)?.cast<String, dynamic>();
    if (action != null) {
      final step = _Step(action);
      turn.steps.add(step);
      ref.read(_chatProvider.notifier).touch();
      await _run(step);
      return;
    }
    final text = '${option['text'] ?? ''}';
    if (text.isNotEmpty) {
      await _send(text);
      return;
    }
    final prefill = '${option['prefill'] ?? ''}';
    _input.text = prefill;
    _input.selection = TextSelection.collapsed(offset: prefill.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final turns = ref.watch(_chatProvider);
    final busy = ref.watch(_busyProvider);
    final auto = ref.watch(aiAutoProvider);
    final pal = context.pal;
    final listening = _voice.listening;
    // The assistant lives in the shell's IndexedStack: switching tab is "leaving the page".
    ref.listen<int>(shellTabProvider, (prev, next) {
      if (prev == 2 && next != 2) _quiet();
    });
    ref.listen<bool>(voiceLaunchProvider, (_, next) {
      if (next && ref.read(voiceLaunchProvider.notifier).consume()) {
        _startVoice();
      }
    });
    // A widget-mic launch that arrived while the app lock was up starts once the app is unlocked.
    ref.listen(lockControllerProvider, (_, next) {
      if (next.loaded &&
          !next.locked &&
          ref.read(voiceLaunchProvider.notifier).consume()) {
        _startVoice();
      }
    });
    return ColoredBox(
      color: pal.bg,
      child: Column(
        children: [
          const _Header(),
          // "Sáng nay bạn ăn gì?" one-tap answers learned from the owner's routine (hidden when nothing to ask).
          const RoutineChips(),
          Expanded(
            child: turns.isEmpty
                ? _Welcome(onPick: (t) => _send(t))
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    children: [
                      for (final t in turns)
                        t.isUser
                            ? _UserBubble(turn: t)
                            : _AgentTurn(
                                turn: t,
                                speaking: identical(_speaking, t),
                                onSpeak: () => _speak(t),
                                onRun: _run,
                                onUndo: _undo,
                                onRunAll: () async {
                                  for (final s in t.steps.where(
                                    (s) =>
                                        s.isCommand &&
                                        (s.status == _St.pending ||
                                            s.status == _St.failed),
                                  )) {
                                    await _run(s);
                                  }
                                },
                                onSkip: (s) {
                                  s.status = _St.skipped;
                                  ref.read(_chatProvider.notifier).touch();
                                },
                                onChoose: (o) => _choose(t, o),
                              ),
                      if (_waiting) const _Thinking(),
                    ],
                  ),
          ),
          Container(
            decoration: BoxDecoration(
              color: pal.surface,
              border: Border(top: BorderSide(color: pal.lineSoft)),
            ),
            padding: const EdgeInsets.fromLTRB(10, 4, 12, 10),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (listening)
                    ListeningBar(level: _voice.level)
                  else
                    Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () =>
                              ref.read(aiAutoProvider.notifier).set(!auto),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  auto
                                      ? Symbols.bolt_rounded
                                      : Symbols.touch_app_rounded,
                                  size: 18,
                                  color: auto ? MomaColors.emerald : pal.muted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  auto
                                      ? 'Tự động ghi: Bật'
                                      : 'Tự động ghi: Tắt',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: auto
                                        ? MomaColors.emerald
                                        : pal.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        InkResponse(
                          radius: 18,
                          onTap: () => showInfoDialog(
                            context,
                            title: 'Tự động ghi',
                            message: 'Khi bật, Trợ lý tự ghi các khoản thu chi và chuyển khoản mà Trợ lý hiểu chắc chắn, rồi cho bạn hoàn tác nếu sai. Các việc quan trọng như công nợ, ngân sách hay hủy giao dịch luôn chờ bạn xác nhận.',
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Symbols.help_rounded,
                              size: 18,
                              color: pal.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 44,
                        height: 48,
                        child: Center(
                          child: _reading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: MomaColors.emerald,
                                  ),
                                )
                              : IconButton(
                                  tooltip: 'Gửi ảnh hóa đơn',
                                  onPressed: busy ? null : _attach,
                                  icon: Icon(
                                    Symbols.add_circle_rounded,
                                    size: 28,
                                    color: busy ? pal.hint : MomaColors.emerald,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          maxLength: _maxRequestChars,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            counterText: '',
                            hintText: listening
                                ? 'Đang nghe…'
                                : 'Nhắn hoặc nói với Trợ lý',
                            filled: true,
                            fillColor: pal.surfaceAlt,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(26),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(26),
                              borderSide: BorderSide(color: pal.lineSoft),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(26),
                              borderSide: const BorderSide(
                                color: MomaColors.emerald,
                                width: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Chat-app style: send when there is text, microphone when the field is empty.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _input,
                        builder: (context, value, _) =>
                            listening || value.text.trim().isEmpty
                            ? VoiceMicButton(
                                listening: listening,
                                enabled: !busy,
                                level: _voice.level,
                                onTap: _toggleVoice,
                                onHoldStart: _startVoice,
                                onHoldEnd: () => _voice.stop(),
                              )
                            : IconButton.filled(
                                tooltip: 'Gửi',
                                onPressed: busy ? null : () => _send(),
                                style: IconButton.styleFrom(
                                  backgroundColor: MomaColors.emerald,
                                  disabledBackgroundColor: MomaColors.emerald
                                      .withValues(alpha: 0.4),
                                  shape: const CircleBorder(),
                                  minimumSize: const Size(48, 48),
                                ),
                                icon: const Icon(
                                  Symbols.arrow_upward_rounded,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Assistant avatar: brand gradient circle with the sparkle mark.
class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [MomaColors.forest, MomaColors.emerald],
      ),
    ),
    child: Icon(
      Symbols.auto_awesome_rounded,
      color: MomaColors.mint,
      fill: 1,
      size: size * 0.55,
    ),
  );
}

/// Persona header (the shared plain app bar has no avatar / subtitle slot).
class _Header extends ConsumerWidget {
  const _Header();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final voice = ref.watch(voicePrefsProvider);
    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border(bottom: BorderSide(color: pal.lineSoft)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const _AssistantAvatar(size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Trợ lý tài chính',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: pal.ink,
                        height: 1.2,
                      ),
                    ),
                    Text(
                      'Ghi chép, trả lời và đề xuất cho bạn',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: pal.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Trợ lý đã học được gì',
                onPressed: () => openAssistantMemory(context),
                icon: const Icon(
                  Symbols.psychology_rounded,
                  color: MomaColors.emerald,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Giọng nói',
                icon: Icon(Symbols.more_vert_rounded, color: pal.muted),
                onSelected: (v) {
                  final n = ref.read(voicePrefsProvider.notifier);
                  if (v == 'send') n.setAutoSend(!voice.autoSend);
                  if (v == 'read') n.setAutoRead(!voice.autoRead);
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'send',
                    checked: voice.autoSend,
                    child: const Text('Tự gửi sau khi nói'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'read',
                    checked: voice.autoRead,
                    child: const Text('Tự đọc câu trả lời'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome({required this.onPick});
  final void Function(String) onPick;

  static const _chips = [
    (Symbols.restaurant_rounded, 'Hôm nay ăn tối 200k'),
    (Symbols.payments_rounded, 'Nhận lương 15 triệu'),
    (Symbols.handshake_rounded, 'Nam mượn tôi 500k'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = context.pal;
    final name = callName(ref.watch(profileProvider).value);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: pal.lineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _AssistantAvatar(size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Chào $name',
                      style: TextStyle(
                        color: pal.ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Mình là Trợ lý tài chính của MoMa. Bạn cứ nói tự nhiên hoặc gửi ảnh hóa đơn, mình sẽ ghi thu chi, chuyển khoản, cho vay, thu nợ, đặt ngân sách và trả lời số liệu giúp bạn.',
                style: TextStyle(color: pal.ink, fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 16),
              Text(
                'Bạn có thể thử:',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: pal.muted,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _chips)
                    Material(
                      color: pal.tintSoft,
                      shape: StadiumBorder(side: BorderSide(color: pal.tint)),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: () => onPick(c.$2),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(c.$1, size: 17, color: MomaColors.emerald),
                              const SizedBox(width: 6),
                              Text(
                                c.$2,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                  color: pal.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.turn});
  final _Turn turn;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final image = turn.image;
    final caption = image != null && turn.text.startsWith(_photoPrefix)
        ? turn.text.substring(_photoPrefix.length)
        : turn.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            padding: image != null
                ? const EdgeInsets.all(4)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: MomaColors.emerald,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: image == null
                ? Text(
                    turn.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      height: 1.4,
                    ),
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.memory(
                            image,
                            width: 212,
                            height: 180,
                            fit: BoxFit.cover,
                            cacheWidth: 424,
                            gaplessPlayback: true,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Ảnh hóa đơn/chuyển khoản',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                caption,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _hhmm(turn.at),
                  style: TextStyle(fontSize: 11, color: pal.hint),
                ),
                if (turn.delivered) ...[
                  const SizedBox(width: 3),
                  const Icon(
                    Symbols.done_all_rounded,
                    size: 14,
                    color: MomaColors.emerald,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Staged "thinking" bubble: the status line advances through the stages (and stays on the last one) with a
/// soft shimmer and typing dots, until the agent's reply replaces it.
class _Thinking extends StatefulWidget {
  const _Thinking();
  static const stages = [
    'Đang đọc yêu cầu…',
    'Đang xem dữ liệu của bạn…',
    'Đang thực hiện…',
  ];
  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();
  Timer? _timer;
  int _stage = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1200), (t) {
      if (_stage >= _Thinking.stages.length - 1) {
        t.cancel();
        return;
      }
      setState(() => _stage++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AssistantAvatar(),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: pal.bubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
              ),
              child: AnimatedBuilder(
                animation: _anim,
                builder: (context, _) {
                  final v = _anim.value;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Opacity(
                            opacity:
                                0.3 +
                                0.7 *
                                    (0.5 +
                                        0.5 *
                                            math.sin(
                                              (v - i * 0.18) * 2 * math.pi,
                                            )),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: MomaColors.emerald,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: ShaderMask(
                            key: ValueKey(_stage),
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (r) => LinearGradient(
                              colors: [
                                pal.muted,
                                MomaColors.emerald,
                                pal.muted,
                              ],
                              stops: const [0, 0.5, 1],
                              begin: Alignment(-3 + 4 * v, 0),
                              end: Alignment(-1 + 4 * v, 0),
                            ).createShader(r),
                            child: Text(
                              _Thinking.stages[_stage],
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTurn extends StatelessWidget {
  const _AgentTurn({
    required this.turn,
    required this.speaking,
    required this.onSpeak,
    required this.onRun,
    required this.onUndo,
    required this.onRunAll,
    required this.onSkip,
    required this.onChoose,
  });
  final _Turn turn;

  /// A quick answer of a CHOICES card was tapped.
  final Future<void> Function(Map<String, dynamic>) onChoose;

  /// This reply is being read aloud ("Đọc" shows "Dừng").
  final bool speaking;
  final VoidCallback onSpeak;
  final Future<void> Function(_Step) onRun;
  final Future<void> Function(_Step) onUndo;
  final Future<void> Function() onRunAll;
  final void Function(_Step) onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final pending = turn.steps
        .where((s) => s.isCommand && s.status == _St.pending)
        .length;
    const bubbleShape = BorderRadius.only(
      topLeft: Radius.circular(6),
      topRight: Radius.circular(18),
      bottomLeft: Radius.circular(18),
      bottomRight: Radius.circular(18),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AssistantAvatar(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (turn.reply.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, right: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: pal.bubble,
                        borderRadius: bubbleShape,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              turn.reply,
                              style: TextStyle(
                                fontSize: 14.5,
                                height: 1.4,
                                color: pal.ink,
                              ),
                            ),
                          ),
                          InkResponse(
                            radius: 18,
                            onTap: () async {
                              await Clipboard.setData(
                                ClipboardData(text: turn.reply),
                              );
                              if (context.mounted) {
                                showSnack(context, 'Đã sao chép');
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8, top: 2),
                              child: Icon(
                                Symbols.content_copy_rounded,
                                size: 16,
                                color: pal.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final s in turn.steps)
                  if (s.type == 'ASK')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, right: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: pal.bubble,
                          borderRadius: bubbleShape,
                        ),
                        child: Text(
                          '${s.json['question']}',
                          style: TextStyle(
                            fontSize: 14.5,
                            height: 1.4,
                            color: pal.ink,
                          ),
                        ),
                      ),
                    )
                  else if (s.type == 'ANSWER')
                    _AnswerCard(json: s.json)
                  else if (s.type == 'CHOICES')
                    ChoicesCard(json: s.json, onChoose: onChoose)
                  else if (s.type == 'REMIND')
                    RemindActionCard(json: s.json)
                  else
                    _ActionCard(
                      step: s,
                      onRun: onRun,
                      onUndo: onUndo,
                      onSkip: onSkip,
                    ),
                if (pending > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton(
                      onPressed: onRunAll,
                      child: Text('Xác nhận tất cả ($pending)'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Row(
                    children: [
                      Text(
                        _hhmm(turn.at),
                        style: TextStyle(fontSize: 11, color: pal.hint),
                      ),
                      if (_spoken(turn).isNotEmpty) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: onSpeak,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  speaking
                                      ? Symbols.stop_circle_rounded
                                      : Symbols.volume_up_rounded,
                                  size: 15,
                                  color: MomaColors.emerald,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  speaking ? 'Dừng' : 'Đọc',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: MomaColors.emerald,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconFor(String commandType) => switch (commandType) {
  'TX_CREATE' => Symbols.receipt_long_rounded,
  'TX_REVERSE' => Symbols.undo_rounded,
  'DEBT_CREATE' || 'DEBT_REPAY' => Symbols.handshake_rounded,
  'GOAL_CREATE' || 'GOAL_ALLOCATE' => Symbols.savings_rounded,
  'BUDGET_UPSERT' => Symbols.pie_chart_rounded,
  'RECURRING_UPSERT' => Symbols.event_repeat_rounded,
  'ACCOUNT_CREATE' => Symbols.account_balance_wallet_rounded,
  'SPLIT_APPLY' || 'RECURRING_SPLIT_UPSERT' => Symbols.call_split_rounded,
  'TX_ANNOTATE' => Symbols.edit_note_rounded,
  'CALL' => Symbols.psychology_rounded,
  _ => Symbols.bolt_rounded,
};

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.step,
    required this.onRun,
    required this.onUndo,
    required this.onSkip,
  });
  final _Step step;
  final Future<void> Function(_Step) onRun;
  final Future<void> Function(_Step) onUndo;
  final void Function(_Step) onSkip;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final done = step.status == _St.done;
    final failed = step.status == _St.failed;
    final c = failed
        ? MomaColors.expense
        : (done ? MomaColors.income : MomaColors.emerald);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: failed
              ? MomaColors.expense.withValues(alpha: 0.5)
              : pal.lineSoft,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CategoryAvatar(
                iconData: _iconFor(step.commandType),
                color: c,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: pal.ink,
                        decoration: step.undone || step.status == _St.skipped
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    for (final l in step.lines)
                      Text(
                        l,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: pal.muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (step.status == _St.running)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: MomaColors.emerald,
                  ),
                )
              else if (done && !step.undone)
                const Icon(
                  Symbols.check_circle_rounded,
                  color: MomaColors.income,
                  fill: 1,
                )
              else if (step.undone)
                Text(
                  'Đã hoàn tác',
                  style: TextStyle(fontSize: 12, color: pal.muted),
                ),
            ],
          ),
          if (failed && step.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                step.error!,
                style: const TextStyle(
                  color: MomaColors.expense,
                  fontSize: 12.5,
                ),
              ),
            ),
          if (step.status == _St.pending || failed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => onSkip(step),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42),
                      ),
                      child: const Text('Bỏ qua'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => onRun(step),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                      ),
                      child: Text(failed ? 'Thử lại' : 'Xác nhận'),
                    ),
                  ),
                ],
              ),
            ),
          if (done && step.undoable && !step.undone)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => onUndo(step),
                child: const Text('Hoàn tác'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.json});
  final Map<String, dynamic> json;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final what = '${json['what']}';
    final data = json['data'];
    final rows = <(String, String, Color?)>[];
    var title = 'Số liệu';
    try {
      switch (what) {
        case 'BALANCES':
          title = 'Số dư các tài khoản';
          for (final a in (data as List)) {
            final m = a as Map;
            rows.add((
              '${m['name']}',
              m['balance'] == null
                  ? 'Chưa biết'
                  : formatVnd(parseVnd('${m['balance']}')),
              null,
            ));
          }
        case 'RECENT':
          title = 'Giao dịch gần đây';
          for (final t in (data as List)) {
            final tx = MomaTx.fromJson(Map<String, dynamic>.from(t as Map));
            rows.add((
              tx.merchant?.isNotEmpty == true
                  ? tx.merchant!
                  : (tx.note ?? 'Giao dịch'),
              '${tx.isIncome
                  ? '+'
                  : tx.isExpense
                  ? '-'
                  : ''}${formatVnd(tx.amount)}',
              tx.isIncome
                  ? MomaColors.income
                  : (tx.isExpense ? MomaColors.expense : null),
            ));
          }
        case 'DEBTS':
          title = 'Công nợ đang mở';
          for (final d in (data as List)) {
            final m = d as Map;
            rows.add((
              '${m['direction'] == 'RECEIVABLE' ? 'Phải thu' : 'Phải trả'} ${m['contact_alias']}',
              formatVnd(parseVnd('${m['remaining']}')),
              null,
            ));
          }
        case 'BUDGETS':
          title = 'Ngân sách tháng';
          for (final b in (data as List)) {
            final m = b as Map;
            rows.add((
              '${m['category_name'] ?? 'Tổng'}',
              'Còn ${formatVnd(parseVnd('${m['remaining']}'))}',
              null,
            ));
          }
        case 'PLANS':
          title = 'Kế hoạch & dự toán';
          final m = data as Map;
          for (final e in (m['events'] as List? ?? const [])) {
            final ev = e as Map;
            rows.add((
              '${ev['title']}',
              ev['actual'] != null
                  ? 'Thực tế ${formatVnd((ev['actual'] as num).round())} / ~${formatVnd((ev['estimate'] as num).round())}'
                  : '~${formatVnd((ev['estimate'] as num).round())}',
              null,
            ));
          }
          for (final l in (m['life'] as List? ?? const [])) {
            final lp = l as Map;
            final ym = lp['reach_month'] as String?;
            rows.add((
              '${lp['name']}',
              ym == null
                  ? 'Chưa đủ tích lũy'
                  : '~T${int.parse(ym.substring(5))}/${ym.substring(0, 4)}',
              null,
            ));
          }
          if (rows.isEmpty) rows.add(('Chưa có kế hoạch nào', '', null));
        case 'GOALS':
          title = 'Mục tiêu tiết kiệm';
          for (final g
              in (data as Map)['goals'] == null
                  ? (data as List)
                  : ((data)['goals'] as List)) {
            final m = g as Map;
            rows.add((
              '${m['name']}',
              '${formatVnd(parseVnd('${m['allocated']}'))} / ${formatVnd(parseVnd('${m['target']}'))}',
              null,
            ));
          }
        default:
          final s = Summary.fromJson(Map<String, dynamic>.from(data as Map));
          final mm = '${json['month']}';
          title = 'Tháng ${mm.substring(5)}/${mm.substring(0, 4)}';
          rows
            ..add(('Thu nhập', '+${formatVnd(s.income)}', MomaColors.income))
            ..add(('Chi tiêu', '-${formatVnd(s.expense)}', MomaColors.expense))
            ..add(('Tài sản ròng', formatVnd(s.netWorth), null));
      }
    } on Object {
      rows.add(('Không đọc được dữ liệu', '', null));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: pal.ink,
            ),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text('Chưa có dữ liệu.', style: TextStyle(color: pal.muted)),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.$1,
                      style: TextStyle(fontSize: 14, color: pal.muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    r.$2,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: r.$3 ?? pal.ink,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Số liệu do hệ thống tính từ sổ cái.',
            style: TextStyle(fontSize: 11.5, color: pal.muted),
          ),
        ],
      ),
    );
  }
}
