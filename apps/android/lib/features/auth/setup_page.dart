import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/brand.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import 'auth_service.dart';
import '../../app/theme/palette.dart';

/// True while sign-up is finishing: the session exists after the code is verified, but the owner binding and
/// device registration are still running, so the router must not jump to the main app yet.
final ValueNotifier<bool> signupInProgress = ValueNotifier<bool>(false);

/// "Tạo tài khoản": step 1 collects email / name / password and mails a code, step 2 verifies the code.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});
  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  int _step = 0;
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    for (final c in [_email, _name, _password, _confirm, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } on Exception catch (e) {
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _valid => _form.currentState?.validate() ?? false;

  Future<void> _sendCode() async {
    if (_step == 0 && !_valid) return;
    await _guard(() async {
      await AuthService(ref.read(apiProvider)).startSignup(_email.text);
      if (mounted) {
        setState(() => _step = 1);
        _code.clear();
      }
    });
  }

  Future<void> _finish() async {
    if (!_valid) return;
    signupInProgress.value = true;
    await _guard(() async {
      try {
        await AuthService(ref.read(apiProvider)).completeSetup(
          email: _email.text,
          code: _code.text,
          password: _password.text,
          displayName: _name.text,
        );
        if (mounted) context.go('/onboarding');
      } finally {
        signupInProgress.value = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.pal.surface,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_step == 0) ...[
                ActionButtons(
                  primaryLabel: 'Tiếp tục',
                  onPrimary: _sendCode,
                  busy: _busy,
                ),
                TextButton(
                  onPressed: _busy ? null : () => context.go('/login'),
                  child: const Text('Đã có tài khoản? Đăng nhập'),
                ),
              ] else
                ActionButtons(
                  primaryLabel: 'Xác nhận và tạo tài khoản',
                  onPrimary: _finish,
                  secondaryLabel: 'Quay lại',
                  onSecondary: () => setState(() => _step = 0),
                  tertiaryLabel: 'Gửi lại mã',
                  onTertiary: _sendCode,
                  busy: _busy,
                ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Quay lại',
                  onPressed: () => _step == 1
                      ? setState(() => _step = 0)
                      : context.go('/welcome'),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const Center(child: MomaWordmark(size: 48, dark: true)),
              const SizedBox(height: 24),
              Text(
                _step == 0 ? 'Tạo tài khoản' : 'Xác nhận email',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _step == 0
                    ? 'Dùng email chủ sở hữu để tạo tài khoản MoMa của bạn.'
                    : 'Chúng tôi đã gửi một mã xác nhận đến ${_email.text.trim()}. Mở hộp thư và nhập mã vào bên dưới.',
                style: text.bodyMedium?.copyWith(color: context.pal.muted),
              ),
              const SizedBox(height: 20),
              if (_step == 0) ...[
                LabeledField(
                  label: 'Email',
                  hint: 'Nhập email',
                  controller: _email,
                  icon: Icons.mail_outline_rounded,
                  required: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: V.email,
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Tên hiển thị',
                  hint: 'Nhập tên của bạn',
                  controller: _name,
                  icon: Icons.person_outline_rounded,
                  required: true,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: V.displayName,
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Mật khẩu',
                  hint: 'Nhập mật khẩu',
                  controller: _password,
                  icon: Icons.lock_outline_rounded,
                  required: true,
                  obscure: _hide,
                  textInputAction: TextInputAction.next,
                  validator: V.newPassword,
                  suffix: IconButton(
                    tooltip: _hide ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                    icon: Icon(
                      _hide
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Nhập lại mật khẩu',
                  hint: 'Nhập lại mật khẩu',
                  controller: _confirm,
                  icon: Icons.lock_reset_rounded,
                  required: true,
                  obscure: _hide,
                  onSubmitted: (_) => _sendCode(),
                  validator: V.sameAs(
                    () => _password.text,
                    'Mật khẩu nhập lại chưa khớp.',
                  ),
                ),
              ] else ...[
                LabeledField(
                  label: 'Mã xác nhận',
                  hint: 'Nhập mã trong thư',
                  controller: _code,
                  icon: Icons.pin_outlined,
                  required: true,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  maxLength: 8,
                  onSubmitted: (_) => _finish(),
                  validator: V.otp,
                ),
                const SizedBox(height: 12),
                Text(
                  'Không thấy thư? Kiểm tra mục Spam hoặc Quảng cáo.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: context.pal.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
