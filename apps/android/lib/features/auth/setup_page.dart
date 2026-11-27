import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import '../../core/ui/brand.dart';
import '../../core/widgets.dart';
import 'auth_service.dart';

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
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  int _step = 0;
  bool _busy = false;
  bool _hide = true;
  String? _emailError, _nameError, _passwordError, _confirmError, _codeError;

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

  bool _validateStep1() {
    final e = _email.text.trim();
    setState(() {
      _emailError = e.contains('@') && e.contains('.')
          ? null
          : 'Nhập email hợp lệ.';
      _nameError = _name.text.trim().isEmpty ? 'Nhập tên hiển thị.' : null;
      _passwordError = _password.text.length < 8
          ? 'Mật khẩu cần tối thiểu 8 ký tự.'
          : null;
      _confirmError = _confirm.text == _password.text
          ? null
          : 'Mật khẩu nhập lại không khớp.';
    });
    return _emailError == null &&
        _nameError == null &&
        _passwordError == null &&
        _confirmError == null;
  }

  Future<void> _sendCode() async {
    if (_step == 0 && !_validateStep1()) return;
    await _guard(() async {
      await AuthService(ref.read(apiProvider)).startSignup(_email.text);
      if (mounted) setState(() => _step = 1);
    });
  }

  Future<void> _finish() async {
    if (_code.text.trim().length < 6) {
      setState(() => _codeError = 'Nhập mã gồm các chữ số trong thư.');
      return;
    }
    setState(() => _codeError = null);
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
      backgroundColor: Colors.white,
      body: SafeArea(
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
                color: MomaColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _step == 0
                  ? 'Dùng email chủ sở hữu để tạo tài khoản MoMa của bạn.'
                  : 'Chúng tôi đã gửi một mã xác nhận đến ${_email.text.trim()}. Mở hộp thư và nhập mã vào bên dưới.',
              style: text.bodyMedium?.copyWith(color: MomaColors.muted),
            ),
            const SizedBox(height: 20),
            if (_step == 0) ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.mail_outline_rounded),
                  hintText: 'Email',
                  errorText: _emailError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                  hintText: 'Tên hiển thị',
                  errorText: _nameError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: _hide,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  hintText: 'Mật khẩu (tối thiểu 8 ký tự)',
                  errorText: _passwordError,
                  suffixIcon: IconButton(
                    tooltip: _hide ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                    icon: Icon(
                      _hide
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: _hide,
                onSubmitted: (_) => _sendCode(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.lock_reset_rounded),
                  hintText: 'Nhập lại mật khẩu',
                  errorText: _confirmError,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _sendCode,
                child: _busy ? const _Spinner() : const Text('Tiếp tục'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Đã có tài khoản? Đăng nhập'),
              ),
            ] else ...[
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofocus: true,
                maxLength: 8,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w800,
                ),
                onSubmitted: (_) => _finish(),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  errorText: _codeError,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _finish,
                child: _busy
                    ? const _Spinner()
                    : const Text('Xác nhận và tạo tài khoản'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _sendCode,
                child: const Text('Gửi lại mã'),
              ),
              Text(
                'Không thấy thư? Kiểm tra mục Spam hoặc Quảng cáo.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: MomaColors.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 22,
    width: 22,
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );
}
