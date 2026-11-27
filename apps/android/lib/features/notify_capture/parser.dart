import '../../core/brands/brand_registry.dart' show brandFor, normalizeBrandKey;
import '../../core/quick_parse.dart' show foldVietnamese;

enum NotifyDirection { inflow, outflow }

/// What a bank / wallet notification says. [amount] is integer VND (always positive); null fields mean
/// "not found" and are never guessed.
class NotifyParse {
  const NotifyParse({
    required this.bank,
    this.direction,
    this.amount,
    this.balance,
    this.description,
    this.last4,
    this.txCode,
    this.counterparty,
    this.bankRef,
    this.postedAt,
    this.accountNumber,
  });
  final String bank;
  final NotifyDirection? direction;
  final int? amount;
  final int? balance;
  final String? description;

  /// Last 4 digits of the account ("TK 1234", "TK xx1234", "tai khoan ...1234"), when the text has them.
  final String? last4;

  /// Provider transaction code ("Mã giao dịch: 123456789"), when present.
  final String? txCode;

  /// Sender / receiver named in the title ("Nhận tiền chuyển khoản từ NGUYEN VAN A").
  final String? counterparty;

  /// Bank transfer reference inside the message ("FT26332327719412"), used to pair both legs of a transfer.
  final String? bankRef;

  /// Full account number when the text has it unmasked ("Số dư TK VCB 1026746096").
  final String? accountNumber;

  /// Time printed in the message ("28/11/26;03:08"), local time; null when absent.
  final DateTime? postedAt;

  /// Only a message with both an amount and a direction can become a transaction.
  bool get isTransaction => amount != null && amount! > 0 && direction != null;

  /// Signed amount (money in positive), 0 when not a transaction.
  int get signedAmount => !isTransaction
      ? 0
      : (direction == NotifyDirection.inflow ? amount! : -amount!);
}

/// Display name of the bank / wallet behind an Android package id.
const notifyBankNames = <String, String>{
  'com.VCB': 'Vietcombank',
  'vn.com.techcombank.bb.app': 'Techcombank',
  'com.mbmobile': 'MB Bank',
  'com.tpb.mb.gprsandroid': 'TPBank',
  'com.vnpay.bidv': 'BIDV',
  'com.vietinbank.ipay': 'VietinBank',
  'mobile.acb.com.vn': 'ACB',
  'com.vnpay.vpbankonline': 'VPBank',
  'com.sacombank.ewallet': 'Sacombank',
  'com.vnpay.Agribank3g': 'Agribank',
  'com.mservice.momotransfer': 'MoMo',
  'vn.com.vng.zalopay': 'ZaloPay',
  'com.beeasy.toppay': 'ShopeePay',
  'com.vib.myvib2': 'VIB',
  'com.vnpay.hdbank': 'HDBank',
  'vn.com.msb.smartBanking': 'MSB',
  'vn.com.ocb.awe': 'OCB',
  'xyz.be.cake': 'Cake',
  'vn.com.seabank.mb1': 'SeABank',
  'vn.shb.saha.mbanking': 'SHB',
  'vn.shb.mbanking': 'SHB',
  'com.vnpay.EximBankOmni': 'Eximbank',
  'io.lifestyle.plus': 'TNEX',
  'com.bplus.vtpay': 'Viettel Money',
  'vnptpay.vnptmedia.vnpt.com.vnptpay': 'VNPT Money',
  'vn.com.lpbank.digibank': 'LPBank',
  'vn.com.lpb.lienviet24h': 'LPBank',
  'vnpay.smartacccount': 'VNPAY',
};

/// Package of MoMo (also used for MoMo emails read from Gmail / Outlook).
const momoPackage = 'com.mservice.momotransfer';

String bankNameOf(String package) =>
    notifyBankNames[package] ??
    brandFor(package: package)?.shortName ??
    package;

/// Which bank / wallet a shared text or receipt screenshot comes from (by name in the text): wallets first, then
/// the longest bank name found. Null when none is named.
String? detectPackageFromText(String text) {
  final key = normalizeBrandKey(text);
  if (key.isEmpty) return null;
  const wallets = {
    'momo': momoPackage,
    'zalopay': 'vn.com.vng.zalopay',
    'shopeepay': 'com.beeasy.toppay',
    'viettelmoney': 'com.bplus.vtpay',
  };
  for (final e in wallets.entries) {
    if (key.contains(e.key)) return e.value;
  }
  final names = [
    for (final e in notifyBankNames.entries)
      (normalizeBrandKey(e.value), e.key),
  ]..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  for (final (n, pkg) in names) {
    if (n.length >= 3 && key.contains(n)) return pkg;
  }
  return null;
}

// A VND number: grouped thousands ("1,500,000" / "200.000") or a plain run of digits, optional ".00" tail.
// Never part of a date or time ("28/11", "10:15").
const _num = r'(\d{1,3}(?:[.,]\d{3})+|\d+)(?:[.,]00(?!\d))?(?![\d/:])';
const _cur = r'(\s?(?:vnd|dong|d|₫)(?![a-z]))';

final _balanceRe = RegExp(
  r'(?:so du(?: hien tai| kha dung| cuoi(?: ky)?| vi)?|\bsd|\bsdc)\s*[:=]?\s*'
  '$_num$_cur?',
);
// "TK 1234", "TK: xx1234", "STK 0451000123456", "tai khoan ...1234", "the 1234" is not an account (card) and is
// left alone.
final _accountRe = RegExp(
  r'(?:\bs?tk|tai khoan)(?:\s+(?!tai\b)[a-z]{2,10})?\s*[:.]?\s*((?:[x*•.]+\s?)?\d[\dx*•]{2,24})',
);
final _txCodeRe = RegExp(
  r'(?:ma giao dich|ma gd|\bmgd)\s*[:#]?\s*([0-9a-z]{6,24})',
);
final _keywordRe = RegExp(
  r'(?:\bps|\bgd|giao dich|so tien(?: gd| giao dich)?|bien dong)\s*[:=]?\s*([+-])?\s?'
  '$_num$_cur?',
);
final _signedRe = RegExp(
  r'(?:^|[\s:|(\[;,])([+-])\s?'
  '$_num$_cur?',
);
final _currencyRe = RegExp(
  r'(?<![\d.,])'
  '$_num$_cur',
);
final _descRe = RegExp(
  r'(?:\bnd|noi dung(?: giao dich| gd)?|loi nhan|dien giai|\bmo ta|\bref)\s*[:.]?\s+|(?:\bnd|noi dung|loi nhan)\s*:',
);

const _inWords = [
  'nhan duoc',
  'vua nhan',
  'da nhan',
  'nhan tien',
  'duoc cong',
  'ghi co',
  'tien vao',
  'hoan tien',
  'nap tien',
  'tang ',
];
const _outWords = [
  'thanh toan',
  'da chuyen',
  'chuyen tien thanh cong',
  'chuyen den',
  'bi tru',
  'ghi no',
  'tien ra',
  'rut tien',
  'giam ',
  'da tra',
];

int _toVnd(String digits) => int.parse(digits.replaceAll(RegExp(r'[.,]'), ''));

/// Parses one notification (title + text). Balance figures ("Số dư", "SD") never count as the amount.
NotifyParse parseBankNotification({
  required String package,
  required String title,
  required String text,
}) {
  final bank = bankNameOf(package);
  // Drop combining marks (decomposed input) so the folded copy keeps the same indices as the original.
  final raw = '$title\n$text'.replaceAll(RegExp('[̀-ͯ]'), '');
  var low = foldVietnamese(raw);
  final original = low.length == raw.length ? raw : low;

  // 1) Balances: remember the first one and blank them out so they cannot be read as the amount.
  int? balance;
  for (final m in _balanceRe.allMatches(low)) {
    balance ??= _toVnd(m.group(1)!);
  }
  low = low.replaceAllMapped(_balanceRe, (m) => ' ' * (m.end - m.start));

  // Account number (only its last 4 digits are kept) and the provider's transaction code: blanked too, so a long
  // digit run is never read as the amount.
  String? last4;
  String? accountNumber;
  for (final m in _accountRe.allMatches(low)) {
    final digits = RegExp(r'(\d+)$').firstMatch(m.group(1)!)?.group(1);
    if (digits != null && digits.length >= 4) {
      last4 = digits.substring(digits.length - 4);
      // A full (unmasked) number is kept too.
      if (RegExp(r'^\d{6,19}$').hasMatch(m.group(1)!)) {
        accountNumber = m.group(1);
      }
      break;
    }
  }
  final code = _txCodeRe.firstMatch(low)?.group(1)?.toUpperCase();
  low = low
      .replaceAllMapped(_accountRe, (m) => ' ' * (m.end - m.start))
      .replaceAllMapped(_txCodeRe, (m) => ' ' * (m.end - m.start));

  // 2) Description: text after "ND:", "Nội dung", "Lời nhắn"... up to the end of the line / segment.
  String? description;
  var descStart = low.length;
  final d = _descRe.firstMatch(low);
  if (d != null) {
    descStart = d.start;
    var end = original.length;
    final stop = RegExp(r'[\n|]').firstMatch(original.substring(d.end));
    if (stop != null) end = d.end + stop.start;
    // Messages are often quoted: kèm lời nhắn: "AN TRUA".
    final s = original
        .substring(d.end, end)
        .trim()
        .replaceAll(RegExp(r'^["“”]+|["“”]+[.\s]*$'), '')
        .trim();
    if (s.isNotEmpty) description = s;
  }

  // Sender / receiver named in the title: "Nhận tiền chuyển khoản từ NGUYEN VAN A".
  String? counterparty;
  final firstLine = low.indexOf('\n');
  final titleLow = firstLine < 0 ? low : low.substring(0, firstLine);
  final cp = RegExp(r'\b(?:tu|den|cho)\s+([^\d\n:]{3,60})$')
      .firstMatch(titleLow);
  if (cp != null) {
    final name = original
        .substring(cp.start + cp.group(0)!.indexOf(cp.group(1)!), cp.end)
        .trim();
    if (name.isNotEmpty && !name.contains(RegExp(r'[|]'))) counterparty = name;
  }
  // The amount and direction come from the part before the description (a note like "chuyen tien" must not
  // flip the direction).
  final head = low.substring(0, descStart);

  // 3) Amount, by confidence: keyword ("GD:", "PS:", "Số tiền"), then a signed number, then a number with "VND/đ".
  int? amount;
  String? sign;
  // A keyword hit only counts when it looks like money (sign, thousands separators or a currency), so a
  // reference such as "Mã GD 123456" is not taken as the amount.
  final k = _keywordRe
      .allMatches(head)
      .where(
        (m) =>
            m.group(1) != null ||
            m.group(2)!.contains(RegExp('[.,]')) ||
            m.group(3) != null,
      )
      .firstOrNull;
  if (k != null) {
    sign = k.group(1);
    amount = _toVnd(k.group(2)!);
  } else {
    final s = _signedRe.firstMatch(head);
    if (s != null) {
      sign = s.group(1);
      amount = _toVnd(s.group(2)!);
    } else {
      final c = _currencyRe.firstMatch(head);
      if (c != null) amount = _toVnd(c.group(1)!);
    }
  }
  if (amount != null && amount <= 0) amount = null;

  // 4) Direction: the sign wins; otherwise wording.
  NotifyDirection? direction;
  if (sign == '+') {
    direction = NotifyDirection.inflow;
  } else if (sign == '-') {
    direction = NotifyDirection.outflow;
  } else {
    final inAt = _firstIndex(head, _inWords);
    final outAt = _firstIndex(head, _outWords);
    if (inAt != null && (outAt == null || inAt < outAt)) {
      direction = NotifyDirection.inflow;
    } else if (outAt != null) {
      direction = NotifyDirection.outflow;
    }
  }

  return NotifyParse(
    bank: bank,
    direction: direction,
    amount: amount,
    balance: balance,
    description: description,
    last4: last4,
    txCode: code,
    counterparty: counterparty,
    bankRef: _bankRef(raw),
    accountNumber: accountNumber,
    postedAt: _postedAt(raw),
  );
}

int? _firstIndex(String s, List<String> words) {
  int? best;
  for (final w in words) {
    final i = s.indexOf(w);
    if (i >= 0 && (best == null || i < best)) best = i;
  }
  return best;
}

// Bank transfer reference: "FT26332327719412", or the number after "Ref" ("Ref 159036437923-...").
String? _bankRef(String raw) {
  final up = raw.toUpperCase();
  final ft = RegExp(r'\b(FT\d{8,20})\b').firstMatch(up);
  if (ft != null) return ft.group(1);
  return RegExp(r'\bREF[:.]?\s*(\d{6,20})\b').firstMatch(up)?.group(1);
}

// "28/11/26;03:08", "28/11/2026 03:08" or "28-11-2026 03:24:23" (local phone time).
DateTime? _postedAt(String s) {
  final m = RegExp(
    r'(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})[;,\s]+(?:luc\s+|lúc\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(s);
  if (m == null) return null;
  var y = int.parse(m.group(3)!);
  if (y < 100) y += 2000;
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(1)!);
  final h = int.parse(m.group(4)!);
  final mi = int.parse(m.group(5)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  final sec = int.tryParse(m.group(6) ?? '') ?? 0;
  return DateTime(y, mo, d, h, mi, sec);
}
