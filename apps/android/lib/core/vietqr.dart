// VietQR (NAPAS 247) payload builder: same output as the API (apps/api/src/modules/bank/vietqr.ts), so the app can
// make an amount QR offline from a cached plain QR of the linked account.

String _tlv(String id, String value) =>
    '$id${value.length.toString().padLeft(2, '0')}$value';

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), EMVCo tag 63.
String vietQrCrc16(String s) {
  var crc = 0xffff;
  for (final c in s.codeUnits) {
    crc ^= (c << 8) & 0xffff;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xffff
          : (crc << 1) & 0xffff;
    }
  }
  return crc.toRadixString(16).toUpperCase().padLeft(4, '0');
}

const _fold = {
  'àáảãạăằắẳẵặâầấẩẫậ': 'a',
  'èéẻẽẹêềếểễệ': 'e',
  'ìíỉĩị': 'i',
  'òóỏõọôồốổỗộơờớởỡợ': 'o',
  'ùúủũụưừứửữự': 'u',
  'ỳýỷỹỵ': 'y',
  'đ': 'd',
};

/// ASCII-only note as banking apps expect (no diacritics, letters/digits/space/basic marks, max 50).
String vietQrNote(String note) {
  final b = StringBuffer();
  for (final ch in note.split('')) {
    final lower = ch.toLowerCase();
    String out = ch;
    for (final e in _fold.entries) {
      if (e.key.contains(lower)) {
        out = ch == lower ? e.value : e.value.toUpperCase();
        break;
      }
    }
    if (RegExp(r'[A-Za-z0-9 .,\-_/]').hasMatch(out)) b.write(out);
  }
  final s = b.toString().trim();
  return s.length > 50 ? s.substring(0, 50) : s;
}

String vietQrPayload({
  required String bin,
  required String accountNumber,
  int? amount,
  String? note,
}) {
  if (!RegExp(r'^\d{6}$').hasMatch(bin)) throw ArgumentError('INVALID_BIN');
  if (!RegExp(r'^[0-9A-Za-z]{3,19}$').hasMatch(accountNumber)) {
    throw ArgumentError('INVALID_ACCOUNT');
  }
  final amt = amount != null && amount > 0 && amount <= 999999999999
      ? '$amount'
      : null;
  final merchant =
      _tlv('00', 'A000000727') +
      _tlv('01', _tlv('00', bin) + _tlv('01', accountNumber)) +
      _tlv('02', 'QRIBFTTA');
  final n = note == null ? '' : vietQrNote(note);
  final body =
      '${_tlv('00', '01')}${_tlv('01', amt != null ? '12' : '11')}${_tlv('38', merchant)}${_tlv('53', '704')}'
      '${amt != null ? _tlv('54', amt) : ''}${_tlv('58', 'VN')}${n.isNotEmpty ? _tlv('62', _tlv('08', n)) : ''}6304';
  return body + vietQrCrc16(body);
}

Map<String, String> _parse(String s) {
  final out = <String, String>{};
  var i = 0;
  while (i + 4 <= s.length) {
    final tag = s.substring(i, i + 2);
    final len = int.tryParse(s.substring(i + 2, i + 4));
    if (len == null || i + 4 + len > s.length) break;
    out[tag] = s.substring(i + 4, i + 4 + len);
    i += 4 + len;
  }
  return out;
}

/// Bank BIN and account number inside a VietQR payload (tag 38 -> 01 -> 00/01), or null.
({String bin, String account})? vietQrTarget(String payload) {
  final m = _parse(payload)['38'];
  if (m == null) return null;
  final inner = _parse(m)['01'];
  if (inner == null) return null;
  final t = _parse(inner);
  final bin = t['00'];
  final acc = t['01'];
  if (bin == null || acc == null) return null;
  return (bin: bin, account: acc);
}

/// Rebuilds [payload] (a plain or amount QR of the same account) with a new amount and note, fully offline.
String? vietQrWithAmount(String payload, {int? amount, String? note}) {
  final t = vietQrTarget(payload);
  if (t == null) return null;
  try {
    return vietQrPayload(
      bin: t.bin,
      accountNumber: t.account,
      amount: amount,
      note: note,
    );
  } on ArgumentError {
    return null;
  }
}
