import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../validators.dart';
import '../../app/theme/palette.dart';

/// Form field with the label above and a short "Nhập ..." placeholder inside (design reference).
/// It validates itself while the user types / leaves it ([validator]); rules are never written into the placeholder.
/// [errorText] is for server-driven messages tied to this field.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.icon,
    this.obscure = false,
    this.required = false,
    this.validator,
    this.errorText,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.maxLength,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
    this.style,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;

  /// Short explanation under the field (e.g. an example). Not a validation rule.
  final String? helper;
  final IconData? icon;
  final bool obscure;
  final bool required;
  final Validator? validator;
  final String? errorText;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int? maxLength;
  final int maxLines;
  final TextAlign textAlign;
  final TextStyle? style;
  final Iterable<String>? autofillHints;
  final TextCapitalization textCapitalization;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: context.pal.ink,
            ),
            children: [
              if (required)
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
          obscureText: obscure,
          autofocus: autofocus,
          enabled: enabled,
          maxLength: maxLength,
          minLines: 1,
          maxLines: obscure ? 1 : maxLines,
          textAlign: textAlign,
          style: style,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          textCapitalization: textCapitalization,
          autofillHints: autofillHints,
          onFieldSubmitted: onSubmitted,
          onChanged: onChanged,
          validator: validator,
          forceErrorText: errorText,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          decoration: InputDecoration(
            counterText: '',
            hintText: hint ?? 'Nhập ${label.toLowerCase()}',
            helperText: helper,
            helperMaxLines: 3,
            errorMaxLines: 3,
            prefixIcon: icon == null ? null : Icon(icon),
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}
