import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import 'pin_hasher.dart';

/// Six dots + message + numeric keypad. Calls [onCompleted] when six digits are in; a non-null result is an
/// error: the dots shake, the entry clears and the message is shown.
class PinEntry extends StatefulWidget {
  const PinEntry({
    super.key,
    required this.onCompleted,
    this.enabled = true,
    this.message,
    this.extraKey,
    this.onBrand = false,
  });

  final Future<String?> Function(String pin) onCompleted;

  /// False while waiting out a cooldown.
  final bool enabled;

  /// Shown under the dots instead of the last error (e.g. a countdown).
  final String? message;

  /// Bottom-left key (biometric button); empty when null.
  final Widget? extraKey;

  /// White-on-green colours for the lock screen.
  final bool onBrand;

  @override
  State<PinEntry> createState() => PinEntryState();
}

class PinEntryState extends State<PinEntry>
    with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _error;
  bool _busy = false;
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  /// Clears the entry (e.g. when the setup flow moves to the confirm step).
  void reset() => setState(() {
    _pin = '';
    _error = null;
  });

  Future<void> _digit(String d) async {
    if (!widget.enabled || _busy || _pin.length >= pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < pinLength) return;
    setState(() => _busy = true);
    final err = await widget.onCompleted(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      _error = err;
    });
    if (err != null) {
      HapticFeedback.mediumImpact();
      _shake.forward(from: 0);
    }
  }

  void _delete() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final ink = widget.onBrand ? Colors.white : pal.ink;
    final idle = widget.onBrand
        ? Colors.white.withValues(alpha: 0.28)
        : pal.line;
    final fill = widget.onBrand ? Colors.white : MomaColors.emerald;
    final msg = widget.message ?? _error;
    final errColor = widget.onBrand
        ? const Color(0xFFFFB4A8)
        : MomaColors.expense;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _shake,
          builder: (context, child) {
            final t = _shake.value;
            final dx = math.sin(t * math.pi * 5) * 14 * (1 - t);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: Row(
            key: const ValueKey('pin-dots'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < pinLength; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length
                        ? (_error != null ? errColor : fill)
                        : Colors.transparent,
                    border: Border.all(
                      color: i < _pin.length ? fill : idle,
                      width: 2,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: Center(
            child: msg == null
                ? null
                : Text(
                    msg,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.message != null ? ink : errColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        _Keypad(
          ink: ink,
          enabled: widget.enabled && !_busy,
          onBrand: widget.onBrand,
          onDigit: _digit,
          onDelete: _delete,
          extraKey: widget.extraKey,
        ),
      ],
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.ink,
    required this.enabled,
    required this.onBrand,
    required this.onDigit,
    required this.onDelete,
    this.extraKey,
  });
  final Color ink;
  final bool enabled;
  final bool onBrand;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final Widget? extraKey;

  Widget _key(BuildContext context, String d) => PinKey(
    key: ValueKey('pin-key-$d'),
    onBrand: onBrand,
    onTap: enabled ? () => onDigit(d) : null,
    child: Text(
      d,
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: enabled ? ink : ink.withValues(alpha: 0.35),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    Widget row(List<Widget> c) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: c),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([
          for (final d in ['1', '2', '3']) _key(context, d),
        ]),
        row([
          for (final d in ['4', '5', '6']) _key(context, d),
        ]),
        row([
          for (final d in ['7', '8', '9']) _key(context, d),
        ]),
        row([
          extraKey ?? const SizedBox(width: PinKey.size + 24),
          _key(context, '0'),
          PinKey(
            key: const ValueKey('pin-key-del'),
            onBrand: onBrand,
            onTap: onDelete,
            semanticLabel: 'Xóa',
            child: Icon(Symbols.backspace_rounded, color: ink, size: 26),
          ),
        ]),
      ],
    );
  }
}

/// One round keypad button.
class PinKey extends StatelessWidget {
  const PinKey({
    super.key,
    required this.child,
    required this.onTap,
    this.onBrand = false,
    this.filled = true,
    this.semanticLabel,
  });
  static const size = 72.0;
  final Widget child;
  final VoidCallback? onTap;
  final bool onBrand;
  final bool filled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bg = !filled
        ? Colors.transparent
        : onBrand
        ? Colors.white.withValues(alpha: 0.1)
        : context.pal.surface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: SizedBox(
              width: size,
              height: size,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
