/// Deterministic Vietnamese quick-entry parser (rule engine, no AI, no network).
/// It only produces a *suggestion*; the user confirms and the normal TX_CREATE command path posts it.
class QuickParse {
  const QuickParse({
    required this.amount,
    required this.income,
    required this.categoryName,
    required this.note,
  });

  /// Integer VND, or null when the text carries no unambiguous amount (never guessed).
  final int? amount;
  final bool income;

  /// Name of a seeded system category, or null if no rule matched.
  final String? categoryName;
  final String note;
}

const _fromChars =
    'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const _toChars =
    'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';

/// Lowercases and strips Vietnamese diacritics so "Ăn trưa" matches "an trua".
String foldVietnamese(String input) {
  final lower = input.toLowerCase();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    final i = _fromChars.indexOf(ch);
    b.write(i >= 0 ? _toChars[i] : ch);
  }
  return b.toString();
}

const _incomeWords = [
  'luong',
  'thuong',
  'nhan ',
  'thu nhap',
  'lai suat',
  'tien lai',
  'ban ',
  'duoc tra',
  'hoan tien',
];

const _incomeRules = <String, List<String>>{
  'Lương': ['luong'],
  'Thưởng': ['thuong'],
  'Lãi': ['lai suat', 'tien lai', 'lai '],
};

const _expenseRules = <String, List<String>>{
  'Ăn uống': [
    'an ',
    'trua',
    'sang',
    'toi',
    'com ',
    'pho',
    'bun ',
    'ca phe',
    'cafe',
    'tra sua',
    'nhau',
    'bia',
    'do an',
    'nha hang',
  ],
  'Di chuyển': [
    'grab',
    'xang',
    'taxi',
    'gui xe',
    've xe',
    'xe bus',
    'be ',
    'gojek',
    'phi cau duong',
    'do xang',
  ],
  'Nhà ở': ['tien nha', 'thue nha', 'chung cu', 'sua nha'],
  'Hóa đơn': [
    'dien',
    'nuoc',
    'internet',
    'wifi',
    'dien thoai',
    'hoa don',
    'cuoc ',
    'gas',
  ],
  'Mua sắm': [
    'mua ',
    'quan ',
    'ao ',
    'giay',
    'shopee',
    'lazada',
    'tiki',
    'tiktok shop',
    'sieu thi',
  ],
  'Giải trí': [
    'phim',
    'netflix',
    'spotify',
    'game',
    'karaoke',
    'du lich',
    've ',
  ],
  'Sức khỏe': ['thuoc', 'kham', 'benh vien', 'gym', 'nha khoa'],
  'Giáo dục': ['hoc phi', 'khoa hoc', 'sach', 'hoc '],
};

final _amountPattern = RegExp(
  r'(\d+(?:[.,]\d+)*)\s*(nghìn|nghin|ngàn|ngan|triệu|trieu|tỷ|ty|tr|k|m)?(\d{1,3})?(?![\p{L}\d])',
  unicode: true,
  caseSensitive: false,
);

int _unitMultiplier(String unit) {
  switch (foldVietnamese(unit)) {
    case 'k':
    case 'nghin':
    case 'ngan':
      return 1000;
    case 'tr':
    case 'trieu':
    case 'm':
      return 1000000;
    case 'ty':
      return 1000000000;
  }
  return 1;
}

/// Parses amounts such as "65k", "1.5tr", "1,5 triệu", "1tr2", "300 nghìn", "65.000". Integer math only.
int? parseAmountToken(String number, String? unit, String? tail) {
  if (unit == null || unit.isEmpty) {
    // Bare number: accept only unambiguous forms (plain digits or thousand-grouped), at least 1.000.
    final grouped = RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(number);
    final plain = RegExp(r'^\d+$').hasMatch(number);
    if (!grouped && !plain) return null;
    final v = int.tryParse(number.replaceAll(RegExp(r'[.,]'), ''));
    if (v == null || v < 1000) return null;
    return v;
  }
  final mult = _unitMultiplier(unit);
  final parts = number.split(RegExp(r'[.,]'));
  if (parts.length > 2) return null;
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  var value = whole * mult;
  // Fraction from "1,5tr" or "1tr2"; extra precision beyond the unit is rejected, not rounded.
  final fraction = parts.length == 2 ? parts[1] : (tail ?? '');
  if (fraction.isNotEmpty) {
    final f = int.tryParse(fraction);
    if (f == null) return null;
    var scale = 1;
    for (var i = 0; i < fraction.length; i++) {
      scale *= 10;
    }
    if ((f * mult) % scale != 0) return null;
    value += (f * mult) ~/ scale;
  }
  return value > 0 ? value : null;
}

QuickParse parseQuickText(String text) {
  final folded = '${foldVietnamese(text)} ';
  int? amount;
  String remaining = text;
  for (final m in _amountPattern.allMatches(text)) {
    final v = parseAmountToken(m.group(1)!, m.group(2), m.group(3));
    if (v != null) {
      amount = v;
      remaining = text.replaceRange(m.start, m.end, ' ');
      break;
    }
  }
  final income = _incomeWords.any(folded.contains);
  final rules = income ? _incomeRules : _expenseRules;
  String? category;
  for (final e in rules.entries) {
    if (e.value.any(
      (w) => (' $folded').contains(' ${w.trimRight()}') && folded.contains(w),
    )) {
      category = e.key;
      break;
    }
  }
  final note = remaining.replaceAll(RegExp(r'\s+'), ' ').trim();
  return QuickParse(
    amount: amount,
    income: income,
    categoryName: category,
    note: note,
  );
}
