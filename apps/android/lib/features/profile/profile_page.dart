import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/sheets.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/header.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import 'avatar.dart';
import 'owner_account.dart';

enum _PhotoAction { camera, gallery, remove }

/// "Hồ sơ": owner photo (kept on this device), display name, sign-in email, password change and sign-out.
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  bool _nameLoaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final profile = ref.read(profileProvider).value;
    if (profile == null) return;
    final wanted = _name.text.trim();
    if (wanted == ((profile['display_name'] as String?)?.trim() ?? '')) {
      showSnack(context, 'Đã cập nhật hồ sơ');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiProvider).command('PROFILE_UPDATE', {
        'expected_version': profile['version'],
        'display_name': wanted,
      }, commandId: ApiClient.newId());
      ref.invalidate(profileProvider);
      if (mounted) showSnack(context, 'Đã cập nhật hồ sơ');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showErrorDialog(context, e.message);
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  Future<void> _photo() async {
    final has = ref.read(avatarProvider).value != null;
    final action = await showChoiceSheet<_PhotoAction>(
      context,
      title: 'Ảnh đại diện',
      options: [
        const ChoiceOption(
          value: _PhotoAction.camera,
          label: 'Chụp ảnh',
          icon: Symbols.photo_camera_rounded,
        ),
        const ChoiceOption(
          value: _PhotoAction.gallery,
          label: 'Chọn từ thư viện',
          icon: Symbols.photo_library_rounded,
        ),
        if (has)
          const ChoiceOption(
            value: _PhotoAction.remove,
            label: 'Xóa ảnh',
            icon: Symbols.delete_rounded,
          ),
      ],
      footnote: 'Ảnh chỉ lưu trên máy này.',
    );
    if (action == null || !mounted) return;
    final avatar = ref.read(avatarProvider.notifier);
    try {
      switch (action) {
        case _PhotoAction.camera:
          if (await avatar.pick(ImageSource.camera) && mounted) {
            showSnack(context, 'Đã cập nhật ảnh đại diện');
          }
        case _PhotoAction.gallery:
          if (await avatar.pick(ImageSource.gallery) && mounted) {
            showSnack(context, 'Đã cập nhật ảnh đại diện');
          }
        case _PhotoAction.remove:
          await avatar.remove();
          if (mounted) showSnack(context, 'Đã xóa ảnh đại diện');
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      await showErrorDialog(
        context,
        e.code.contains('access_denied')
            ? 'MoMa chưa được cấp quyền dùng máy ảnh hoặc thư viện ảnh.'
            : 'Không lấy được ảnh. Vui lòng thử lại.',
      );
    } on Exception {
      if (mounted) {
        await showErrorDialog(context, 'Không lưu được ảnh. Vui lòng thử lại.');
      }
    }
  }

  Future<void> _signOut() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Đăng xuất',
      message: 'Bạn sẽ cần đăng nhập lại để dùng MoMa trên máy này.',
      confirmLabel: 'Đăng xuất',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(ownerAccountProvider).signOut();
    } on Exception {
      if (mounted) {
        await showErrorDialog(
          context,
          'Không đăng xuất được. Vui lòng thử lại.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final account = ref.watch(ownerAccountProvider);
    final profileAsync = ref.watch(profileProvider);
    final profile = profileAsync.value;
    if (!_nameLoaded && profile != null) {
      _name.text = (profile['display_name'] as String?) ?? '';
      _nameLoaded = true;
    }
    final name = (profile?['display_name'] as String?)?.trim() ?? '';
    final email = account.email ?? '';
    final since = _parseDate(
      profile?['created_at'] as String? ?? account.createdAt,
    );
    return Scaffold(
      body: MomaPage(
        title: 'Hồ sơ',
        showBack: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Center(
              child: Semantics(
                button: true,
                label: 'Đổi ảnh đại diện',
                child: GestureDetector(
                  onTap: _photo,
                  child: Stack(
                    children: [
                      OwnerAvatar(size: 104, borderColor: pal.surface),
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: MomaColors.emerald,
                            shape: BoxShape.circle,
                            border: Border.all(color: pal.surface, width: 2),
                          ),
                          child: const Icon(
                            Symbols.photo_camera_rounded,
                            color: Colors.white,
                            size: 17,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              name.isNotEmpty ? name : 'Chủ sở hữu',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: pal.ink,
              ),
            ),
            if (email.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      email,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: pal.muted),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sao chép email',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: email));
                      if (context.mounted) {
                        showSnack(context, 'Đã sao chép email');
                      }
                    },
                    icon: Icon(Symbols.content_copy_rounded, color: pal.muted),
                  ),
                ],
              ),
            if (since != null)
              Text(
                'Thành viên từ ${dateLabel(since)}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: pal.muted),
              ),
            const SizedBox(height: 20),
            const _Label('Thông tin cá nhân'),
            _Card(
              child: profile == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: profileAsync.hasError
                            ? Text(
                                'Chưa tải được hồ sơ. Vui lòng thử lại sau.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: pal.muted,
                                ),
                              )
                            : const CircularProgressIndicator(),
                      ),
                    )
                  : Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LabeledField(
                            label: 'Tên hiển thị',
                            controller: _name,
                            required: true,
                            validator: V.displayName,
                            maxLength: 80,
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _save(),
                          ),
                          const SizedBox(height: 16),
                          ActionButtons(
                            primaryLabel: 'Lưu',
                            busy: _saving,
                            onPrimary: _save,
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            const _Label('Bảo mật'),
            _Card(
              padding: EdgeInsets.zero,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: const Icon(
                  Symbols.lock_rounded,
                  color: MomaColors.emerald,
                ),
                title: const Text(
                  'Đổi mật khẩu',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                subtitle: const Text(
                  'Cần mật khẩu hiện tại để xác nhận',
                  style: TextStyle(fontSize: 13),
                ),
                trailing: Icon(Symbols.chevron_right_rounded, color: pal.muted),
                onTap: () => showFormSheet<void>(
                  context,
                  (_) => const ChangePasswordSheet(),
                ),
              ),
            ),
            const SizedBox(height: 28),
            OutlinedButton.icon(
              onPressed: _signOut,
              style: OutlinedButton.styleFrom(
                foregroundColor: MomaColors.expense,
                side: const BorderSide(color: MomaColors.expense),
              ),
              icon: const Icon(Symbols.logout_rounded),
              label: const Text('Đăng xuất'),
            ),
          ],
        ),
      ),
    );
  }

  static DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toLocal();
}

/// Password change: verifies the current password, then sets the new one. Failures open a modal.
class ChangePasswordSheet extends ConsumerStatefulWidget {
  const ChangePasswordSheet({super.key});

  @override
  ConsumerState<ChangePasswordSheet> createState() =>
      _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<ChangePasswordSheet> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _showCurrent = false;
  bool _showNext = false;
  bool _showAgain = false;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  String? _newValidator(String? v) {
    final base = V.newPassword(v);
    if (base != null) return base;
    if (v == _current.text) return 'Mật khẩu mới cần khác mật khẩu hiện tại.';
    return null;
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(ownerAccountProvider)
          .changePassword(current: _current.text, next: _next.text);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Đã đổi mật khẩu')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await showErrorDialog(context, e.message, title: 'Chưa đổi được');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Widget _eye(bool shown, VoidCallback toggle) => IconButton(
    tooltip: shown ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
    onPressed: toggle,
    icon: Icon(
      shown ? Symbols.visibility_off_rounded : Symbols.visibility_rounded,
    ),
  );

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Đổi mật khẩu',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: context.pal.ink,
          ),
        ),
        const SizedBox(height: 16),
        LabeledField(
          label: 'Mật khẩu hiện tại',
          controller: _current,
          required: true,
          obscure: !_showCurrent,
          validator: V.currentPassword,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.next,
          suffix: _eye(
            _showCurrent,
            () => setState(() => _showCurrent = !_showCurrent),
          ),
        ),
        const SizedBox(height: 14),
        LabeledField(
          label: 'Mật khẩu mới',
          controller: _next,
          required: true,
          obscure: !_showNext,
          validator: _newValidator,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.next,
          suffix: _eye(_showNext, () => setState(() => _showNext = !_showNext)),
        ),
        const SizedBox(height: 14),
        LabeledField(
          label: 'Nhập lại mật khẩu mới',
          controller: _again,
          required: true,
          obscure: !_showAgain,
          validator: V.sameAs(
            () => _next.text,
            'Mật khẩu nhập lại không khớp.',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          suffix: _eye(
            _showAgain,
            () => setState(() => _showAgain = !_showAgain),
          ),
        ),
        const SizedBox(height: 20),
        ActionButtons(
          primaryLabel: 'Đổi mật khẩu',
          busy: _busy,
          onPrimary: _submit,
          secondaryLabel: 'Hủy',
          onSecondary: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: context.pal.muted,
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: context.pal.surface,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}
