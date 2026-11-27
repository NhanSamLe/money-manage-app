// VietQR (NAPAS 247 fast transfer) payload, EMVCo merchant-presented QR. Any Vietnamese banking app or e-wallet can
// scan the result and prefill the transfer: bank, account number, optional amount and note.

function tlv(id: string, value: string): string {
  return `${id}${String(value.length).padStart(2, "0")}${value}`;
}

/** CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) as required by EMVCo tag 63. */
export function crc16(s: string): string {
  let crc = 0xffff;
  for (let i = 0; i < s.length; i++) {
    crc ^= s.charCodeAt(i) << 8;
    for (let b = 0; b < 8; b++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return crc.toString(16).toUpperCase().padStart(4, "0");
}

function ascii(note: string): string {
  // The note field is ASCII only in banking apps: strip diacritics, keep letters, digits, space and basic marks.
  return note
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/đ/g, "d")
    .replace(/Đ/g, "D")
    .replace(/[^A-Za-z0-9 .,\-_/]/g, "")
    .trim()
    .slice(0, 50);
}

export interface VietQrInput {
  bin: string;
  accountNumber: string;
  amount?: number | undefined;
  note?: string | undefined;
}

export function vietQrPayload(i: VietQrInput): string {
  if (!/^\d{6}$/.test(i.bin)) throw new RangeError("INVALID_BIN");
  if (!/^[0-9A-Za-z]{3,19}$/.test(i.accountNumber)) throw new RangeError("INVALID_ACCOUNT");
  const amount = i.amount && i.amount > 0 && Number.isInteger(i.amount) && i.amount <= 999_999_999_999 ? String(i.amount) : undefined;
  const merchant = tlv("00", "A000000727") + tlv("01", tlv("00", i.bin) + tlv("01", i.accountNumber)) + tlv("02", "QRIBFTTA");
  const note = i.note ? ascii(i.note) : "";
  const body =
    tlv("00", "01") +
    tlv("01", amount ? "12" : "11") +
    tlv("38", merchant) +
    tlv("53", "704") +
    (amount ? tlv("54", amount) : "") +
    tlv("58", "VN") +
    (note ? tlv("62", tlv("08", note)) : "") +
    "6304";
  return body + crc16(body);
}
