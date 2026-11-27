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
  });
  final String bank;
  final NotifyDirection? direction;
  final int? amount;
  final int? balance;
  final String? description;

  /// Only a message with both an amount and a direction can become a transaction.
  bool get isTransaction => amount != null && amount! > 0 && direction != null;
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
};

String bankNameOf(String package) => notifyBankNames[package] ?? package;

// A VND number: grouped thousands ("1,500,000" / "200.000") or a plain run of digits, optional ".00" tail.
// Never part of a date or time ("28/11", "10:15").
const _num = r'(\d{1,3}(?:[.,]\d{3})+|\d+)(?:[.,]00(?!\d))?(?![\d/:])';
const _cur = r'(\s?(?:vnd|dong|d|₫)(?![a-z]))';

final _balanceRe = RegExp(
  r'(?:so du(?: hien tai| kha dung| cuoi(?: ky)?| vi)?|\bsd|\bsdc)\s*[:=]?\s*'
  '$_num$_cur?',
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

  // 2) Description: text after "ND:", "Nội dung", "Lời nhắn"... up to the end of the line / segment.
  String? description;
  var descStart = low.length;
  final d = _descRe.firstMatch(low);
  if (d != null) {
    descStart = d.start;
    var end = original.length;
    final stop = RegExp(r'[\n|]').firstMatch(original.substring(d.end));
    if (stop != null) end = d.end + stop.start;
    final s = original.substring(d.end, end).trim();
    if (s.isNotEmpty) description = s;
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
