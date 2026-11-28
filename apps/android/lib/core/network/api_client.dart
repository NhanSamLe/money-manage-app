import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../storage/local_store.dart';

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
  ApiClient(this._store, {http.Client? client})
    : _http = client ?? http.Client();
  final LocalStore _store;
  final http.Client _http;
  static const _timeout = Duration(seconds: 15);

  Future<Map<String, String>> _headers({String? idempotencyKey}) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final bearer = token == null ? null : 'Bearer $token';
    return {
      'content-type': 'application/json',
      'authorization': ?bearer,
      'x-device-id': await _store.deviceId(),
      'idempotency-key': ?idempotencyKey,
    };
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final uri = Uri.parse('${await _store.apiBase()}$path')
        .replace(queryParameters: query);
    final headers = await _headers();
    return _decode(await _send(() => _http.get(uri, headers: headers)));
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
    return res as Map<String, dynamic>;
  }

  static String newId() => const Uuid().v4();

  Future<String> deviceIdForRegistration() => _store.deviceId();

  Future<http.Response> _send(
    Future<http.Response> Function() call, {
    Duration timeout = _timeout,
  }) async {
    try {
      return await call().timeout(timeout);
    } on Exception {
      throw ApiException(
        'OFFLINE',
        'Không kết nối được máy chủ. Hãy kiểm tra mạng và thử lại.',
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
