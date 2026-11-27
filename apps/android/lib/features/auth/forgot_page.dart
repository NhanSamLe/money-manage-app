import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/brand.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import 'auth_service.dart';
import '../../app/theme/palette.dart';

/// Password recovery with the emailed code (no deep links). Supabase Auth owns the credential reset.
class ForgotPage extends ConsumerStatefulWidget {
  const ForgotPage({super.key});
  @override
  ConsumerState<ForgotPage> createState() => _ForgotPageState();
}

class _ForgotPageState extends ConsumerState<ForgotPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } on AuthException {
      if (mounted) {
        await showErrorDialog(
          context,
          'Mã xác nhận không đúng hoặc đã hết hạn.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _valid => _form.currentState?.validate() ?? false;

  Future<void> _send() async {
    if (!_valid) return;
    await _run(() async {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        _email.text.trim(),
      );
      if (mounted) setState(() => _sent = true);
    });
  }

  Future<void> _reset() async {
    if (!_valid) return;
    await _run(() async {
      final auth = Supabase.instance.client.auth;
      await auth.verifyOTP(
        email: _email.text.trim(),
        token: _code.text.trim(),
        type: OtpType.recovery,
      );
      await auth.updateUser(UserAttributes(password: _password.text));
      await AuthService(ref.read(apiProvider)).registerDevice();
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.pal.surface,
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
                  onPressed: () => context.go('/login'),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const Center(child: MomaWordmark(size: 48, dark: true)),
              const SizedBox(height: 24),
              Text(
                'Quên mật khẩu',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _sent
                    ? 'Nhập mã trong thư và đặt mật khẩu mới.'
                    : 'Chúng tôi sẽ gửi mã xác nhận tới email của bạn.',
                style: text.bodyMedium?.copyWith(color: context.pal.muted),
              ),
              const SizedBox(height: 24),
              LabeledField(
                label: 'Email',
                hint: 'Nhập email',
                controller: _email,
                icon: Icons.mail_outline_rounded,
                required: true,
                enabled: !_sent,
                keyboardType: TextInputType.emailAddress,
                validator: V.email,
              ),
              if (_sent) ...[
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Mã xác nhận',
                  hint: 'Nhập mã trong thư',
                  controller: _code,
                  icon: Icons.pin_outlined,
                  required: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  validator: V.otp,
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Mật khẩu mới',
                  hint: 'Nhập mật khẩu mới',
                  controller: _password,
                  icon: Icons.lock_outline_rounded,
                  required: true,
                  obscure: _hide,
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
              ],
              const SizedBox(height: 24),
              ActionButtons(
                primaryLabel: _sent ? 'Đặt mật khẩu mới' : 'Gửi mã',
                onPrimary: _sent ? _reset : _send,
                secondaryLabel: _sent ? 'Gửi lại mã' : null,
                onSecondary: _send,
                busy: _busy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
