import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One cached API response (the decoded `data` of a GET), stored as JSON.
class CacheEntry {
  const CacheEntry(this.json, this.at);
  final String json;
  final DateTime at;
  Object? get data => jsonDecode(json);
}

/// Key/value storage behind [OfflineCache]. Rows are scoped by owner (Supabase user id).
abstract class KvStore {
  Future<CacheEntry?> read(String owner, String key);
  Future<void> write(String owner, String key, String json, DateTime at);
  Future<void> clear();
  Future<int> sizeBytes();
  Future<DateTime?> lastWrite(String owner);
}

class MemoryKvStore implements KvStore {
  final _rows = <String, CacheEntry>{};
  @override
  Future<CacheEntry?> read(String owner, String key) async =>
      _rows['$owner|$key'];
  @override
  Future<void> write(
    String owner,
    String key,
    String json,
    DateTime at,
  ) async => _rows['$owner|$key'] = CacheEntry(json, at);
  @override
  Future<void> clear() async => _rows.clear();
  @override
  Future<int> sizeBytes() async =>
      _rows.values.fold<int>(0, (s, e) => s + e.json.length);
  @override
  Future<DateTime?> lastWrite(String owner) async {
    DateTime? last;
    for (final e in _rows.entries) {
      if (!e.key.startsWith('$owner|')) continue;
      if (last == null || e.value.at.isAfter(last)) last = e.value.at;
    }
    return last;
  }
}

/// SQLite file `moma_cache.db` in the app's database folder. Opened lazily; any failure (no plugin in tests,
/// corrupt file) disables the cache instead of breaking the request that triggered it.
class SqliteKvStore implements KvStore {
  /// [_factory] / [_path]: tests pass the FFI factory and an in-memory path.
  SqliteKvStore([this._factory, this._path]);
  final DatabaseFactory? _factory;
  final String? _path;
  Future<Database?>? _db;
  String? _file;

  Future<Database?> _open() => _db ??= () async {
    try {
      final f = _factory ?? databaseFactory;
      final file = _path ?? p.join(await f.getDatabasesPath(), 'moma_cache.db');
      _file = file;
      return await f.openDatabase(
        file,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => db.execute(
            'create table api_cache (owner text not null, key text not null, json text not null, '
            'at integer not null, primary key (owner, key))',
          ),
        ),
      );
    } catch (e) {
      debugPrint('MoMa cache disabled: $e');
      return null;
    }
  }();

  @override
  Future<CacheEntry?> read(String owner, String key) async {
    final db = await _open();
    if (db == null) return null;
    final rows = await db.query(
      'api_cache',
      columns: ['json', 'at'],
      where: 'owner = ? and key = ?',
      whereArgs: [owner, key],
    );
    if (rows.isEmpty) return null;
    return CacheEntry(
      rows.first['json']! as String,
      DateTime.fromMillisecondsSinceEpoch(rows.first['at']! as int),
    );
  }

  @override
  Future<void> write(String owner, String key, String json, DateTime at) async {
    final db = await _open();
    if (db == null) return;
    await db.insert('api_cache', {
      'owner': owner,
      'key': key,
      'json': json,
      'at': at.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clear() async {
    final db = await _open();
    if (db == null) return;
    await db.delete('api_cache');
  }

  @override
  Future<int> sizeBytes() async {
    final db = await _open();
    if (db == null) return 0;
    final f = _file;
    if (f != null && f != inMemoryDatabasePath) {
      try {
        return await File(f).length();
      } catch (_) {}
    }
    final r = await db.rawQuery(
      'select coalesce(sum(length(json)), 0) as n from api_cache',
    );
    return (r.first['n'] as int?) ?? 0;
  }

  @override
  Future<DateTime?> lastWrite(String owner) async {
    final db = await _open();
    if (db == null) return null;
    final r = await db.rawQuery(
      'select max(at) as at from api_cache where owner = ?',
      [owner],
    );
    final at = r.first['at'] as int?;
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }
}

/// Online/offline state as seen by API calls: offline once a request fails for lack of network, online again
/// with the next success. [dataAt] = when the data now on screen was fetched (shown in the offline banner).
@immutable
class NetState {
  const NetState({this.offline = false, this.dataAt, this.lastOnline});
  final bool offline;
  final DateTime? dataAt;
  final DateTime? lastOnline;
}

class NetStatus {
  NetStatus._();
  static final notifier = ValueNotifier<NetState>(const NetState());
  static bool get offline => notifier.value.offline;

  /// Called after every reachable response: only notifies on a real change (offline → online) or once a minute,
  /// so screens watching the state do not rebuild on every request.
  static void online() {
    final cur = notifier.value;
    final now = DateTime.now();
    final last = cur.lastOnline;
    if (!cur.offline &&
        last != null &&
        now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    notifier.value = NetState(lastOnline: now);
  }

  static void wentOffline({DateTime? dataAt}) {
    final cur = notifier.value;
    DateTime? shown = cur.offline ? cur.dataAt : null;
    if (dataAt != null && (shown == null || dataAt.isBefore(shown))) {
      shown = dataAt; // the oldest data on screen is what matters
    }
    notifier.value = NetState(
      offline: true,
      dataAt: shown ?? cur.lastOnline,
      lastOnline: cur.lastOnline,
    );
  }

  @visibleForTesting
  static void reset() => notifier.value = const NetState();
}

/// Read cache for API GET responses: "có mạng thì dùng mạng, không thì dùng dữ liệu đã lưu" (D-021).
/// Rarely-changing endpoints are served from the cache for a while without any request.
class OfflineCache {
  OfflineCache(this._store, {String? Function()? owner})
    : _owner = owner ?? _supabaseOwner;

  static OfflineCache instance = OfflineCache(SqliteKvStore());

  final KvStore _store;
  final String? Function() _owner;

  /// Entries written before this moment are never used as "fresh" (set after every write command).
  DateTime _invalidatedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static String? _supabaseOwner() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  String? get owner => _owner();

  /// Paths never cached (auth/setup flows, health checks).
  static bool cacheable(String path) =>
      !path.startsWith('/auth') &&
      !path.startsWith('/setup') &&
      !path.startsWith('/health') &&
      !path.startsWith('/devices');

  /// How long a response is reused without asking the server. Null = always ask (network first).
  static Duration? freshFor(String path) {
    if (path == '/categories' || path == '/profile' || path == '/settings') {
      return const Duration(hours: 6);
    }
    if (path == '/banks/sepay/qr') return const Duration(hours: 6);
    if (path == '/banks/sepay/accounts' || path == '/banks/links') {
      return const Duration(minutes: 30);
    }
    return null;
  }

  static String keyFor(String path, Map<String, String>? query) {
    if (query == null || query.isEmpty) return path;
    final keys = query.keys.toList()..sort();
    return '$path?${keys.map((k) => '$k=${query[k]}').join('&')}';
  }

  Future<CacheEntry?> read(String key) async {
    final o = owner;
    if (o == null) return null;
    try {
      return await _store.read(o, key);
    } catch (_) {
      return null;
    }
  }

  /// Cached data that is still fresh for [path] (no request needed), or null.
  Future<CacheEntry?> fresh(String path, String key) async {
    final ttl = freshFor(path);
    if (ttl == null) return null;
    final e = await read(key);
    if (e == null) return null;
    if (!e.at.isAfter(_invalidatedAt)) return null;
    if (DateTime.now().difference(e.at) > ttl) return null;
    return e;
  }

  Future<void> write(String key, Object? data) async {
    final o = owner;
    if (o == null) return;
    try {
      await _store.write(o, key, jsonEncode(data), DateTime.now());
    } catch (_) {}
  }

  /// After a write command: every cached read may be outdated, ask the server next time.
  void invalidate() => _invalidatedAt = DateTime.now();

  Future<void> clear() async {
    try {
      await _store.clear();
    } catch (_) {}
  }

  Future<int> sizeBytes() async {
    try {
      return await _store.sizeBytes();
    } catch (_) {
      return 0;
    }
  }

  Future<DateTime?> lastSync() async {
    final o = owner;
    if (o == null) return null;
    try {
      return await _store.lastWrite(o);
    } catch (_) {
      return null;
    }
  }
}
