/// Integer VND only. Wire format is a decimal string; never use double for money.
int parseVnd(String wire) => int.parse(wire);

String formatVnd(int v) {
  final neg = v < 0;
  final digits = (neg ? -v : v).toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf ₫';
}

/// Parses user input such as "1.250.000" into an int, or null if empty/invalid.
int? parseVndInput(String text) {
  final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty || digits.length > 16) return null;
  return int.parse(digits);
}
