import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Length of the app-lock PIN.
const pinLength = 6;

/// PBKDF2-HMAC-SHA256 (RFC 8018) with one 32-byte output block.
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  final first = BytesBuilder(copy: false)
    ..add(salt)
    ..add(const [0, 0, 0, 1]);
  var u = hmac.convert(first.takeBytes()).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// Hashes and verifies the app-lock PIN. Only the salted hash is ever stored, encoded as
/// `pbkdf2-sha256$<iterations>$<salt b64>$<hash b64>` so the cost can be raised later without breaking old PINs.
class PinHasher {
  const PinHasher({this.iterations = 120000, this.offThread = true});

  final int iterations;

  /// Run the key derivation in a background isolate (tests run it inline).
  final bool offThread;

  static const _scheme = 'pbkdf2-sha256';

  Future<Uint8List> _derive(String pin, List<int> salt, int iter) {
    final p = utf8.encode(pin);
    if (!offThread) return Future.value(pbkdf2Sha256(p, salt, iter));
    return Isolate.run(() => pbkdf2Sha256(p, salt, iter));
  }

  Future<String> hash(String pin, {List<int>? salt}) async {
    final s = salt ?? _randomSalt();
    final h = await _derive(pin, s, iterations);
    return '$_scheme\$$iterations\$${base64Encode(s)}\$${base64Encode(h)}';
  }

  Future<bool> verify(String pin, String encoded) async {
    final parts = encoded.split(r'$');
    if (parts.length != 4 || parts[0] != _scheme) return false;
    final iter = int.tryParse(parts[1]);
    if (iter == null || iter < 1) return false;
    final List<int> salt;
    final List<int> expected;
    try {
      salt = base64Decode(parts[2]);
      expected = base64Decode(parts[3]);
    } on FormatException {
      return false;
    }
    final actual = await _derive(pin, salt, iter);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  static List<int> _randomSalt() {
    final r = Random.secure();
    return List<int>.generate(16, (_) => r.nextInt(256));
  }
}

/// Wrong-PIN throttling: every [freeAttempts] wrong tries in a row the user waits a fixed [cooldown], then gets
/// another [freeAttempts] tries.
class AttemptPolicy {
  static const freeAttempts = 5;
  static const cooldown = Duration(seconds: 10);

  /// Wait imposed right after the given number of consecutive failures, or null when the user may retry now.
  static Duration? cooldownAfter(int failures) =>
      failures > 0 && failures % freeAttempts == 0 ? cooldown : null;

  /// Tries left before the next wait.
  static int remaining(int failures) => freeAttempts - failures % freeAttempts;
}
