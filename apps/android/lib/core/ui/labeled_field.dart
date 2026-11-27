import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../validators.dart';
import '../widgets.dart';

/// Form field with the label above and a short "Nhập ..." placeholder inside (design reference).
///
/// Validation timing (UX standard): nothing is shown while the user is still typing for the first time.
/// The error appears when they leave the field (or press the form's button), and from then on it updates live,
/// so it disappears the moment the value becomes valid. Messages are short; rules are never placeholder text.
/// [errorText] is for server-driven messages tied to this field.
class LabeledField extends StatefulWidget {
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
    this.suffixText,
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
    this.inputFormatters,
    this.help,
    this.helpTitle,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;

  /// Short explanation under the field. Not a validation rule.
  final String? helper;
  final IconData? icon;
  final bool obscure;
  final bool required;
  final Validator? validator;
  final String? errorText;
  final Widget? suffix;
  final String? suffixText;
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
  final List<TextInputFormatter>? inputFormatters;

  /// Explanation opened by the "?" next to the label (an info dialog), for anything that needs one.
  final String? help;
  final String? helpTitle;

  @override
  State<LabeledField> createState() => _LabeledFieldState();
}

class _LabeledFieldState extends State<LabeledField> {
  final _key = GlobalKey<FormFieldState<String>>();
  late final FocusNode _focus = FocusNode();
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // First time the field loses focus: start validating it live.
      if (!_focus.hasFocus && !_touched && mounted) {
        setState(() => _touched = true);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _changed(String v) {
    // A form submit may have flagged this field before it was touched: keep it live from now on.
    if (!_touched && (_key.currentState?.hasError ?? false)) {
      setState(() => _touched = true);
    }
    widget.onChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(
          widget.label,
          required: widget.required,
          help: widget.help,
          helpTitle: widget.helpTitle,
        ),
        const SizedBox(height: 6),
        TextFormField(
          key: _key,
          focusNode: _focus,
          controller: widget.controller,
          obscureText: widget.obscure,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          maxLength: widget.maxLength,
          minLines: 1,
          maxLines: widget.obscure ? 1 : widget.maxLines,
          textAlign: widget.textAlign,
          style: widget.style,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          autofillHints: widget.autofillHints,
          inputFormatters: widget.inputFormatters,
          onFieldSubmitted: widget.onSubmitted,
          onChanged: _changed,
          validator: widget.validator,
          forceErrorText: widget.errorText,
          autovalidateMode: _touched
              ? AutovalidateMode.always
              : AutovalidateMode.disabled,
          decoration: InputDecoration(
            counterText: '',
            hintText: widget.hint ?? 'Nhập ${widget.label.toLowerCase()}',
            helperText: widget.helper,
            helperMaxLines: 3,
            errorMaxLines: 2,
            prefixIcon: widget.icon == null ? null : Icon(widget.icon),
            suffixIcon: widget.suffix,
            suffixText: widget.suffixText,
          ),
        ),
      ],
    );
  }
}
