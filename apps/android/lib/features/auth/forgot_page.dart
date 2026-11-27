import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import 'auth_service.dart';

/// Password recovery with the emailed code (no deep links). Supabase Auth owns the credential reset.
class ForgotPage extends ConsumerStatefulWidget {
  const ForgotPage({super.key});
  @override
  ConsumerState<ForgotPage> createState() => _ForgotPageState();
}

class _ForgotPageState extends ConsumerState<ForgotPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on AuthException {
      if (mounted) {
        setState(() => _error = 'Không thực hiện được. Kiểm tra email và mã.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
    await Supabase.instance.client.auth.resetPasswordForEmail(
      _email.text.trim(),
    );
    if (mounted) setState(() => _sent = true);
  });

  Future<void> _reset() => _run(() async {
    if (_password.text.length < 8) {
      throw ApiException(
        'VALIDATION_FAILED',
        'Mật khẩu cần tối thiểu 8 ký tự.',
      );
    }
    final auth = Supabase.instance.client.auth;
    await auth.verifyOTP(
      email: _email.text.trim(),
      token: _code.text.trim(),
      type: OtpType.recovery,
    );
    await auth.updateUser(UserAttributes(password: _password.text));
    await AuthService(ref.read(apiProvider)).registerDevice();
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/login')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Quên mật khẩu',
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: MomaColors.forest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _sent
                  ? 'Nhập mã trong thư và đặt mật khẩu mới.'
                  : 'Chúng tôi sẽ gửi mã xác nhận tới email của bạn.',
              style: text.bodyMedium?.copyWith(color: MomaColors.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.mail_outline_rounded),
                labelText: 'Email',
                hintText: 'Nhập email',
              ),
            ),
            if (_sent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.pin_outlined),
                  labelText: 'Mã xác nhận',
                  hintText: 'Nhập mã trong thư',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                  labelText: 'Mật khẩu mới',
                  hintText: 'Nhập tối thiểu 8 ký tự',
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: MomaColors.expense),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : (_sent ? _reset : _send),
              child: Text(_sent ? 'Đặt mật khẩu mới' : 'Gửi mã'),
            ),
          ],
        ),
      ),
    );
  }
}
