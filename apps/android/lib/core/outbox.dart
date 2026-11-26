import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'network/api_client.dart';
import 'providers.dart';

/// A command that could not reach the server. The command id is fixed, so retrying can never double-post.
class PendingCommand {
  PendingCommand({
    required this.commandId,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.error,
  });
  factory PendingCommand.fromJson(Map<String, dynamic> j) => PendingCommand(
    commandId: j['id'] as String,
    type: j['type'] as String,
    payload: (j['payload'] as Map<String, dynamic>),
    createdAt: DateTime.parse(j['at'] as String),
    error: j['error'] as String?,
  );
  final String commandId;
  final String type;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  /// Set when the server rejected the command for good (needs the owner's decision, never silently dropped).
  final String? error;

  Map<String, dynamic> toJson() => {
    'id': commandId,
    'type': type,
    'payload': payload,
    'at': createdAt.toIso8601String(),
    'error': error,
  };

  PendingCommand withError(String message) => PendingCommand(
    commandId: commandId,
    type: type,
    payload: payload,
    createdAt: createdAt,
    error: message,
  );
}

/// Durable storage in the Android Keystore-backed secure storage.
class OutboxStore {
  OutboxStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'outbox_v1';
  static const maxItems = 200;

  Future<List<PendingCommand>> load() async {
    final raw = await _s.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => PendingCommand.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(List<PendingCommand> items) => _s.write(
    key: _key,
    value: jsonEncode(items.map((e) => e.toJson()).toList()),
  );
}

final outboxStoreProvider = Provider<OutboxStore>((_) => OutboxStore());

class OutboxState {
  const OutboxState({this.items = const [], this.syncing = false});
  final List<PendingCommand> items;
  final bool syncing;
  int get waiting => items.where((e) => e.error == null).length;
  int get failed => items.where((e) => e.error != null).length;
}

class OutboxController extends Notifier<OutboxState> {
  @override
  OutboxState build() => const OutboxState();

  Future<void> load() async {
    state = OutboxState(items: await ref.read(outboxStoreProvider).load());
  }

  Future<bool> add(
    String type,
    Map<String, dynamic> payload,
    String commandId,
  ) async {
    if (state.items.length >= OutboxStore.maxItems) return false;
    final items = [
      ...state.items,
      PendingCommand(
        commandId: commandId,
        type: type,
        payload: payload,
        createdAt: DateTime.now(),
      ),
    ];
    await ref.read(outboxStoreProvider).save(items);
    state = OutboxState(items: items);
    return true;
  }

  Future<void> discard(String commandId) async {
    final items = state.items.where((e) => e.commandId != commandId).toList();
    await ref.read(outboxStoreProvider).save(items);
    state = OutboxState(items: items);
  }

  /// Sends queued commands oldest first. Stops at the first retryable failure (still offline).
  Future<int> flush() async {
    if (state.syncing) return 0;
    state = OutboxState(items: state.items, syncing: true);
    final api = ref.read(apiProvider);
    var sent = 0;
    var items = [...state.items];
    for (final cmd in state.items.where((e) => e.error == null)) {
      try {
        await api.command(cmd.type, cmd.payload, commandId: cmd.commandId);
        items.removeWhere((e) => e.commandId == cmd.commandId);
        sent++;
      } on ApiException catch (e) {
        if (e.retryable) break;
        final i = items.indexWhere((x) => x.commandId == cmd.commandId);
        if (i >= 0) items[i] = items[i].withError(e.message);
      }
    }
    await ref.read(outboxStoreProvider).save(items);
    state = OutboxState(items: items);
    if (sent > 0) {
      ref.invalidate(accountsProvider);
      ref.invalidate(summaryProvider);
      ref.invalidate(transactionsProvider);
    }
    return sent;
  }
}

final outboxProvider = NotifierProvider<OutboxController, OutboxState>(
  OutboxController.new,
);
