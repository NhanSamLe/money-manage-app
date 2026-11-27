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

  group('MoMo (app, email, shared receipt)', () {
    test('real MoMo notification: money in with "kèm lời nhắn" and the sender in the title', () {
      final r = p(
        'com.mservice.momotransfer',
        'Nhận tiền chuyển khoản từ NGUYEN VAN B',
        'Số tiền 10.000 đ, kèm lời nhắn: "LE DAO NHAN SAM chuyen tien"',
      );
      expect(r.bank, 'MoMo');
      expect(r.direction, NotifyDirection.inflow);
      expect(r.amount, 10000);
      expect(r.description, 'LE DAO NHAN SAM chuyen tien');
      expect(r.counterparty, 'NGUYEN VAN B');
      expect(r.isTransaction, isTrue);
    });

    test('receipt "Chuyển tiền thành công 50.000đ" is money out', () {
      final r = p(momoPackage, '', 'Chuyển tiền thành công 50.000đ');
      expect(r.direction, NotifyDirection.outflow);
      expect(r.amount, 50000);
    });

    test('receipt "Thanh toán thành công -120.000đ" with "Số dư ví"', () {
      final r = p(
        momoPackage,
        '',
        'Thanh toán thành công -120.000đ\nSố dư ví: 1.234.000đ',
      );
      expect(r.direction, NotifyDirection.outflow);
      expect(r.amount, 120000);
      expect(r.balance, 1234000);
    });

    test('MoMo email: subject + snippet, amount from "Số tiền", code from "Mã giao dịch"', () {
      final r = p(
        momoPackage,
        'MoMo',
        'Giao dịch thành công\nBạn đã thanh toán thành công. Số tiền: 120.000 VND. Mã giao dịch: 43918273645. Dịch vụ: Highlands Coffee',
      );
      expect(r.direction, NotifyDirection.outflow);
      expect(r.amount, 120000);
      expect(r.txCode, '43918273645');
    });

    test('MoMo email "Chuyển tiền thành công" with -50.000đ', () {
      final r = p(
        momoPackage,
        'Ví MoMo',
        'Chuyển tiền thành công -50.000đ tới NGUYEN VAN C. Mã giao dịch: 51234567890',
      );
      expect(r.direction, NotifyDirection.outflow);
      expect(r.amount, 50000);
      expect(r.txCode, '51234567890');
    });

    test('MoMo email without an amount stays a non-transaction', () {
      final r = p(momoPackage, 'MoMo', 'Xác nhận giao dịch của bạn');
      expect(r.isTransaction, isFalse);
    });
  });

  group('account last 4 digits', () {
    test('"TK 1234", "TK xx1234", "tai khoan ...1234", full number', () {
      expect(p('com.VCB', '', 'TK 1234 +50,000VND').last4, '1234');
      expect(p('com.VCB', '', 'TK xx1234 -50,000VND').last4, '1234');
      expect(
        p('com.VCB', '', 'tai khoan ...5678 nhan +1,000VND').last4,
        '5678',
      );
      expect(
        p('com.vnpay.bidv', '', 'TK 1234567890 tai BIDV -200.000VND').last4,
        '7890',
      );
      expect(
        p('com.mbmobile', '', 'TK 0123xxx789|GD: -50,000VND').last4,
        isNull,
      );
    });
    test('the account number is never read as the amount', () {
      final r = p('com.VCB', '', 'TK 0451000123456 nhan duoc 75.000 VND');
      expect(r.amount, 75000);
      expect(r.last4, '3456');
    });
  });

  test('wallet / bank detection from shared text', () {
    expect(
      detectPackageFromText('Ví MoMo - Thanh toán thành công'),
      momoPackage,
    );
    expect(
      detectPackageFromText('ZaloPay: nhận 20.000đ'),
      'vn.com.vng.zalopay',
    );
    expect(
      detectPackageFromText('Techcombank: TK 1234 +50,000'),
      'vn.com.techcombank.bb.app',
    );
    expect(detectPackageFromText('xin chao'), isNull);
  });

  group('exact extras from the owner phone', () {
    test('MoMo money in, "₫" without and with a space, FT bank reference', () {
      for (final text in [
        'Số tiền 10.000₫, kèm lời nhắn: "LE DAO NHAN SAM chuyen FT26332327719412".',
        'Số tiền 10.000 ₫, kèm lời nhắn: "LE DAO NHAN SAM chuyen FT26332327719412".',
      ]) {
        final r = p(
          'com.mservice.momotransfer',
          'Nhận tiền chuyển khoản từ LE DAO NHAN SAM',
          text,
        );
        expect(r.direction, NotifyDirection.inflow);
        expect(r.amount, 10000);
        expect(r.description, 'LE DAO NHAN SAM chuyen FT26332327719412');
        expect(r.counterparty, 'LE DAO NHAN SAM');
        expect(r.bankRef, 'FT26332327719412');
      }
    });

    test(
      'TPBank with an empty title: time, last4, PS and SD (not SD KHA DUNG)',
      () {
        final r = p(
          'com.tpb.mb.gprsandroid',
          '',
          '(TPBank): 28/11/26;03:08\nTK: xxxx4102004\nPS:+4.000VND\nSD: 4.000VND\nSD KHA DUNG: 4.000VND',
        );
        expect(r.direction, NotifyDirection.inflow);
        expect(r.amount, 4000);
        expect(r.balance, 4000);
        expect(r.last4, '2004');
        expect(r.postedAt, DateTime(2026, 11, 28, 3, 8));
      },
    );
  });

  test('exact Vietcombank sample: comma thousands, full account number, time, balance, Ref', () {
    final r = p(
      'com.VCB',
      '',
      'Số dư TK VCB 1026746096 +4,000 VND lúc 28-11-2026 03:24:23. Số dư 13,684,007 VND. Ref 159036437923-LE DAO NHAN SAM chuyen tien qua MoMo-CHUYEN TIEN-OQCH000PN',
    );
    expect(r.direction, NotifyDirection.inflow);
    expect(r.amount, 4000);
    expect(r.accountNumber, '1026746096');
    expect(r.last4, '6096');
    expect(r.postedAt, DateTime(2026, 11, 28, 3, 24, 23));
    expect(r.balance, 13684007);
    expect(r.bankRef, '159036437923');
    expect(
      r.description,
      '159036437923-LE DAO NHAN SAM chuyen tien qua MoMo-CHUYEN TIEN-OQCH000PN',
    );
  });
}
