import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/theme_mode.dart';
import '../../core/account_presets.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/money/money.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../../core/ui/actions.dart';
import '../../core/ui/labeled_field.dart';
import '../../core/validators.dart';
import '../../core/widgets.dart';
import '../accounts/add_account_sheet.dart';
import '../guide/guide_content.dart';

const _stepTitles = [
  'Hồ sơ',
  'Tài khoản',
  'Kiểm tra số dư',
  'Nguồn dữ liệu',
  'Tùy chọn',
  'Hoàn tất',
];

/// First-run setup wizard (design "Thiết lập lần đầu"): six guided steps from profile to a working book,
/// ending with a short how-to. Everything but the account is skippable; each step explains why it matters.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  int _step = 0;
  bool _busy = false;
  bool _nameLoaded = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_busy) return;
    if (_step == 0) {
      if (!(_form.currentState?.validate() ?? false)) return;
      await _saveName();
      if (!mounted) return;
    }
    if (_step == 1 && (ref.read(accountsProvider).value ?? const []).isEmpty) {
      await showErrorDialog(
        context,
        'Hãy thêm ít nhất một tài khoản để bắt đầu ghi giao dịch.',
        title: 'Chưa có tài khoản',
      );
      return;
    }
    if (_step == _stepTitles.length - 1) {
      if (mounted) context.go('/home');
      return;
    }
    setState(() => _step++);
  }

  Future<void> _saveName() async {
    final profile = ref.read(profileProvider).value;
    final current = (profile?['display_name'] as String?)?.trim() ?? '';
    final wanted = _name.text.trim();
    if (profile == null || wanted == current) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).command('PROFILE_UPDATE', {
        'expected_version': profile['version'],
        'display_name': wanted,
      }, commandId: ApiClient.newId());
      ref.invalidate(profileProvider);
    } on ApiException catch (e) {
      if (mounted) await showErrorDialog(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final profile = ref.watch(profileProvider).value;
    if (!_nameLoaded && profile != null) {
      _name.text = (profile['display_name'] as String?) ?? '';
      _nameLoaded = true;
    }
    final last = _step == _stepTitles.length - 1;
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: pal.surface,
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Thiết lập ban đầu',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: pal.ink,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.go('/home'),
                        child: const Text('Để sau'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _Stepper(step: _step),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _body(context),
                ),
              ),
            ),
            Container(
              color: pal.surface,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: ActionButtons(
                primaryLabel: last ? 'Vào MoMa' : 'Tiếp tục',
                onPrimary: _next,
                secondaryLabel: _step > 0 && !last ? 'Quay lại' : null,
                onSecondary: () => setState(() => _step--),
                busy: _busy,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (_step) {
      case 0:
        return _profile(context);
      case 1:
        return _accounts(context);
      case 2:
        return _balances(context);
      case 3:
        return _sources(context);
      case 4:
        return _options(context);
      default:
        return _finish(context);
    }
  }

  Widget _head(BuildContext context, String title, String sub) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: context.pal.ink,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        sub,
        style: TextStyle(fontSize: 14, height: 1.45, color: context.pal.muted),
      ),
      const SizedBox(height: 18),
    ],
  );

  // ---------------------------------------------------------------- 1 profile
  Widget _profile(BuildContext context) => Form(
    key: _form,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _head(
          context,
          'Chào mừng bạn đến với MoMa',
          'Chỉ vài bước để sổ tài chính của bạn sẵn sàng. Trước hết hãy xác nhận tên MoMa sẽ dùng để chào bạn.',
        ),
        LabeledField(
          label: 'Tên hiển thị',
          hint: 'Nhập tên của bạn',
          controller: _name,
          icon: Symbols.person_rounded,
          required: true,
          textCapitalization: TextCapitalization.words,
          validator: V.displayName,
        ),
        const SizedBox(height: 16),
        const _Note(
          icon: Symbols.lock_rounded,
          text: 'MoMa chỉ có một chủ sở hữu là bạn. Dữ liệu được lưu trong tài khoản riêng của bạn và không chia sẻ.',
        ),
      ],
    ),
  );

  // -------------------------------------------------------------- 2 accounts
  Widget _accounts(BuildContext context) {
    final pal = context.pal;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final added = {for (final a in accounts) a.institution.toLowerCase()};
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _head(
          context,
          'Tiền của bạn đang ở đâu?',
          'Thêm nơi bạn đang giữ tiền: tiền mặt, tài khoản ngân hàng, ví điện tử. Chạm vào một mục để thêm, nhập số dư hiện tại nếu bạn biết.',
        ),
        for (final g in accountPresetGroups) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              g,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: pal.muted,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in accountPresets.where((p) => p.group == g))
                _PresetTile(
                  preset: p,
                  added: added.contains(p.institution.toLowerCase()),
                  onTap: () async {
                    await showAddAccountSheet(context, preset: p);
                    ref.invalidate(accountsProvider);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: () async {
            await showAddAccountSheet(context);
            ref.invalidate(accountsProvider);
          },
          icon: const Icon(Symbols.add_rounded),
          label: const Text('Thêm tài khoản khác'),
        ),
        const SizedBox(height: 12),
        _Note(
          icon: Symbols.info_rounded,
          text: accounts.isEmpty
              ? 'Bạn cần ít nhất một tài khoản để ghi giao dịch. Tiền mặt là lựa chọn nhanh nhất.'
              : 'Đã thêm ${accounts.length} tài khoản. Bạn có thể thêm hoặc sửa sau trong Cài đặt, mục Tài khoản.',
        ),
      ],
    );
  }

  // --------------------------------------------------------------- 3 balances
  Widget _balances(BuildContext context) {
    final pal = context.pal;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _head(
          context,
          'Kiểm tra số dư đầu kỳ',
          'MoMa tính tài sản từ số dư bạn nhập khi thêm tài khoản, cộng trừ theo từng giao dịch sau đó.',
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              for (final (i, a) in accounts.indexed) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      AccountBadge(
                        institution: a.institution,
                        kind: a.kind,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              accountKindLabel(a.kind),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: pal.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        a.balance == null ? 'Chưa biết' : formatVnd(a.balance!),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: a.balance == null
                              ? const Color(0xFFE0A100)
                              : pal.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                if (i < accounts.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Note(
          icon: Symbols.lightbulb_rounded,
          text: accounts.any((a) => a.balance == null)
              ? 'Tài khoản "Chưa biết" chưa được tính vào tài sản ròng. Muốn có số dư đúng, hãy lưu trữ tài khoản đó rồi thêm lại với số dư hiện tại.'
              : 'Số dư đã đầy đủ. Từ giờ mỗi khoản thu, chi, chuyển khoản sẽ tự cập nhật số dư.',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 4 sources
  Widget _sources(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      _head(
        context,
        'Nguồn dữ liệu giao dịch',
        'Hiện tại MoMa ghi nhận giao dịch qua ba cách bạn chủ động. Tự động đọc thông báo ngân hàng và kết nối API sẽ có ở bản sau.',
      ),
      const _SourceRow(
        icon: Symbols.edit_note_rounded,
        color: Color(0xFF1B8A5A),
        title: 'Nhập tay hoặc gõ câu tự nhiên',
        text: 'Bấm nút + rồi gõ "ăn trưa 65k". Nhanh và chính xác nhất.',
        ready: true,
      ),
      const _SourceRow(
        icon: Symbols.auto_awesome_rounded,
        color: Color(0xFF8B5CF6),
        title: 'Trợ lý AI',
        text: 'Nhắn bằng lời thường, bạn xác nhận rồi mới ghi vào sổ.',
        ready: true,
      ),
      const _SourceRow(
        icon: Symbols.upload_file_rounded,
        color: Color(0xFF2F80ED),
        title: 'Nhập sao kê CSV',
        text: 'Đưa lịch sử giao dịch từ file sao kê ngân hàng (Cài đặt, mục Dữ liệu).',
        ready: true,
      ),
      const _SourceRow(
        icon: Symbols.account_balance_rounded,
        color: Color(0xFF64748B),
        title: 'API ngân hàng',
        text: 'Kết nối trực tiếp để đồng bộ tự động.',
        ready: false,
      ),
      const _SourceRow(
        icon: Symbols.notifications_rounded,
        color: Color(0xFF64748B),
        title: 'Thông báo Android',
        text: 'Đọc thông báo giao dịch từ ứng dụng ngân hàng, ví điện tử.',
        ready: false,
      ),
    ],
  );

  // ----------------------------------------------------------------- 5 options
  Widget _options(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final pal = context.pal;
    const opts = [
      (
        ThemeMode.light,
        'Sáng',
        'Dễ nhìn ngoài trời',
        Symbols.light_mode_rounded,
      ),
      (
        ThemeMode.dark,
        'Tối',
        'Dịu mắt khi ít ánh sáng',
        Symbols.dark_mode_rounded,
      ),
      (
        ThemeMode.system,
        'Theo hệ thống',
        'Tự đổi theo điện thoại',
        Symbols.brightness_6_rounded,
      ),
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _head(
          context,
          'Tùy chọn giao diện',
          'Chọn giao diện bạn thấy dễ nhìn. Bạn có thể đổi lại bất cứ lúc nào trong Cài đặt.',
        ),
        Container(
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              for (final (i, o) in opts.indexed) ...[
                ListTile(
                  onTap: () => ref.read(themeModeProvider.notifier).set(o.$1),
                  leading: Icon(o.$4, color: MomaColors.emerald),
                  title: Text(
                    o.$2,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(o.$3),
                  trailing: mode == o.$1
                      ? const Icon(
                          Symbols.check_circle_rounded,
                          color: MomaColors.emerald,
                        )
                      : Icon(
                          Symbols.radio_button_unchecked_rounded,
                          color: pal.line,
                        ),
                ),
                if (i < opts.length - 1) const Divider(height: 1, indent: 16),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _Note(
          icon: Symbols.category_rounded,
          text: 'Danh mục thu chi (Ăn uống, Di chuyển, Lương...) đã có sẵn. Bạn thêm hoặc sửa trong Cài đặt, mục Danh mục.',
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 6 finish
  Widget _finish(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Center(
        child: Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [MomaColors.emerald, MomaColors.forest],
            ),
          ),
          child: const Icon(
            Symbols.check_rounded,
            color: Colors.white,
            size: 46,
          ),
        ),
      ),
      const SizedBox(height: 16),
      Center(
        child: Text(
          'Mọi thứ đã sẵn sàng',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: context.pal.ink,
          ),
        ),
      ),
      const SizedBox(height: 6),
      Center(
        child: Text(
          'Đây là cách dùng MoMa hằng ngày. Bạn có thể xem lại trong Cài đặt, mục Hướng dẫn sử dụng.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: context.pal.muted,
          ),
        ),
      ),
      const SizedBox(height: 20),
      const GuideCards(),
    ],
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Bước ${step + 1}/${_stepTitles.length}',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: MomaColors.emerald,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _stepTitles[step],
                style: TextStyle(fontSize: 13, color: pal.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < _stepTitles.length; i++) ...[
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < step
                      ? MomaColors.emerald
                      : (i == step ? pal.tint : pal.surfaceAlt),
                  border: i == step
                      ? Border.all(color: MomaColors.emerald, width: 1.6)
                      : null,
                ),
                child: i < step
                    ? const Icon(
                        Symbols.check_rounded,
                        size: 16,
                        color: Colors.white,
                      )
                    : Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: i == step ? MomaColors.emerald : pal.muted,
                        ),
                      ),
              ),
              if (i < _stepTitles.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: i < step ? MomaColors.emerald : pal.line,
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.added,
    required this.onTap,
  });
  final AccountPreset preset;
  final bool added;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final w = (MediaQuery.sizeOf(context).width - 40 - 16) / 3;
    return SizedBox(
      width: w,
      child: Material(
        color: added ? pal.tint : pal.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: added ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: added ? MomaColors.emerald : pal.line),
            ),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AccountBadge(
                      institution: preset.institution,
                      kind: preset.kind,
                      size: 42,
                    ),
                    if (added)
                      const Positioned(
                        right: -4,
                        bottom: -2,
                        child: CircleAvatar(
                          radius: 9,
                          backgroundColor: MomaColors.emerald,
                          child: Icon(
                            Symbols.check_rounded,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preset.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
                Text(
                  added ? 'Đã thêm' : 'Thêm',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: added ? MomaColors.emerald : pal.muted,
                    fontWeight: added ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.ready,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: ready ? pal.tint : pal.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        ready ? 'Có sẵn' : 'Sắp có',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: ready ? MomaColors.emerald : pal.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: TextStyle(fontSize: 13, height: 1.4, color: pal.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.tintSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: MomaColors.emerald, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, height: 1.45, color: pal.ink),
            ),
          ),
        ],
      ),
    );
  }
}
