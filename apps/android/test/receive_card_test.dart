import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moma/features/banks/qr_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders a bank-style receive card PNG for the widget copy', (
    tester,
  ) async {
    final bytes = await tester.runAsync(
      () => renderReceiveCard(
        payload:
            '00020101021138570010A000000727012700069704230113464141020040208QRIBFTTA53037045802VN6304ABCD',
        bank: 'TPBank',
        holder: 'Le Dao Nhan Sam',
        accountNumber: '46414102004',
        amount: 150000,
        note: 'Tien an trua',
      ),
    );
    expect(bytes, isNotNull);
    // PNG signature.
    expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(bytes.length, greaterThan(5000));
    final out = Platform.environment['MOMA_CARD_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
