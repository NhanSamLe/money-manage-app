import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/providers.dart';
import 'auth_service.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService(ref.read(apiProvider))
          .signIn(_email.text, _password.text);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/welcome')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Đăng nhập tài khoản',
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: MomaColors.forest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tiếp tục quản lý tài chính của bạn',
              style: text.bodyMedium?.copyWith(color: MomaColors.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.mail_outline_rounded),
                hintText: 'Email',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _hide,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                hintText: 'Mật khẩu',
                suffixIcon: IconButton(
                  icon: Icon(
                    _hide
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _hide = !_hide),
                ),
              ),
            ),
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
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Đăng nhập'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/setup'),
              child: const Text('Chưa thiết lập? Thiết lập mới'),
            ),
          ],
        ),
      ),
    );
  }
}
