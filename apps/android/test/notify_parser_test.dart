import 'package:flutter_test/flutter_test.dart';
import 'package:moma/features/notify_capture/parser.dart';

NotifyParse p(String pkg, String title, String text) =>
    parseBankNotification(package: pkg, title: title, text: text);

void main() {
  test('Vietcombank money in, balance ignored, Ref as description', () {
    final r = p(
      'com.VCB',
      'Thông báo VCB',
      'Số dư TK VCB 0011001234567 +1,500,000 VND lúc 28-11-2026 10:15:30. Số dư 12,345,678 VND. Ref MBVCB.123.NGUYEN VAN A chuyen tien',
    );
    expect(r.bank, 'Vietcombank');
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 1500000);
    expect(r.balance, 12345678);
    expect(r.description, 'MBVCB.123.NGUYEN VAN A chuyen tien');
    expect(r.isTransaction, isTrue);
  });

  test('MB Bank "GD: -50,000VND" with pipes', () {
    final r = p(
      'com.mbmobile',
      'Thông báo biến động số dư',
      'TK 0123xxx789|GD: -50,000VND 28/11/26 10:15|SD: 1,234,567VND|ND: thanh toan QR',
    );
    expect(r.direction, NotifyDirection.outflow);
    expect(r.amount, 50000);
    expect(r.balance, 1234567);
    expect(r.description, 'thanh toan QR');
  });

  test('Techcombank multi-line', () {
    final r = p(
      'vn.com.techcombank.bb.app',
      'Biến động số dư',
      'TK 1903xxxx5678\nSố tiền: +500,000 VND\nSố dư: 2,000,000 VND\nND: Chuyen tien an trua',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 500000);
    expect(r.balance, 2000000);
    expect(r.description, 'Chuyen tien an trua');
  });

  test('BIDV "-200.000VND" with dotted thousands', () {
    final r = p(
      'com.vnpay.bidv',
      'BIDV',
      'TK 1234567890 tai BIDV -200.000VND vao 10:15 28/11/2026. So du:5.000.000VND. ND: TT hoa don dien',
    );
    expect(r.direction, NotifyDirection.outflow);
    expect(r.amount, 200000);
    expect(r.balance, 5000000);
    expect(r.description, 'TT hoa don dien');
  });

  test('TPBank PS:+ / SD:', () {
    final r = p(
      'com.tpb.mb.gprsandroid',
      'TPBank',
      '(TPBank): 28/11/26;10:15\nTK: xxxx1234\nPS:+1.000.000VND\nSD: 3.000.000VND\nND: luong thang 11',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 1000000);
    expect(r.balance, 3000000);
    expect(r.description, 'luong thang 11');
  });

  test('ACB sign separated by a space, amount without currency', () {
    final r = p(
      'mobile.acb.com.vn',
      'ACB',
      'ACB: TK 123456(VND) - 300,000 luc 10:15 28/11/2026. So du 1,000,000. GD: CK den cua hang',
    );
    expect(r.direction, NotifyDirection.outflow);
    expect(r.amount, 300000);
    expect(r.balance, 1000000);
  });

  test('VietinBank labelled lines with "Thời gian giao dịch" date', () {
    final r = p(
      'com.vietinbank.ipay',
      'VietinBank',
      'Thời gian giao dịch: 28/11/2026 10:15\nTài khoản: 1234\nGiao dịch: +2,500,000VND\nSố dư hiện tại: 7,500,000VND\nNội dung: hoan tien don hang',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 2500000);
    expect(r.balance, 7500000);
    expect(r.description, 'hoan tien don hang');
  });

  test('MoMo received, direction from wording, "đ" suffix', () {
    final r = p(
      'com.mservice.momotransfer',
      'Nhận tiền thành công',
      'Bạn vừa nhận được 200.000đ từ NGUYEN VAN A. Lời nhắn: trả tiền cafe',
    );
    expect(r.bank, 'MoMo');
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 200000);
    expect(r.balance, isNull);
    expect(r.description, 'trả tiền cafe');
  });

  test('MoMo payment is money out', () {
    final r = p(
      'com.mservice.momotransfer',
      'Thanh toán thành công',
      'Bạn đã thanh toán 65.000đ cho Highlands Coffee. Số dư ví: 1.200.000đ',
    );
    expect(r.direction, NotifyDirection.outflow);
    expect(r.amount, 65000);
    expect(r.balance, 1200000);
  });

  test('ZaloPay received with "đ" after a space', () {
    final r = p(
      'vn.com.vng.zalopay',
      'ZaloPay',
      'Bạn đã nhận 100.000 đ từ Tran Thi B',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 100000);
  });

  test('a note saying "chuyen tien" does not flip an explicit sign', () {
    final r = p(
      'com.vnpay.vpbankonline',
      'VPBank',
      'TK 9876 +3,000,000VND. ND: chuyen tien thanh toan tien nha',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 3000000);
  });

  test('promotion or OTP is not a transaction', () {
    expect(
      p(
        'com.VCB',
        'Ưu đãi',
        'Giảm 50% khi thanh toán QR tại cửa hàng, hạn 30/11/2026',
      ).isTransaction,
      isFalse,
    );
    expect(
      p(
        'com.mbmobile',
        'OTP',
        'Ma OTP cua quy khach la 123456. Ma GD 998877',
      ).isTransaction,
      isFalse,
    );
  });
}
