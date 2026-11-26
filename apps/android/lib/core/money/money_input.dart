import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'money.dart';

/// Formats digits as VND with dot separators while typing; the value itself stays an integer.
class ThousandsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final n = parseVndInput(newValue.text);
    if (n == null) return const TextEditingValue();
    final text = formatVnd(n).replaceAll(' ₫', '');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    this.hint = 'Số tiền',
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        ThousandsFormatter(),
      ],
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.payments_outlined),
        hintText: hint,
        suffixText: '₫',
      ),
    );
  }
}
