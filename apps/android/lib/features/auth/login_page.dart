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

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    // Every field validates inline; server/network failures use a dialog.
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await AuthService(ref.read(apiProvider))
          .signIn(_email.text, _password.text);
    } on Exception catch (e) {
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                  onPressed: () => context.go('/welcome'),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: MomaWordmark(size: 56, dark: true)),
              const SizedBox(height: 32),
              Text(
                'Đăng nhập tài khoản',
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: context.pal.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Tiếp tục quản lý tài chính của bạn',
                style: text.bodyMedium?.copyWith(color: context.pal.muted),
              ),
              const SizedBox(height: 24),
              LabeledField(
                label: 'Email',
                hint: 'Nhập email',
                controller: _email,
                icon: Icons.mail_outline_rounded,
                required: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                validator: V.email,
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Mật khẩu',
                hint: 'Nhập mật khẩu',
                controller: _password,
                icon: Icons.lock_outline_rounded,
                required: true,
                obscure: _hide,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                validator: V.currentPassword,
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.go('/forgot'),
                  child: const Text('Quên mật khẩu?'),
                ),
              ),
              const SizedBox(height: 8),
              ActionButtons(
                primaryLabel: 'Đăng nhập',
                onPrimary: _submit,
                busy: _busy,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Hoặc',
                      style: text.bodySmall?.copyWith(color: context.pal.muted),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: _busy ? null : () => context.go('/register'),
                child: const Text('Tạo tài khoản mới'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
