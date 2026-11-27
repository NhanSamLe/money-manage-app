import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/widgets.dart';
import '../widgets/widget_sync.dart';
import 'speech_service.dart';
import 'voice_prefs.dart';

/// Round input-bar button: microphone when idle, pulsing stop button while listening.
/// Tap toggles listening; long-press is hold-to-talk.
class VoiceMicButton extends StatefulWidget {
  const VoiceMicButton({
    super.key,
    required this.listening,
    required this.enabled,
    required this.level,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });
  final bool listening;
  final bool enabled;
  final ValueListenable<double> level;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends State<VoiceMicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.listening) _pulse.repeat();
  }

  @override
  void didUpdateWidget(VoiceMicButton old) {
    super.didUpdateWidget(old);
    if (widget.listening && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.listening && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.listening;
    final color = on ? MomaColors.expense : MomaColors.emerald;
    final enabled = widget.enabled || on;
    return Semantics(
      button: true,
      label: on ? 'Dừng nghe' : 'Nói với Trợ lý',
      child: Tooltip(
        message: on ? 'Dừng nghe' : 'Nói (giữ để nói)',
        child: GestureDetector(
          onTap: enabled ? widget.onTap : null,
          onLongPressStart: enabled && !on ? (_) => widget.onHoldStart() : null,
          onLongPressEnd: enabled ? (_) => widget.onHoldEnd() : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: AnimatedBuilder(
              animation: Listenable.merge([_pulse, widget.level]),
              builder: (context, _) {
                final t = _pulse.value;
                final lv = widget.level.value;
                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    if (on)
                      Transform.scale(
                        scale: 1 + 0.35 * t + 0.25 * lv,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color.withValues(alpha: 0.28 * (1 - t)),
                          ),
                        ),
                      ),
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: enabled ? color : color.withValues(alpha: 0.4),
                      ),
                      child: Icon(
                        on ? Symbols.stop_rounded : Symbols.mic_rounded,
                        color: Colors.white,
                        fill: 1,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// "Đang nghe…" strip with a small live waveform, shown above the input while listening.
class ListeningBar extends StatefulWidget {
  const ListeningBar({super.key, required this.level});
  final ValueListenable<double> level;

  @override
  State<ListeningBar> createState() => _ListeningBarState();
}

class _ListeningBarState extends State<ListeningBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_anim, widget.level]),
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 5; i++)
                  Container(
                    width: 3.5,
                    height:
                        5 +
                        13 *
                            (0.25 +
                                    0.45 * widget.level.value +
                                    0.3 *
                                        (0.5 +
                                            0.5 *
                                                math.sin(
                                                  (_anim.value + i * 0.21) *
                                                      2 *
                                                      math.pi,
                                                )))
                                .clamp(0.0, 1.0),
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: MomaColors.expense,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Đang nghe…',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: MomaColors.expense,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Chạm nút đỏ để dừng',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: pal.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains the microphone before Android's own permission prompt. True: continue to the system prompt.
Future<bool> showMicRationale(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (c) {
      final pal = c.pal;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: MomaColors.emerald.withValues(alpha: 0.12),
                ),
                child: const Icon(
                  Symbols.mic_rounded,
                  color: MomaColors.emerald,
                  size: 32,
                  fill: 1,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Cho phép dùng micro',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: pal.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'MoMa cần micro để bạn nói với Trợ lý. Âm thanh được nhận dạng bởi dịch vụ giọng nói của điện thoại; MoMa không lưu âm thanh.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: pal.muted),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Để sau'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Tiếp tục'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return ok ?? false;
}

/// The permission was refused for good: Android will not ask again, only Settings can grant it.
Future<void> showMicSettingsDialog(BuildContext context) async {
  final open = await showConfirmDialog(
    context,
    title: 'Chưa có quyền micro',
    message: 'Để nói với Trợ lý, bạn mở Cài đặt của MoMa, chọn Quyền (Quyền ứng dụng) và cho phép Micro.',
    confirmLabel: 'Mở Cài đặt',
    cancelLabel: 'Để sau',
  );
  if (!open) return;
  final opened = await WidgetSync.openPermissions();
  if (!opened && context.mounted) {
    showSnack(
      context,
      'Không mở được Cài đặt. Bạn vào Cài đặt > Ứng dụng > MoMa > Quyền.',
    );
  }
}

/// Microphone permission flow: rationale sheet first, then the system prompt; a second refusal (Android stops
/// asking after two) leads to the Settings dialog. True when the recognizer is ready.
Future<bool> ensureVoiceReady(
  BuildContext context, {
  required SpeechService speech,
  required Future<bool> Function() prepare,
  required VoicePrefsNotifier prefs,
}) async {
  final granted = await speech.hasPermission();
  if (!granted) {
    if (!context.mounted || !await showMicRationale(context)) return false;
  }
  final ready = await prepare();
  if (!context.mounted) return false;
  if (ready) {
    if (!granted) await prefs.setMicDenials(0);
    return true;
  }
  if (await speech.hasPermission()) {
    // Permission is fine: the phone has no speech recognition service.
    if (context.mounted) {
      await showErrorDialog(
        context,
        'Điện thoại chưa có dịch vụ nhận dạng giọng nói. Bạn cài hoặc bật ứng dụng Google (Gõ bằng giọng nói của Google) rồi thử lại.',
      );
    }
    return false;
  }
  final denials = await prefs.micDenials() + 1;
  await prefs.setMicDenials(denials);
  if (!context.mounted) return false;
  if (denials >= 2) {
    await showMicSettingsDialog(context);
  } else {
    showSnack(
      context,
      'Bạn chưa cho phép micro. Bấm micro lần nữa nếu muốn nói với Trợ lý.',
    );
  }
  return false;
}
