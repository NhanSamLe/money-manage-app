import 'package:material_ui/material_ui.dart';

part 'brand_data.g.dart';

enum BrandKind { bank, wallet }

/// How a logo asset is drawn: [tile] = square app-icon artwork that fills the
/// badge; [wordmark] = wide logo drawn padded on a white rounded square.
enum BrandLogoStyle { tile, wordmark }

/// A Vietnamese bank or e-wallet with its bundled official logo.
class Brand {
  const Brand({
    required this.code,
    required this.bin,
    required this.shortName,
    required this.fullName,
    required this.kind,
    required this.asset,
    required this.style,
    required this.aliases,
    this.androidPackage,
  });

  /// VietQR/NAPAS bank code (upper-case, `_` instead of spaces), e.g. `VCB`.
  final String code;

  /// NAPAS BIN (6 digits) or null for wallets outside the VietQR list.
  final String? bin;
  final String shortName;
  final String fullName;
  final BrandKind kind;
  final String asset;
  final BrandLogoStyle style;

  /// Lower-case names / common spellings (matched diacritic-insensitively).
  final List<String> aliases;
  final String? androidPackage;

  @override
  String toString() => 'Brand($code)';
}

/// Lower-cases, strips Vietnamese diacritics (đ -> d) and drops every
/// non-alphanumeric character: "Ngân hàng MB Bank" -> "nganhangmbbank".
String normalizeBrandKey(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    final m = _fold[c] ?? c;
    final u = m.codeUnitAt(0);
    if ((u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x7a)) b.write(m);
  }
  return b.toString();
}

const _groups = {
  'a': 'àáảãạăằắẳẵặâầấẩẫậ',
  'e': 'èéẻẽẹêềếểễệ',
  'i': 'ìíỉĩị',
  'o': 'òóỏõọôồốổỗộơờớởỡợ',
  'u': 'ùúủũụưừứửữự',
  'y': 'ỳýỷỹỵ',
  'd': 'đ',
};
final Map<String, String> _fold = {
  for (final e in _groups.entries)
    for (final ch in e.value.split('')) ch: e.key,
};

class _Index {
  _Index() {
    for (final b in kBrands) {
      byCode[b.code.toLowerCase()] = b;
      if (b.bin != null) byBin[b.bin!] = b;
      final p = b.androidPackage;
      if (p != null) byPackage[p.toLowerCase()] = b;
      for (final a in b.aliases) {
        final k = normalizeBrandKey(a);
        if (k.isNotEmpty) byAlias.putIfAbsent(k, () => b);
      }
    }
    // Longest first so "pvcombankpay" wins over "pvcombank" in substring search.
    containable = byAlias.keys.where((k) => k.length >= 4).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
  }
  final byCode = <String, Brand>{};
  final byBin = <String, Brand>{};
  final byPackage = <String, Brand>{};
  final byAlias = <String, Brand>{};
  late final List<String> containable;
}

final _index = _Index();

/// Extra Android packages (besides each brand's main app) that identify a brand.
const _extraPackages = {
  'vn.com.lpb.lienviet24h': 'LPB',
  'vn.shb.mbanking': 'SHB',
};

/// Finds the brand for whatever identifier a screen has. Checked in order:
/// [package] (Android app id), [bin] (NAPAS BIN), [code] (VietQR code), then
/// [institution] (free text: exact alias first, then the longest alias of 4+
/// chars contained in it). Matching ignores case, spaces and diacritics.
Brand? brandFor({
  String? institution,
  String? bin,
  String? code,
  String? package,
}) {
  final i = _index;
  if (package != null && package.trim().isNotEmpty) {
    final p = package.trim().toLowerCase();
    final b = i.byPackage[p];
    if (b != null) return b;
    final extra = _extraPackages[p];
    if (extra != null) return i.byCode[extra.toLowerCase()];
  }
  if (bin != null) {
    final b = i.byBin[bin.trim()];
    if (b != null) return b;
  }
  if (code != null && code.trim().isNotEmpty) {
    final c = code.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final b = i.byCode[c] ?? i.byAlias[normalizeBrandKey(code)];
    if (b != null) return b;
  }
  if (institution != null) {
    final k = normalizeBrandKey(institution);
    if (k.isEmpty) return null;
    final exact = i.byAlias[k];
    if (exact != null) return exact;
    for (final a in i.containable) {
      if (k.contains(a)) return i.byAlias[a];
    }
  }
  return null;
}

/// Official logo of [brand] in a [size] x [size] rounded square: app-icon
/// artwork fills the square; wide wordmarks sit padded on white with a subtle
/// border. Use wherever a bank / wallet is shown (pickers, lists, QR pages).
class BrandLogo extends StatelessWidget {
  const BrandLogo(this.brand, {super.key, this.size = 44});
  final Brand brand;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.26);
    final tile = brand.style == BrandLogoStyle.tile;
    return Semantics(
      label: brand.shortName,
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(tile ? 0 : size * 0.1),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: radius,
          border: Border.all(color: const Color(0x1F000000), width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.asset(
          brand.asset,
          fit: tile ? BoxFit.cover : BoxFit.contain,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => Center(
            child: Icon(
              brand.kind == BrandKind.wallet
                  ? Icons.account_balance_wallet_rounded
                  : Icons.account_balance_rounded,
              size: size * 0.5,
              color: const Color(0xFF21896E),
            ),
          ),
        ),
      ),
    );
  }
}
