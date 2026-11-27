import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/palette.dart';
import '../../core/ui/header.dart';
import '../../core/ui/select_field.dart';
import '../../core/widgets.dart';
import 'lock_controller.dart';
import 'lock_screen.dart';
import 'lock_services.dart';
import 'pin_pad.dart';

/// Opens "Khóa ứng dụng" (Settings -> Ứng dụng).
Future<void> openLockSettings(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const LockSettingsPage()));

/// Whether this phone can use fingerprint / face (cached for the session).
final biometricAvailableProvider = FutureProvider<bool>(
  (ref) => ref.read(biometricProvider).isAvailable(),
);

class LockSettingsPage extends ConsumerStatefulWidget {
  const LockSettingsPage({super.key});
  @override
  ConsumerState<LockSettingsPage> createState() => _LockSettingsPageState();
}

class _LockSettingsPageState extends ConsumerState<LockSettingsPage> {
  bool _busy = false;

  LockController get _c => ref.read(lockControllerProvider.notifier);

  Future<void> _guard(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } on Object {
      if (mounted) {
        await showErrorDialog(
          context,
          'Không lưu được cài đặt khóa. Thử lại nhé.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool on) => _guard(() async {
    if (on) {
      final pin = await Navigator.of(
        context,
      ).push<String>(MaterialPageRoute(builder: (_) => const PinSetupPage()));
      if (pin == null || !mounted) return;
      await _c.enable(pin);
      if (!mounted) return;
      if (await ref.read(biometricAvailableProvider.future) && mounted) {
        final use = await showConfirmDialog(
          context,
          title: 'Dùng vân tay / khuôn mặt?',
          message: 'Mở MoMa nhanh hơn. Mã PIN vẫn dùng được khi cần.',
          confirmLabel: 'Dùng',
          cancelLabel: 'Để sau',
        );
        if (use) await _enableBio();
      }
    } else {
      if (!await _verify('Nhập mã PIN để tắt khóa')) return;
      await _c.disable();
    }
  });

  Future<bool> _verify(String title) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PinVerifyPage(title: title)),
    );
    return ok == true;
  }

  Future<void> _enableBio() async {
    // Confirm once that the sensor works before relying on it.
    final ok = await ref
        .read(biometricProvider)
        .authenticate('Xác thực để bật mở khóa bằng vân tay / khuôn mặt');
    if (ok) await _c.setBiometric(true);
  }

  Future<void> _changePin() => _guard(() async {
    if (!await _verify('Nhập mã PIN hiện tại')) return;
    if (!mounted) return;
    final pin = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const PinSetupPage(title: 'Đổi mã PIN'),
      ),
    );
    if (pin == null) return;
    await _c.changePin(pin);
    if (mounted) showSnack(context, 'Đã đổi mã PIN');
  });

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(lockControllerProvider);
    final bioAvailable = ref.watch(biometricAvailableProvider).value ?? false;
    final cfg = s.config;
    return Scaffold(
      body: MomaPage(
        title: 'Khóa ứng dụng',
        showBack: true,
        child: !s.loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _Card(
                    children: [
                      LabeledSwitch(
                        label: 'Khóa ứng dụng',
                        help: 'Hỏi mã PIN khi mở MoMa và khi quay lại sau một thời gian không dùng.',
                        value: cfg.enabled,
                        onChanged: (v) => _toggle(v),
                      ),
                      if (cfg.enabled) ...[
                        if (bioAvailable)
                          LabeledSwitch(
                            label: 'Dùng vân tay / khuôn mặt',
                            value: cfg.biometric,
                            onChanged: (v) => _guard(
                              () => v ? _enableBio() : _c.setBiometric(false),
                            ),
                          ),
                        const SizedBox(height: 12),
                        PickField<LockDelay>(
                          initialValue: cfg.delay,
                          decoration: const InputDecoration(
                            labelText: 'Tự khóa khi rời ứng dụng',
                          ),
                          help: 'Chuyển qua ứng dụng khác một lúc rồi quay lại thì không cần nhập lại mã PIN.',
                          items: [
                            for (final d in LockDelay.values)
                              DropdownMenuItem(value: d, child: Text(d.label)),
                          ],
                          onChanged: (d) {
                            if (d != null) _guard(() => _c.setDelay(d));
                          },
                        ),
                      ],
                    ],
                  ),
                  if (cfg.enabled) ...[
                    const SizedBox(height: 12),
                    _Card(
                      padding: EdgeInsets.zero,
                      children: [
                        ListTile(
                          onTap: _changePin,
                          leading: const Icon(Symbols.password_rounded),
                          title: const Text(
                            'Đổi mã PIN',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          trailing: Icon(
                            Symbols.chevron_right_rounded,
                            color: context.pal.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _Card(
                    children: [
                      LabeledSwitch(
                        label: 'Ẩn nội dung khi chuyển ứng dụng',
                        help: 'Màn hình đa nhiệm chỉ hiện ô trống, đồng thời chặn chụp màn hình trong MoMa.',
                        value: cfg.hideRecents,
                        onChanged: (v) => _guard(() => _c.setHideRecents(v)),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 12, 12),
  });
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.pal.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// Create a 6-digit PIN: enter, then confirm. Pops with the PIN (never stored here).
class PinSetupPage extends StatefulWidget {
  const PinSetupPage({super.key, this.title = 'Tạo mã PIN'});
  final String title;
  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  String? _first;

  Future<String?> _done(String pin) async {
    if (_first == null) {
      setState(() => _first = pin);
      return null;
    }
    if (pin == _first) {
      Navigator.of(context).pop(pin);
      return null;
    }
    setState(() => _first = null);
    return 'Mã PIN không khớp. Nhập lại từ đầu.';
  }

  @override
  Widget build(BuildContext context) => _PinPage(
    title: widget.title,
    heading: _first == null ? 'Nhập mã PIN gồm 6 số' : 'Nhập lại mã PIN',
    child: PinEntry(onCompleted: _done),
  );
}

/// Asks for the current PIN (same throttling as the lock screen). Pops true when correct.
class PinVerifyPage extends StatelessWidget {
  const PinVerifyPage({super.key, required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => _PinPage(
    title: 'Khóa ứng dụng',
    heading: title,
    child: PinChallenge(onSuccess: () => Navigator.of(context).pop(true)),
  );
}

class _PinPage extends StatelessWidget {
  const _PinPage({
    required this.title,
    required this.heading,
    required this.child,
  });
  final String title;
  final String heading;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: MomaPage(
      title: title,
      showBack: true,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                heading,
                key: const ValueKey('pin-heading'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 28),
              child,
            ],
          ),
        ),
      ),
    ),
  );
}
