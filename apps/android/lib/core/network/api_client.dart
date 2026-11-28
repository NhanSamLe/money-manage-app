import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../storage/local_store.dart';
import '../storage/offline_cache.dart';

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.retryable = false});
  final String code;
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

/// Thin HTTP client for the MoMa API. Business rules live on the server/database, not here.
class ApiClient {
  ApiClient(this._store, {http.Client? client, OfflineCache? cache})
    : _http = client ?? http.Client(),
      _cache = cache ?? OfflineCache.instance;
  final LocalStore _store;
  final http.Client _http;
  final OfflineCache? _cache;
  static const _timeout = Duration(seconds: 15);

  Future<Map<String, String>> _headers({String? idempotencyKey}) async {
    String? token;
    try {
      token = Supabase.instance.client.auth.currentSession?.accessToken;
    } catch (_) {
      token = null; // Supabase not initialised (tests, a background engine before init)
    }
    final bearer = token == null ? null : 'Bearer $token';
    return {
      'content-type': 'application/json',
      'authorization': ?bearer,
      'x-device-id': await _store.deviceId(),
      'idempotency-key': ?idempotencyKey,
    };
  }

  /// Reads go network first and fall back to the last saved copy when there is no connection (D-021); a few
  /// rarely-changing endpoints are reused from the cache for a while without any request.
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final cache = _cache;
    final cacheable = cache != null && OfflineCache.cacheable(path);
    final key = OfflineCache.keyFor(path, query);
    if (cacheable) {
      final fresh = await cache.fresh(path, key);
      if (fresh != null) return fresh.data;
    }
    final uri = Uri.parse('${await _store.apiBase()}$path')
        .replace(queryParameters: query);
    final headers = await _headers();
    final http.Response res;
    try {
      res = await _send(() => _http.get(uri, headers: headers));
    } on ApiException catch (e) {
      if (e.code == 'OFFLINE') {
        final saved = cacheable ? await cache.read(key) : null;
        if (saved != null) NetStatus.wentOffline(dataAt: saved.at);
        if (saved != null) return saved.data;
      }
      rethrow;
    }
    final data = _decode(res);
    if (cacheable) await cache.write(key, data);
    return data;
  }

  Future<dynamic> post(
    String path,
    Object body, {
    String? idempotencyKey,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = Uri.parse('${await _store.apiBase()}$path');
    final headers = {
      ...await _headers(idempotencyKey: idempotencyKey),
      ...?extraHeaders,
    };
    return _decode(
      await _send(
        () => _http.post(uri, headers: headers, body: jsonEncode(body)),
      ),
    );
  }

  Future<dynamic> put(String path, Object body) async {
    final uri = Uri.parse('${await _store.apiBase()}$path');
    final headers = await _headers();
    return _decode(
      await _send(
        () => _http.put(uri, headers: headers, body: jsonEncode(body)),
      ),
    );
  }

  Future<dynamic> delete(String path) async {
    final uri = Uri.parse('${await _store.apiBase()}$path');
    final headers = await _headers();
    return _decode(await _send(() => _http.delete(uri, headers: headers)));
  }

  /// Uploads raw bytes (a compressed photo) as the request body; returns the decoded `data`.
  Future<dynamic> postBytes(
    String path,
    List<int> bytes, {
    String contentType = 'image/jpeg',
  }) async {
    final uri = Uri.parse('${await _store.apiBase()}$path');
    final headers = {...await _headers(), 'content-type': contentType};
    return _decode(
      await _send(
        () => _http.post(uri, headers: headers, body: bytes),
        timeout: const Duration(seconds: 60),
      ),
    );
  }

  /// Downloads a binary resource (an attachment picture). Errors come back as [ApiException] like JSON calls.
  Future<List<int>> getBytes(String path) async {
    final uri = Uri.parse('${await _store.apiBase()}$path');
    final headers = await _headers();
    final res = await _send(
      () => _http.get(uri, headers: headers),
      timeout: const Duration(seconds: 60),
    );
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    _decode(res);
    throw ApiException('UNKNOWN', 'Có lỗi không xác định (${res.statusCode}).');
  }

  /// Sends one command. The caller owns [commandId] so a retry after a lost response reuses the same id.
  Future<Map<String, dynamic>> command(
    String type,
    Map<String, dynamic> payload, {
    required String commandId,
  }) async {
    final res = await post('/commands', {
      'command_id': commandId,
      'command_type': type,
      'schema_version': 1,
      'payload': payload,
    }, idempotencyKey: commandId);
    // Balances, lists... may all have changed: the next reads ask the server instead of the cache.
    _cache?.invalidate();
    return res as Map<String, dynamic>;
  }

  static String newId() => const Uuid().v4();

  Future<String> deviceIdForRegistration() => _store.deviceId();

  Future<http.Response> _send(
    Future<http.Response> Function() call, {
    Duration timeout = _timeout,
  }) async {
    try {
      final res = await call().timeout(timeout);
      if (res.statusCode < 500) NetStatus.online();
      return res;
    } on Exception {
      NetStatus.wentOffline();
      throw ApiException(
        'OFFLINE',
        'Đang offline: thao tác này cần mạng. MoMa sẽ dùng được ngay khi có kết nối.',
        retryable: true,
      );
    }
  }

  dynamic _decode(http.Response res) {
    final Object? body = res.body.isEmpty
        ? null
        : jsonDecode(utf8.decode(res.bodyBytes));
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    if (ok && body is Map<String, dynamic>) {
      return body['data'];
    }
    if (body is Map<String, dynamic> && body['error'] is Map<String, dynamic>) {
      final e = body['error'] as Map<String, dynamic>;
      throw ApiException(
        '${e['code']}',
        '${e['message']}',
        retryable: e['retryable'] == true,
      );
    }
    throw ApiException('UNKNOWN', 'Có lỗi không xác định (${res.statusCode}).');
  }
}
