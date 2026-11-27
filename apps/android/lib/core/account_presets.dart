import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import 'brands/brand_registry.dart';

export 'brands/brand_registry.dart' show Brand, BrandLogo, brandFor;

/// Ready-made accounts offered during setup so nobody has to type "Vietcombank" or "MoMo" by hand.
/// [kind] is the API account kind; [code] is a short label; [color] the brand-ish tint used for
/// icon badges; [brand] is the code in `brands/brand_registry.dart` whose official logo is shown.
class AccountPreset {
  const AccountPreset({
    required this.group,
    required this.name,
    required this.institution,
    required this.kind,
    required this.code,
    required this.color,
    this.brand,
  });
  final String group;
  final String name;
  final String institution;
  final String kind;
  final String code;
  final Color color;
  final String? brand;
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
    brand: 'VCB',
    kind: 'BANK',
    code: 'VCB',
    color: Color(0xFF0B7A3E),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Techcombank',
    institution: 'Techcombank',
    brand: 'TCB',
    kind: 'BANK',
    code: 'TCB',
    color: Color(0xFFD71920),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'MB Bank',
    institution: 'MB Bank',
    brand: 'MB',
    kind: 'BANK',
    code: 'MB',
    color: Color(0xFF1D3F95),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'BIDV',
    institution: 'BIDV',
    brand: 'BIDV',
    kind: 'BANK',
    code: 'BIDV',
    color: Color(0xFF00789D),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'VietinBank',
    institution: 'VietinBank',
    brand: 'ICB',
    kind: 'BANK',
    code: 'CTG',
    color: Color(0xFF0B5AA5),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'ACB',
    institution: 'ACB',
    brand: 'ACB',
    kind: 'BANK',
    code: 'ACB',
    color: Color(0xFF1B5FAA),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'VPBank',
    institution: 'VPBank',
    brand: 'VPB',
    kind: 'BANK',
    code: 'VPB',
    color: Color(0xFF0F8F4F),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'TPBank',
    institution: 'TPBank',
    brand: 'TPB',
    kind: 'BANK',
    code: 'TPB',
    color: Color(0xFF6C2C91),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Sacombank',
    institution: 'Sacombank',
    brand: 'STB',
    kind: 'BANK',
    code: 'STB',
    color: Color(0xFF0B5AA5),
  ),
  AccountPreset(
    group: 'Ngân hàng',
    name: 'Agribank',
    institution: 'Agribank',
    brand: 'VBA',
    kind: 'BANK',
    code: 'AGR',
    color: Color(0xFFB2193B),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'MoMo',
    institution: 'MoMo',
    brand: 'MOMO',
    kind: 'WALLET',
    code: 'Mo',
    color: Color(0xFFAE2070),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'ZaloPay',
    institution: 'ZaloPay',
    brand: 'ZALOPAY',
    kind: 'WALLET',
    code: 'Zalo',
    color: Color(0xFF0068FF),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'Viettel Money',
    institution: 'Viettel Money',
    brand: 'VTLMONEY',
    kind: 'WALLET',
    code: 'VT',
    color: Color(0xFFE2231A),
  ),
  AccountPreset(
    group: 'Ví điện tử',
    name: 'ShopeePay',
    institution: 'ShopeePay',
    brand: 'SHOPEEPAY',
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

/// Preset by institution text; falls back to the preset of the same brand so
/// older names (e.g. "ViettelPay" -> Viettel Money) still resolve.
AccountPreset? presetForInstitution(String institution) {
  final k = institution.trim().toLowerCase();
  for (final p in accountPresets) {
    if (p.institution.toLowerCase() == k) return p;
  }
  final b = brandFor(institution: institution);
  if (b == null) return null;
  for (final p in accountPresets) {
    if (p.brand == b.code) return p;
  }
  return null;
}

/// Account avatar. Cash always shows a banknote icon; otherwise the official
/// bank / wallet logo when [institution] (or [bin] / [package]) matches a known
/// brand, else a kind icon (bank building, wallet, piggy bank, card) - never letters.
class AccountBadge extends StatelessWidget {
  const AccountBadge({
    super.key,
    required this.institution,
    required this.kind,
    this.size = 44,
    this.bin,
    this.package,
  });
  final String institution;
  final String kind;
  final double size;

  /// NAPAS BIN of the bank (e.g. from SePay / VietQR), if known.
  final String? bin;

  /// Android package of the bank / wallet app (e.g. a captured notification).
  final String? package;

  @override
  Widget build(BuildContext context) {
    if (kind != 'CASH') {
      final b = brandFor(institution: institution, bin: bin, package: package);
      if (b != null) return BrandLogo(b, size: size);
    }
    final p = presetForInstitution(institution);
    final color = kind == 'CASH'
        ? const Color(0xFF1B8A5A)
        : p?.color ?? const Color(0xFF21896E);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(
        switch (kind) {
          'BANK' => Symbols.account_balance_rounded,
          'WALLET' => Symbols.account_balance_wallet_rounded,
          'CASH' => Symbols.payments_rounded,
          'SAVINGS' => Symbols.savings_rounded,
          'CREDIT_CARD' => Symbols.credit_card_rounded,
          _ => Symbols.wallet_rounded,
        },
        fill: 1,
        color: color,
        size: size * 0.52,
      ),
    );
  }
}
