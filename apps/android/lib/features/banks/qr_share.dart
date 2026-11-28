import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

/// Draws the same bank-style receive card as [ReceiveQrCard] without a widget tree (used by the home-screen widget,
/// which has no screen to capture): white card, bank logo + name, QR with the logo in the middle, holder, full
/// account number, optional amount and note, and the scan hint. Returns PNG bytes.
Future<Uint8List?> renderReceiveCard({
  required String payload,
  required String bank,
  required String holder,
  required String accountNumber,
  int? amount,
  String? note,
}) async {
  const w = 720.0;
  const pad = 56.0;
  const qrSize = 520.0;
  const ink = Color(0xFF0F2A22);
  final brand = brandFor(institution: bank);
  ui.Image? logo;
  if (brand != null) {
    try {
      final data = await rootBundle.load(brand.asset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
        targetWidth: 192,
      );
      logo = (await codec.getNextFrame()).image;
    } catch (_) {}
  }

  TextPainter text(
    String s, {
    double size = 30,
    FontWeight weight = FontWeight.w600,
    Color color = ink,
    double spacing = 0,
  }) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: spacing,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 2,
  )..layout(maxWidth: w - pad * 2);

  final title = text(bank, size: 36, weight: FontWeight.w800);
  final who = text(holder.toUpperCase(), size: 32, weight: FontWeight.w800);
  final number = text(accountNumber, size: 34, spacing: 2);
  final money = amount != null && amount > 0
      ? text(
          formatVnd(amount),
          size: 44,
          weight: FontWeight.w800,
          color: MomaColors.income,
        )
      : null;
  final memo = note != null && note.trim().isNotEmpty
      ? text(note.trim(), size: 26, color: const Color(0xFF5B6B65))
      : null;
  final hint = text(
    'Quét mã bằng ứng dụng ngân hàng hoặc ví bất kỳ',
    size: 22,
    weight: FontWeight.w500,
    color: const Color(0xFF8A9A94),
  );

  const logoSize = 64.0;
  var h = pad + logoSize + 28 + qrSize + 28 + who.height + 6 + number.height;
  if (money != null) h += 14 + money.height;
  if (memo != null) h += 8 + memo.height;
  h += 22 + hint.height + pad;

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  // Opaque white edge to edge: pasted into chat apps it never shows transparent corners.
  c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

  // Header: logo + bank name, centred together.
  var y = pad;
  final headW = (logo != null ? logoSize + 16 : 0) + title.width;
  var x = (w - headW) / 2;
  if (logo != null) {
    final dst = Rect.fromLTWH(x, y, logoSize, logoSize);
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(dst, const Radius.circular(16)));
    paintImage(canvas: c, rect: dst, image: logo, fit: BoxFit.contain);
    c.restore();
    x += logoSize + 16;
  }
  title.paint(c, Offset(x, y + (logoSize - title.height) / 2));
  y += logoSize + 28;

  // QR with the bank logo in the middle (level H keeps it scannable).
  c.save();
  c.translate((w - qrSize) / 2, y);
  QrPainter(
    data: payload,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.H,
    gapless: true,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.square,
      color: MomaColors.forest,
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.square,
      color: ink,
    ),
    embeddedImage: logo,
    embeddedImageStyle: const QrEmbeddedImageStyle(size: Size(104, 104)),
  ).paint(c, const Size(qrSize, qrSize));
  c.restore();
  y += qrSize + 28;

  void center(TextPainter p, double gap) {
    y += gap;
    p.paint(c, Offset((w - p.width) / 2, y));
    y += p.height;
  }

  center(who, 0);
  center(number, 6);
  if (money != null) center(money, 14);
  if (memo != null) center(memo, 8);
  center(hint, 22);

  final img = await rec.endRecording().toImage(w.toInt(), h.ceil());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
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

/// Copies the QR card itself as a picture (paste into Zalo, Messenger...), like bank apps do.
Future<void> copyQrImage(BuildContext context, GlobalKey key) async {
  final bytes = await captureQrPng(key);
  if (bytes == null || !context.mounted) return;
  var ok = false;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      ok =
          await const MethodChannel('moma/widgets')
              .invokeMethod<bool>('copyImage', {'png': bytes}) ??
          false;
    } catch (_) {}
  }
  if (!context.mounted) return;
  if (ok) {
    showSnack(context, 'Đã sao chép ảnh mã QR, dán vào Zalo/Messenger để gửi');
  } else {
    await showErrorDialog(
      context,
      'Không sao chép được ảnh. Bạn thử "Chia sẻ ảnh mã QR".',
    );
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
        value: 'copyimg',
        label: 'Sao chép ảnh mã QR',
        icon: Symbols.content_copy_rounded,
      ),
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
    case 'copyimg':
      await copyQrImage(context, boundaryKey);
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
    this.onCopyImage,
  });
  final VoidCallback? onCopyImage;
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
        if (onCopyImage != null)
          btn(Symbols.photo_library_rounded, 'Chép ảnh QR', onCopyImage!),
        btn(Symbols.content_copy_rounded, 'Sao chép STK', onCopyAccount),
        btn(Symbols.download_rounded, 'Lưu ảnh', onSave),
        btn(Symbols.share_rounded, 'Chia sẻ', onShare),
      ],
    );
  }
}
