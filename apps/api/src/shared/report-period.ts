// Reports use Asia/Ho_Chi_Minh (UTC+7, no DST). Ranges are half-open [from, to).
const VN_OFFSET_HOURS = 7;

export function monthRangeUtc(month: string): { from: string; to: string } {
  const m = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(month);
  if (!m) throw new RangeError("VALIDATION_FAILED");
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const start = Date.UTC(y, mo - 1, 1, -VN_OFFSET_HOURS);
  const end = Date.UTC(y, mo, 1, -VN_OFFSET_HOURS);
  return { from: new Date(start).toISOString(), to: new Date(end).toISOString() };
}

/** Local calendar date YYYY-MM-DD in Asia/Ho_Chi_Minh. */
export function currentVnDate(now: Date): string {
  const vn = new Date(now.getTime() + VN_OFFSET_HOURS * 3_600_000);
  return vn.toISOString().slice(0, 10);
}

export function currentVnMonth(now: Date): string {
  const vn = new Date(now.getTime() + VN_OFFSET_HOURS * 3_600_000);
  return `${vn.getUTCFullYear()}-${String(vn.getUTCMonth() + 1).padStart(2, "0")}`;
}
