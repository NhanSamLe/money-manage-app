import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import 'qr_share.dart' show copyText;

/// Digits only ("0451 000 123456" -> "0451000123456").
String digitsOnly(String s) => s.replaceAll(RegExp(r'\D'), '');

/// "•••• 2004" from a full number or the last 4 digits.
String maskNumber({String? number, String? last4}) {
  final d = number == null ? (last4 ?? '') : digitsOnly(number);
  if (d.isEmpty) return '';
  return '•••• ${d.length > 4 ? d.substring(d.length - 4) : d}';
}

/// An account number shown masked by default, an eye to reveal it and a copy icon that copies the full number
/// (digits only). Without the full number only the masked last 4 digits are shown (no reveal, no copy).
class MaskedNumber extends StatefulWidget {
  const MaskedNumber({
    super.key,
    this.number,
    this.last4,
    this.prefix = '',
    this.style,
    this.iconSize = 18,
  });
  final String? number;
  final String? last4;

  /// Text before the number, e.g. "STK: ".
  final String prefix;
  final TextStyle? style;
  final double iconSize;

  @override
  State<MaskedNumber> createState() => _MaskedNumberState();
}

class _MaskedNumberState extends State<MaskedNumber> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final full = widget.number == null ? null : digitsOnly(widget.number!);
    final hasFull = full != null && full.isNotEmpty;
    final text = _shown && hasFull
        ? full
        : maskNumber(number: full, last4: widget.last4);
    if (text.isEmpty) return const SizedBox.shrink();
    final style = widget.style ?? TextStyle(color: pal.muted, fontSize: 13);
    Widget icon(IconData i, String tip, VoidCallback onTap, Key key) =>
        InkResponse(
          key: key,
          radius: 18,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Semantics(
              button: true,
              label: tip,
              child: Icon(i, size: widget.iconSize, color: pal.muted),
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: GestureDetector(
            onLongPress: hasFull
                ? () => copyText(context, full, 'Đã sao chép số tài khoản')
                : null,
            child: Text(
              '${widget.prefix}$text',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
        if (hasFull) ...[
          icon(
            _shown
                ? Symbols.visibility_off_rounded
                : Symbols.visibility_rounded,
            _shown ? 'Ẩn số tài khoản' : 'Hiện số tài khoản',
            () => setState(() => _shown = !_shown),
            const ValueKey('reveal-number'),
          ),
          icon(
            Symbols.content_copy_rounded,
            'Sao chép số tài khoản',
            () => copyText(context, full, 'Đã sao chép số tài khoản'),
            const ValueKey('copy-number'),
          ),
        ],
      ],
    );
  }
}

/// Copies [value] on long-press, with a snack "Đã sao chép [what]".
class CopyOnLongPress extends StatelessWidget {
  const CopyOnLongPress({
    super.key,
    required this.child,
    required this.value,
    required this.what,
  });
  final Widget child;
  final String value;
  final String what;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: value.isEmpty
        ? null
        : () => copyText(context, value, 'Đã sao chép $what'),
    child: child,
  );
}
