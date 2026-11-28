import { describe, expect, it } from "vitest";
import { analyzeBill, computeSplit, groupKey, matchContact } from "../../src/modules/ai/bill";

const SOLO_COFFEE = `HIGHLANDS COFFEE
Ngày 28/11/2026 07:45
Phin sữa đá 1 39.000
Tổng cộng 39.000`;

const SUPERMARKET = `BÁCH HÓA XANH
Sữa tươi Vinamilk 2 64.000
Mì Hảo Hảo 10 45.000
Dầu gội Clear 1 120.000
Trứng gà 10 quả 1 38.000
Tổng tiền 267.000`;

const HOTPOT = `QUÁN LẨU THÁI TOMYUM
Bàn số 12
Số khách: 4
Lẩu thái hải sản 1 389.000
Bò Mỹ 2 220.000
Rau nấm thập cẩm 2 90.000
Bia Tiger 6 150.000
Tổng cộng 849.000`;

const KARAOKE = `KARAOKE NICE
Phòng VIP 3 giờ 1 450.000
Trái cây dĩa 1 120.000
Bia Heineken 12 360.000
Nước suối 2 20.000
Thanh toán 950.000`;

const MIXED = `NHÀ HÀNG CƠM NIÊU
Cơm niêu 3 135.000
Canh chua cá 1 85.000
Trà đá 3 15.000
Bia Sài Gòn 2 40.000
Tổng cộng 275.000`;

describe("analyzeBill", () => {
  it("solo coffee: record only, no split question", () => {
    const a = analyzeBill(SOLO_COFFEE);
    expect(a.total).toBe(39000);
    expect(a.purpose).toBe("EATOUT");
    expect(a.people).toBe(1);
    expect(a.ask).toBe(false);
  });

  it("supermarket: personal necessities, never asks", () => {
    const a = analyzeBill(SUPERMARKET);
    expect(a.total).toBe(267000);
    expect(a.purpose).toBe("PERSONAL");
    expect(a.people).toBe(1);
    expect(a.ask).toBe(false);
    expect(a.reason).toContain("cá nhân");
  });

  it("hotpot with printed guest count: group of 4, asks, explains why", () => {
    const a = analyzeBill(HOTPOT);
    expect(a.total).toBe(849000);
    expect(a.purpose).toBe("EATOUT");
    expect(a.people).toBe(4);
    expect(a.basis).toBe("pax");
    expect(a.ask).toBe(true);
    expect(a.reason).toContain("4 khách");
  });

  it("karaoke group: entertainment, headcount from drinks/beers", () => {
    const a = analyzeBill(KARAOKE);
    expect(a.total).toBe(950000);
    expect(a.purpose).toBe("ENTERTAINMENT");
    expect(a.people).toBeGreaterThanOrEqual(3);
    expect(a.ask).toBe(true);
  });

  it("mixed bill: 3 mains + 3 drinks -> 3 people, items listed for per-item split", () => {
    const a = analyzeBill(MIXED);
    expect(a.total).toBe(275000);
    expect(a.people).toBe(3);
    expect(a.ask).toBe(true);
    expect(a.items.map((i) => i.qty)).toEqual([3, 1, 3, 2]);
    expect(a.items[3]?.name.toLowerCase()).toContain("bia");
  });

  it("learned 'không chia' for a purpose lowers the ask", () => {
    const a = analyzeBill(HOTPOT, { noSplit: new Set(["EATOUT"]) });
    expect(a.people).toBe(4);
    expect(a.ask).toBe(false);
    expect(a.reason).toContain("thường không chia");
  });
});

describe("computeSplit", () => {
  it("owner example: 1.600.000 for 3 incl. owner -> others 535.000, owner 530.000", () => {
    const s = computeSplit(1_600_000, ["Nam", "Lan"], { rounding: 5000 });
    expect(s).toEqual([
      { who: "Nam", amount: 535_000 },
      { who: "Lan", amount: 535_000 },
      { who: null, amount: 530_000 },
    ]);
  });

  it("sum always equals the total; exact rounding; extras for one person", () => {
    const exact = computeSplit(1_000_000, ["A", "B"], { rounding: 0 });
    expect(exact.reduce((a, s) => a + s.amount, 0)).toBe(1_000_000);
    const extra = computeSplit(275_000, ["Nam", "Huy"], { rounding: 1000, extras: { Huy: 40_000 } });
    expect(extra.reduce((a, s) => a + s.amount, 0)).toBe(275_000);
    expect(extra.find((s) => s.who === "Huy")!.amount).toBeGreaterThan(extra.find((s) => s.who === "Nam")!.amount);
  });

  it("without the owner the last person takes the remainder", () => {
    const s = computeSplit(100_000, ["A", "B", "C"], { includeOwner: false, rounding: 5000 });
    expect(s.reduce((a, x) => a + x.amount, 0)).toBe(100_000);
    expect(s.every((x) => x.who !== null)).toBe(true);
  });

  it("refuses nonsense", () => {
    expect(computeSplit(0, ["A"])).toEqual([]);
    expect(computeSplit(100_000, [])).toEqual([]);
    expect(computeSplit(100_000, ["A"], { extras: { A: 200_000 } })).toEqual([]);
  });
});

describe("names and groups", () => {
  const contacts = [
    { id: "1", alias: "Nam" },
    { id: "2", alias: "Lan Anh" },
    { id: "3", alias: "Huy" },
  ];
  it("matches exact, accent-insensitive and partial names", () => {
    expect(matchContact("nam", contacts)?.id).toBe("1");
    expect(matchContact("Lan", contacts)?.id).toBe("2");
    expect(matchContact("HUY", contacts)?.id).toBe("3");
    expect(matchContact("Tuấn", contacts)).toBeUndefined();
  });
  it("group key is order- and accent-insensitive", () => {
    expect(groupKey(["Nam", "Lan"])).toBe(groupKey(["lan", "NAM"]));
  });
});
