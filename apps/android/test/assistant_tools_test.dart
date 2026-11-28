import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:moma/core/providers.dart';
import 'package:moma/features/assistant/assistant_page.dart';
import 'package:moma/features/assistant/routine_chips.dart';
import 'package:moma/features/voice/speech_service.dart';
import 'package:moma/features/voice/tts_service.dart';

import 'support/fake_api.dart';

class _NoSpeech implements SpeechService {
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<bool> initialize({
    required void Function(String code, bool permanent) onError,
    required void Function(String status) onStatus,
  }) async => false;
  @override
  Future<List<String>> localeIds() async => const [];
  @override
  Future<String?> systemLocaleId() async => null;
  @override
  Future<void> listen({
    String? localeId,
    required void Function(String words, bool isFinal) onResult,
    void Function(double level)? onLevel,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

class _NoTts implements TtsService {
  @override
  VoidCallback? onDone;
  @override
  Future<TtsOutcome> speak(String text) async => TtsOutcome.ok;
  @override
  Future<void> stop() async {}
}

/// Scripted server: agent replies in order, commands answered with ids, everything recorded.
class _ScriptApi extends FakeApi {
  _ScriptApi(this.replies, {this.routine});
  final List<Map<String, dynamic>> replies;
  final Map<String, dynamic>? routine;
  final agentBodies = <Map<String, dynamic>>[];
  final posts = <(String, Map<String, dynamic>)>[];

  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/ai/routine') return routine ?? {'slot': null, 'options': []};
    return super.get(path, query: query);
  }

  @override
  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    final b = (body as Map).cast<String, dynamic>();
    if (path == '/ai/agent') {
      agentBodies.add(b);
      return replies.removeAt(0);
    }
    posts.add((path, b));
    if (path == '/ai/routine/record') {
      return {
        'message': 'Đã ghi Bánh mì 20.000đ',
        'recorded': [
          {
            'tx_id': 'tx-r',
            'command_id': 'cmd-r',
            'undo': {
              'ops': [
                {'op': 'REVERSE_TX', 'tx_id': 'tx-r'},
              ],
            },
          },
        ],
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    commands.add((type: type, payload: payload, id: commandId));
    return switch (type) {
      'TX_CREATE' => {'status': 'COMMITTED', 'tx_id': 'tx-bill'},
      'SPLIT_APPLY' => {
        'status': 'COMMITTED',
        'tx_id': payload['tx_id'],
        'application_id': 'app-1',
      },
      _ => {'status': 'COMMITTED'},
    };
  }
}

Future<void> _open(WidgetTester tester, _ScriptApi api) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(api),
        speechServiceProvider.overrideWithValue(_NoSpeech()),
        ttsServiceProvider.overrideWithValue(_NoTts()),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(body: AssistantPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pumpAndSettle();
}

const _choices = {
  'reply': 'Mình đọc được hóa đơn lẩu 849.000đ.',
  'actions': [
    {
      'id': 's1',
      'type': 'CHOICES',
      'question': 'Chia hóa đơn 849.000 ₫ cho ~3 người?',
      'reason': 'Hóa đơn ghi 3 khách → có vẻ đi 3 người.',
      'options': [
        {'label': 'Chia 3 với Nam, Lan', 'text': 'Chia hóa đơn với Nam, Lan'},
        {'label': 'Chọn người…', 'text': '', 'prefill': 'Chia với '},
        {'label': 'Không chia', 'text': 'Không chia, ghi cho mình tôi'},
      ],
      'items': [
        {'name': 'Lẩu thái', 'qty': 1, 'amount': 389000},
        {'name': 'Bia Tiger', 'qty': 6, 'amount': 150000},
      ],
    },
  ],
  'plan': [
    {'do': 'SPLIT_PENDING', 'amount': '849000', 'purpose': 'EATOUT'},
  ],
};

Map<String, dynamic> _splitReply() => {
  'reply': 'Đã chia hóa đơn.',
  'actions': [
    {
      'id': 's1',
      'type': 'COMMAND',
      'risk': 'low',
      'title': 'Chi 849.000 ₫',
      'lines': ['Ăn uống', 'VCB'],
      'command': {
        'command_type': 'TX_CREATE',
        'payload': {'kind': 'EXPENSE', 'amount': '849000'},
      },
      'undoable': true,
      'undo': {
        'ops': [
          {'op': 'REVERSE_TX', 'tx_id': r'$result.tx_id'},
        ],
      },
    },
    {
      'id': 's1b',
      'type': 'COMMAND',
      'risk': 'low',
      'title': 'Chia Lẩu Thái 849.000 ₫',
      'lines': ['Nam nợ bạn 285.000 ₫', 'Lan nợ bạn 285.000 ₫'],
      'command': {
        'command_type': 'SPLIT_APPLY',
        'payload': {
          'tx_id': r'$s1.tx_id',
          'shares': [
            {'name': 'Nam', 'amount': '285000'},
          ],
        },
      },
      'undoable': true,
      'undo': {
        'ops': [
          {'op': 'SPLIT_UNDO', 'application_id': r'$result.application_id'},
        ],
        'habit': {'kind': 'HABIT', 'key': 'chia bill lan nam'},
      },
    },
  ],
  'plan': [
    {'do': 'SPLIT', 'amount': '849000'},
  ],
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('step refs and undo results are filled from executed steps', () {
    expect(
      fillStepRefs('{"tx_id":"\$s1.tx_id","x":"\$s2b.debt_id"}', {
        's1': {'tx_id': 'T1'},
        's2b': {'debt_id': 'D2'},
      }),
      '{"tx_id":"T1","x":"D2"}',
    );
    expect(
      fillUndoOps(
        [
          {'op': 'CANCEL_DEBT', 'debt_id': r'$result.debt_id'},
        ],
        {'debt_id': 'D9'},
      ),
      [
        {'op': 'CANCEL_DEBT', 'debt_id': 'D9'},
      ],
    );
  });

  testWidgets(
    'split question -> tap the learned group -> expense + split run with the real tx id -> Hoàn tác',
    (tester) async {
      final api = _ScriptApi([
        Map<String, dynamic>.from(_choices),
        _splitReply(),
      ]);
      await _open(tester, api);
      await _say(tester, 'Ảnh hóa đơn/chuyển khoản:\nQUÁN LẨU THÁI');

      expect(find.text('Chia hóa đơn 849.000 ₫ cho ~3 người?'), findsOneWidget);
      expect(find.textContaining('3 khách'), findsOneWidget);
      await tester.tap(find.text('Xem các món (2) · chia theo món'));
      await tester.pumpAndSettle();
      expect(find.text('6 × Bia Tiger · 150000đ'), findsOneWidget);

      await tester.tap(find.text('Chia 3 với Nam, Lan'));
      await tester.pumpAndSettle();

      // The answer continues the same task: the pending split goes back as "waiting for the owner".
      final second = api.agentBodies[1];
      expect(second['text'], 'Chia hóa đơn với Nam, Lan');
      final prev = (second['previous'] as Map)['steps'] as List;
      expect((prev.first as Map)['do'], 'SPLIT_PENDING');
      expect((prev.first as Map)['status'], 'ASKED');

      // Low-risk steps ran by themselves; the split used the bill's tx id from step s1.
      expect(api.commands.map((c) => c.type), ['TX_CREATE', 'SPLIT_APPLY']);
      expect(api.commands[1].payload['tx_id'], 'tx-bill');

      final undo = find.text('Hoàn tác');
      expect(undo, findsNWidgets(2));
      await tester.tap(undo.last);
      await tester.pumpAndSettle();
      final post = api.posts.firstWhere((p) => p.$1 == '/ai/undo').$2;
      expect(post['ops'], [
        {'op': 'SPLIT_UNDO', 'application_id': 'app-1'},
      ]);
      expect(post['habit'], {'kind': 'HABIT', 'key': 'chia bill lan nam'});
      expect(find.text('Đã hoàn tác'), findsOneWidget);
    },
  );

  testWidgets('"Chọn người…" pre-fills the input instead of sending', (
    tester,
  ) async {
    final api = _ScriptApi([Map<String, dynamic>.from(_choices)]);
    await _open(tester, api);
    await _say(tester, 'Ảnh hóa đơn/chuyển khoản:\nQUÁN LẨU THÁI');
    await tester.tap(find.text('Chọn người…'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Chia với ',
    );
    expect(api.agentBodies, hasLength(1));
  });

  testWidgets(
    'routine chips: one tap records the usual breakfast, with Hoàn tác',
    (tester) async {
      final api = _ScriptApi(
        [],
        routine: {
          'slot': 'breakfast',
          'question': 'Sáng nay bạn ăn gì?',
          'recorded': false,
          'options': [
            {'key': 'banh mi', 'label': 'Bánh mì', 'amount': 20000},
            {'key': 'ca phe sua', 'label': 'Cà phê sữa', 'amount': 25000},
          ],
        },
      );
      await _open(tester, api);
      expect(find.text('Sáng nay bạn ăn gì?'), findsOneWidget);
      expect(find.text('Bánh mì 20k'), findsOneWidget);
      expect(find.text('Cà phê sữa 25k'), findsOneWidget);
      await tester.tap(find.text('Bánh mì 20k'));
      await tester.pumpAndSettle();
      expect(api.posts.first.$1, '/ai/routine/record');
      expect(api.posts.first.$2, {
        'slot': 'breakfast',
        'keys': ['banh mi'],
      });
      expect(find.text('Đã ghi Bánh mì 20.000đ'), findsOneWidget);
      expect(find.text('Sáng nay bạn ăn gì?'), findsNothing);
      await tester.tap(find.text('Hoàn tác'));
      await tester.pumpAndSettle();
      expect(api.posts.last.$1, '/ai/undo');
      expect(api.posts.last.$2['step_command_id'], 'cmd-r');
    },
  );

  testWidgets('no routine learned (or offline): no chips, no error', (
    tester,
  ) async {
    await _open(tester, _ScriptApi([]));
    expect(find.byType(RoutineChips), findsOneWidget);
    expect(find.textContaining('bạn ăn gì'), findsNothing);
    expect(shortVnd(20000), '20k');
    expect(shortVnd(1600000), '1,6tr');
  });
}
