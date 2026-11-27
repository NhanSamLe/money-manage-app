import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/widgets.dart';
import '../../core/providers.dart';
import 'auth_service.dart';

/// First-time owner setup. Step 1 sends the invite (deployment secret), step 2 verifies the emailed code.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});
  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _secret = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  int _step = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_secret, _email, _code, _password, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job, {VoidCallback? onDone}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
      if (mounted) onDone?.call();
    } on Exception catch (e) {
      if (mounted) await showErrorDialog(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final auth = AuthService(ref.read(apiProvider));
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.go('/welcome')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Thiết lập ban đầu',
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: MomaColors.forest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _step == 0
                  ? 'Bước 1/2: gửi thư mời đến email chủ sở hữu'
                  : 'Bước 2/2: nhập mã trong thư và đặt mật khẩu',
              style: text.bodyMedium?.copyWith(color: MomaColors.muted),
            ),
            const SizedBox(height: 24),
            if (_step == 0) ...[
              TextField(
                controller: _secret,
                obscureText: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.key_rounded),
                  labelText: 'Mã bí mật triển khai',
                  hintText: 'Nhập mã bí mật',
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => auth.startSetup(_secret.text.trim()),
                        onDone: () => setState(() => _step = 1),
                      ),
                child: const Text('Gửi thư mời'),
              ),
              TextButton(
                onPressed: () => setState(() => _step = 1),
                child: const Text('Tôi đã nhận được mã'),
              ),
            ] else ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                  labelText: 'Email chủ sở hữu',
                  hintText: 'Nhập email',
                ),
              ),
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
                controller: _name,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.person_outline_rounded),
                  labelText: 'Tên hiển thị',
                  hintText: 'Nhập tên của bạn',
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
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () {
                        if (_password.text.length < 8) {
                          setState(
                            () => _error = 'Mật khẩu cần tối thiểu 8 ký tự.',
                          );
                          return;
                        }
                        _run(
                          () => auth.completeSetup(
                            email: _email.text,
                            code: _code.text,
                            password: _password.text,
                            displayName: _name.text,
                          ),
                        );
                      },
                child: const Text('Hoàn tất thiết lập'),
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
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
