import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
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

/// Amount input: label above, digits only (typing letters is impossible), thousands separators, live validation.
/// [hint] is the field name (shown as the label); [optional] allows an empty value.
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
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: hint,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: MomaColors.ink,
            ),
            children: [
              if (!optional)
                const TextSpan(
                  text: ' *',
                  style: TextStyle(color: MomaColors.expense),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          onChanged: onChanged,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            ThousandsFormatter(),
          ],
          validator: V.amount(hint, allowEmpty: optional),
          autovalidateMode: AutovalidateMode.onUserInteraction,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.payments_outlined),
            hintText: 'Nhập ${hint.toLowerCase()}',
            suffixText: '₫',
            errorMaxLines: 3,
          ),
        ),
      ],
    );
  }
}
