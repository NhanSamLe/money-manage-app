import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/moma_theme.dart';
import '../../core/brands/brand_registry.dart';
import '../../core/money/money.dart';
import '../../core/sheets.dart';
import '../../core/widgets.dart';

/// Account number inside a VietQR (EMV) payload: tag 38 -> 01 -> 01.
String? vietQrAccountNumber(String payload) {
  Map<String, String> tlv(String s) {
    final out = <String, String>{};
    var i = 0;
    while (i + 4 <= s.length) {
      final tag = s.substring(i, i + 2);
      final len = int.tryParse(s.substring(i + 2, i + 4));
      if (len == null || i + 4 + len > s.length) break;
      out[tag] = s.substring(i + 4, i + 4 + len);
      i += 4 + len;
    }
    return out;
  }

  final merchant = tlv(payload)['38'];
  if (merchant == null) return null;
  final beneficiary = tlv(merchant)['01'];
  if (beneficiary == null) return null;
  final acc = tlv(beneficiary)['01'];
  return (acc == null || acc.isEmpty) ? null : acc;
}

/// Receive card: QR with the bank's logo in the middle (error correction H keeps it scannable), bank, holder,
/// account and amount. Wrapped in a RepaintBoundary so it can be saved / shared as a picture like bank apps do.
class ReceiveQrCard extends StatelessWidget {
  const ReceiveQrCard({
    super.key,
    required this.boundaryKey,
    required this.payload,
    required this.bank,
    required this.holder,
    required this.accountNumber,
    this.amount,
    this.note,
    this.onTapQr,
  });

  final GlobalKey boundaryKey;
  final String payload;
  final String bank;
  final String holder;
  final String accountNumber;
  final int? amount;
  final String? note;
  final VoidCallback? onTapQr;

  @override
  Widget build(BuildContext context) {
    final brand = brandFor(institution: bank);
    final logo = brand == null ? null : AssetImage(brand.asset);
    // Always printed on white so the saved image looks the same in light and dark mode.
    const ink = Color(0xFF0F2A22);
    return RepaintBoundary(
      key: boundaryKey,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (brand != null) ...[
                  BrandLogo(brand, size: 28),
                  const SizedBox(width: 8),
                ],
                Text(
                  bank,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: onTapQr,
              child: QrImageView(
                data: payload,
                size: 240,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.H,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: MomaColors.forest,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: ink,
                ),
                embeddedImage: logo,
                embeddedImageStyle: const QrEmbeddedImageStyle(
                  size: Size(48, 48),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              holder.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              accountNumber,
              style: const TextStyle(
                fontSize: 15,
                letterSpacing: 1.2,
                color: ink,
              ),
            ),
            if (amount != null && amount! > 0) ...[
              const SizedBox(height: 6),
              Text(
                formatVnd(amount!),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: MomaColors.income,
                ),
              ),
            ],
            if (note != null && note!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                note!.trim(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF5B6B65),
                ),
              ),
            ],
            const SizedBox(height: 10),
            const Text(
              'Quét mã bằng ứng dụng ngân hàng hoặc ví bất kỳ',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF8A9A94)),
            ),
          ],
        ),
      ),
    );
  }
}

/// PNG bytes of the card behind [key].
Future<Uint8List?> captureQrPng(GlobalKey key) async {
  final obj = key.currentContext?.findRenderObject();
  if (obj is! RenderRepaintBoundary) return null;
  final img = await obj.toImage(pixelRatio: 3);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

String _fileName() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'MoMa-QR-${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}.png';
}

Future<void> saveQrImage(BuildContext context, GlobalKey key) async {
  final bytes = await captureQrPng(key);
  if (bytes == null || !context.mounted) return;
  try {
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Lưu ảnh mã QR',
      fileName: _fileName(),
      bytes: bytes,
      mimeType: 'image/png',
    );
    if (uri != null && context.mounted) showSnack(context, 'Đã lưu ảnh mã QR');
  } catch (_) {
    if (context.mounted) {
      await showErrorDialog(
        context,
        'Không lưu được ảnh. Bạn thử dùng "Chia sẻ ảnh".',
      );
    }
  }
}

Future<void> shareQrImage(
  BuildContext context,
  GlobalKey key, {
  String? text,
}) async {
  final bytes = await captureQrPng(key);
  if (bytes == null || !context.mounted) return;
  final name = _fileName();
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: 'image/png')],
        fileNameOverrides: [name],
        text: text,
      ),
    );
  } catch (_) {
    if (context.mounted) {
      await showErrorDialog(context, 'Không chia sẻ được ảnh mã QR.');
    }
  }
}

Future<void> copyText(BuildContext context, String text, String done) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showSnack(context, done);
}

/// Tap on the QR: the quick actions bank apps offer.
Future<void> showQrActions(
  BuildContext context, {
  required GlobalKey boundaryKey,
  required String accountNumber,
  required String payload,
  String? shareText,
}) async {
  final v = await showChoiceSheet<String>(
    context,
    title: 'Mã QR nhận tiền',
    options: const [
      ChoiceOption(
        value: 'save',
        label: 'Lưu ảnh mã QR',
        icon: Symbols.download_rounded,
      ),
      ChoiceOption(
        value: 'share',
        label: 'Chia sẻ ảnh mã QR',
        icon: Symbols.share_rounded,
      ),
      ChoiceOption(
        value: 'acc',
        label: 'Sao chép số tài khoản',
        icon: Symbols.content_copy_rounded,
      ),
      ChoiceOption(
        value: 'payload',
        label: 'Sao chép nội dung mã',
        icon: Symbols.qr_code_rounded,
      ),
    ],
  );
  if (!context.mounted || v == null) return;
  switch (v) {
    case 'save':
      await saveQrImage(context, boundaryKey);
    case 'share':
      await shareQrImage(context, boundaryKey, text: shareText);
    case 'acc':
      await copyText(context, accountNumber, 'Đã sao chép số tài khoản');
    case 'payload':
      await copyText(context, payload, 'Đã sao chép nội dung mã QR');
  }
}

/// Three compact actions under the card.
class QrActionRow extends StatelessWidget {
  const QrActionRow({
    super.key,
    required this.onCopyAccount,
    required this.onSave,
    required this.onShare,
  });
  final VoidCallback onCopyAccount;
  final VoidCallback onSave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: MomaColors.emerald.withValues(alpha: 0.14),
                child: Icon(icon, color: MomaColors.emerald, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        btn(Symbols.content_copy_rounded, 'Sao chép STK', onCopyAccount),
        btn(Symbols.download_rounded, 'Lưu ảnh', onSave),
        btn(Symbols.share_rounded, 'Chia sẻ', onShare),
      ],
    );
  }
}
