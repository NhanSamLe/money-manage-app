// Integer VND as bigint; wire format is a decimal string. Never Number/float.
export const MAX_VND = 9_000_000_000_000_000n;

export function parseMoney(input: string, opts: { positive: boolean }): bigint {
  if (!/^-?\d{1,16}$/.test(input)) throw new RangeError("INVALID_AMOUNT");
  const v = BigInt(input);
  if (v > MAX_VND || v < -MAX_VND || (opts.positive && v <= 0n)) throw new RangeError("INVALID_AMOUNT");
  return v;
}

export function formatVnd(v: bigint): string {
  const neg = v < 0n;
  const s = (neg ? -v : v).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return `${neg ? "-" : ""}${s} ₫`;
}
