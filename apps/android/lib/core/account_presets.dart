import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

/// Ready-made accounts offered during setup so nobody has to type "Vietcombank" or "MoMo" by hand.
/// [kind] is the API account kind; [code] is the short badge text; [color] the brand-ish badge colour.
class AccountPreset {
  const AccountPreset({
    required this.group,
    required this.name,
    required this.institution,
    required this.kind,
    required this.code,
    required this.color,
  });
  final String group;
  final String name;
  final String institution;
  final String kind;
  final String code;
  final Color color;
}

const accountPresets = <AccountPreset>[
  AccountPreset(
    group: 'Tiền mặt',
    name: 'Tiền mặt',
    institution: 'Tiền mặt',
    kind: 'CASH',
    code: '₫',
    color: Color(0xFF1B8A5A),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Vietcombank',
    institution: 'Vietcombank',
    kind: 'BANK',
    code: 'VCB',
    color: Color(0xFF0B7A3E),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Techcombank',
    institution: 'Techcombank',
    kind: 'BANK',
    code: 'TCB',
    color: Color(0xFFD71920),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'MB Bank',
    institution: 'MB Bank',
    kind: 'BANK',
    code: 'MB',
    color: Color(0xFF1D3F95),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'BIDV',
    institution: 'BIDV',
    kind: 'BANK',
    code: 'BIDV',
    color: Color(0xFF00789D),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'VietinBank',
    institution: 'VietinBank',
    kind: 'BANK',
    code: 'CTG',
    color: Color(0xFF0B5AA5),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'ACB',
    institution: 'ACB',
    kind: 'BANK',
    code: 'ACB',
    color: Color(0xFF1B5FAA),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'VPBank',
    institution: 'VPBank',
    kind: 'BANK',
    code: 'VPB',
    color: Color(0xFF0F8F4F),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'TPBank',
    institution: 'TPBank',
    kind: 'BANK',
    code: 'TPB',
    color: Color(0xFF6C2C91),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Sacombank',
    institution: 'Sacombank',
    kind: 'BANK',
    code: 'STB',
    color: Color(0xFF0B5AA5),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Agribank',
    institution: 'Agribank',
    kind: 'BANK',
    code: 'AGR',
    color: Color(0xFFB2193B),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'MoMo',
    institution: 'MoMo',
    kind: 'WALLET',
    code: 'Mo',
    color: Color(0xFFAE2070),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'ZaloPay',
    institution: 'ZaloPay',
    kind: 'WALLET',
    code: 'Zalo',
    color: Color(0xFF0068FF),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'ViettelPay',
    institution: 'ViettelPay',
    kind: 'WALLET',
    code: 'VT',
    color: Color(0xFFE2231A),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'ShopeePay',
    institution: 'ShopeePay',
    kind: 'WALLET',
    code: 'SP',
    color: Color(0xFFEE4D2D),
  ),
  AccountPreset(
    group: 'Khác',
    name: 'Thẻ tín dụng',
    institution: 'Thẻ tín dụng',
    kind: 'CREDIT_CARD',
    code: 'CC',
    color: Color(0xFF475569),
  ),
  AccountPreset(
    group: 'Khác',
    name: 'Tiết kiệm',
    institution: 'Tiết kiệm',
    kind: 'SAVINGS',
    code: 'TK',
    color: Color(0xFF0E7490),
  ),
];

const accountPresetGroups = ['Tiền mặt', 'Ngân hàng', 'Ví điện tử', 'Khác'];

AccountPreset? presetForInstitution(String institution) {
  final k = institution.trim().toLowerCase();
  for (final p in accountPresets) {
    if (p.institution.toLowerCase() == k) return p;
  }
  return null;
}

/// Round badge with the institution's short code on its brand colour (no third-party logos are bundled).
class AccountBadge extends StatelessWidget {
  const AccountBadge({
    super.key,
    required this.institution,
    required this.kind,
    this.size = 44,
  });
  final String institution;
  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = presetForInstitution(institution);
    final color = p?.color ?? const Color(0xFF21896E);
    final code = p?.code;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: code != null
          ? Text(
              code,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: code.length > 3 ? size * 0.25 : size * 0.31,
              ),
            )
          : Icon(
              switch (kind) {
                'BANK' => Symbols.account_balance_rounded,
                'WALLET' => Symbols.account_balance_wallet_rounded,
                'CASH' => Symbols.payments_rounded,
                'SAVINGS' => Symbols.savings_rounded,
                'CREDIT_CARD' => Symbols.credit_card_rounded,
                _ => Symbols.wallet_rounded,
              },
              color: color,
              size: size * 0.5,
            ),
    );
  }
}
