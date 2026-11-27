import { describe, expect, it } from "vitest";
import { crc16, vietQrPayload } from "../../src/modules/bank/vietqr";

describe("VietQR payload", () => {
  it("CRC-16/CCITT-FALSE matches the standard check value", () => {
    expect(crc16("123456789")).toBe("29B1");
  });

  it("builds a static code (no amount) with bank BIN and account number", () => {
    const p = vietQrPayload({ bin: "970436", accountNumber: "1017588888" });
    expect(p.startsWith("000201010211")).toBe(true);
    expect(p).toContain("A000000727");
    expect(p).toContain("0006970436");
    expect(p).toContain("01101017588888");
    expect(p).toContain("QRIBFTTA");
    expect(p).toContain("5303704");
    expect(p).toContain("5802VN");
    expect(p.slice(-8, -4)).toBe("6304".length ? "6304" : "");
    expect(p.slice(-4)).toBe(crc16(p.slice(0, -4)));
  });

  it("builds a dynamic code with amount and an ASCII note", () => {
    const p = vietQrPayload({ bin: "970436", accountNumber: "1017588888", amount: 150000, note: "Tiền cà phê Đà Lạt" });
    expect(p.startsWith("000201010212")).toBe(true);
    expect(p).toContain("5406150000");
    expect(p).toContain("Tien ca phe Da Lat");
    expect(p.slice(-4)).toBe(crc16(p.slice(0, -4)));
  });

  it("refuses malformed bank data and ignores unusable amounts", () => {
    expect(() => vietQrPayload({ bin: "12", accountNumber: "123456" })).toThrow();
    expect(() => vietQrPayload({ bin: "970436", accountNumber: "12 34" })).toThrow();
    expect(vietQrPayload({ bin: "970436", accountNumber: "123456", amount: -5 })).toContain("010211");
    expect(vietQrPayload({ bin: "970436", accountNumber: "123456", amount: 1.5 })).toContain("010211");
  });
});
