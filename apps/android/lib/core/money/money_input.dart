import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/labeled_field.dart';
import '../validators.dart';
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

/// Amount input: label above, digits only (typing letters is impossible), thousands separators and validation
/// that follows the standard timing of [LabeledField]. [hint] is the field name; [optional] allows empty.
class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    this.hint = 'Số tiền',
    this.autofocus = false,
    this.optional = false,
    this.onChanged,
  });
  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final bool optional;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => LabeledField(
    label: hint,
    controller: controller,
    required: !optional,
    autofocus: autofocus,
    icon: Icons.payments_outlined,
    suffixText: '₫',
    keyboardType: TextInputType.number,
    onChanged: onChanged,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      ThousandsFormatter(),
    ],
    validator: V.amount(hint, allowEmpty: optional),
  );
}
