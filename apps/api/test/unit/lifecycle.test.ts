import { describe, expect, it, vi } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import type { AttachmentBucket } from "../../src/entrypoints/routes-attachments";
import {
  DB_LIMIT_BYTES,
  projectCapacity,
  projectionLabel,
  recordCapacity,
  runLifecycle,
  runMaintenance,
  sweepR2Page,
  type MaintenanceGateway,
} from "../../src/entrypoints/routes-maintenance";
import type { FinanceGateway } from "../../src/modules/ledger/ports";

const OWNER = "11111111-1111-4111-8111-111111111111";
const cfg = { supabaseUrl: "https://db.test", publishableKey: "pk", serviceRoleKey: "sk", ownerEmail: "o@test", dbTimeoutMs: 1000 } as Config;
const MB = 1024 * 1024;

const weeks = (start: string, sizes: number[]) =>
  sizes.map((s, i) => ({ week: new Date(Date.parse(`${start}T00:00:00Z`) + i * 7 * 86_400_000).toISOString().slice(0, 10), db_bytes: s }));

describe("capacity projection", () => {
  it("projects months to 80% from the least-squares growth of the last 13 weeks", () => {
    // +1 MB per week = ~4.35 MB per month, now at 100 MB of 500 MB: 300 MB to 80% -> ~69 months
    const h = weeks("2026-08-03", [90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100].map((m) => m * MB));
    const p = projectCapacity(h, 100 * MB);
    expect(p.growth_per_month! / MB).toBeCloseTo(4.35, 1);
    expect(p.months_to_80).toBeGreaterThan(65);
    expect(p.months_to_80).toBeLessThan(72);
    expect(p.months_to_full!).toBeGreaterThan(p.months_to_80!);
    expect(p.pct).toBe(20);
    expect(p.label).toBe("Đủ dùng ~5 năm nữa");
  });

  it("ignores snapshots older than 13 weeks (old growth spurts do not distort the forecast)", () => {
    const old = weeks("2026-01-05", [10, 60].map((m) => m * MB)); // a huge jump long ago
    const recent = weeks("2026-08-03", [100, 100.5, 101, 101.5, 102].map((m) => m * MB));
    const p = projectCapacity([...old, ...recent], 102 * MB);
    expect(p.growth_per_month! / MB).toBeCloseTo(2.17, 1);
  });

  it("needs at least 3 snapshots over 2+ weeks; flat or shrinking databases never run out", () => {
    expect(projectCapacity(weeks("2026-08-03", [100 * MB, 101 * MB]), 101 * MB).growth_per_month).toBeNull();
    expect(projectCapacity([], 50 * MB).label).toBe("Chưa đủ dữ liệu để dự báo (cần vài tuần)");
    const shrink = projectCapacity(weeks("2026-08-03", [120, 110, 100, 90].map((m) => m * MB)), 90 * MB);
    expect(shrink.growth_per_month!).toBeLessThan(0);
    expect(shrink.months_to_80).toBeNull();
    expect(shrink.label).toBe("Dung lượng không tăng: đủ dùng lâu dài");
  });

  it("labels: months, years, near and over 80%", () => {
    expect(projectionLabel(1, 30, 20)).toBe("Đủ dùng ~2 năm nữa");
    expect(projectionLabel(1, 8.4, 20)).toBe("Đủ dùng ~8 tháng nữa");
    expect(projectionLabel(1, 0.3, 79)).toBe("Sắp chạm 80% dung lượng");
    expect(projectionLabel(1, 0, 85)).toContain("trên 80%");
    expect(projectCapacity([], DB_LIMIT_BYTES * 0.5).pct).toBe(50);
  });
});

function fakeLg(over: Partial<MaintenanceGateway> = {}) {
  const lg: MaintenanceGateway = {
    run: vi.fn(async () => ({ tables: {}, month_stats: 0, months: 0, more: false })),
    record: vi.fn(async () => ({ week: "2026-11-23", db_bytes: 100, pct: 10, warn: 0 })),
    report: vi.fn(async () => ({}) as never),
    orphans: vi.fn(async (_o: string, keys: string[]) => keys.filter((k) => k.includes("orphan"))),
    r2Cursor: vi.fn(async () => ({})),
    state: vi.fn(async () => ({ r2_cursor: null })),
    pushClaim: vi.fn(async () => true),
    ...over,
  };
  return lg;
}
const gw = { getOwnerId: vi.fn(async () => OWNER) } as unknown as FinanceGateway;

describe("maintenance jobs", () => {
  it("runLifecycle loops bounded batches until nothing is left, summing per table", async () => {
    let n = 0;
    const lg = fakeLg({
      run: vi.fn(async () => {
        n++;
        return { tables: { pf_command: 1000, pf_change: n === 3 ? 5 : 2000 }, month_stats: 2, months: 1, more: n < 3 };
      }),
    });
    const r = await runLifecycle({ cfg, gw, lg }, OWNER, 10);
    expect(r).toEqual({ passes: 3, totals: { pf_command: 3000, pf_change: 4005 }, month_stats: 6, more: false });
    const capped = await runLifecycle({ cfg, gw, lg: fakeLg({ run: vi.fn(async () => ({ tables: {}, month_stats: 0, months: 0, more: true })) }) }, OWNER, 2);
    expect(capped).toMatchObject({ passes: 2, more: true });
  });

  it("cron windows (Vietnam time): 03:30 cleanup, Monday 04:00 capacity, 1st week 04:15 R2", async () => {
    const lg = fakeLg();
    const at = (iso: string) => runMaintenance({ cfg, gw, lg }, new Date(iso));
    expect(await at("2026-11-30T20:35:00Z")).toEqual(["lifecycle"]); // Tue 01/12 03:35 VN
    expect(await at("2026-11-29T21:05:00Z")).toEqual(["capacity"]); // Mon 30/11 04:05 VN
    expect(await at("2026-12-01T21:20:00Z")).toEqual(["r2"]); // Wed 02/12 04:20 VN
    expect(await at("2026-12-10T21:20:00Z")).toEqual([]); // day 11: no R2 sweep
    expect(await at("2026-11-30T05:00:00Z")).toEqual([]); // midday
  });

  it("warns once per level and week, through push + inbox", async () => {
    const pushes: unknown[] = [];
    const pushFetch = vi.fn(async (_u: unknown, init?: RequestInit) => {
      pushes.push(JSON.parse(String(init?.body)));
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    const inbox = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", inbox);
    const lg = fakeLg({ record: vi.fn(async () => ({ week: "2026-11-23", db_bytes: 420 * MB, pct: 82, warn: 80 })) });
    await recordCapacity({ cfg: { ...cfg, onesignalRestKey: "k" } as Config, gw, lg, pushFetch }, OWNER);
    expect(lg.pushClaim).toHaveBeenCalledWith(OWNER, "capacity:80:2026-11-23");
    expect(JSON.stringify(pushes)).toContain("82%");
    expect(JSON.stringify(pushes)).not.toMatch(/Pro|nâng cấp|trả phí/i); // free tiers only (owner decision)
    vi.unstubAllGlobals();
  });

  it("R2 sweep: deletes old orphans only, caps deletes per page and keeps the cursor when capped", async () => {
    const now = new Date("2026-12-01T00:00:00Z");
    const old = new Date("2026-11-20T00:00:00Z");
    const objects = [
      { key: `${OWNER}/t/kept.jpg`, uploaded: old },
      { key: `${OWNER}/t/orphan-new.jpg`, uploaded: now },
      ...Array.from({ length: 20 }, (_, i) => ({ key: `${OWNER}/t/orphan-${i}.jpg`, uploaded: old })),
    ];
    const del: string[] = [];
    const bucket: AttachmentBucket = {
      put: vi.fn(),
      get: vi.fn(),
      delete: vi.fn(async (k: string) => void del.push(k)),
      list: vi.fn(async () => ({ objects, truncated: true, cursor: "next" })),
    } as unknown as AttachmentBucket;
    const lg = fakeLg();
    const r = await sweepR2Page({ cfg, gw, lg }, OWNER, bucket, now);
    expect(del.length).toBe(15);
    expect(del).not.toContain(`${OWNER}/t/kept.jpg`);
    expect(del).not.toContain(`${OWNER}/t/orphan-new.jpg`);
    expect(r).toEqual({ listed: 22, deleted: 15, done: false });
    expect(lg.r2Cursor).not.toHaveBeenCalled(); // same page again next time
    // a bucket without list support (tests / older bindings) is a no-op
    expect(await sweepR2Page({ cfg, gw, lg }, OWNER, { put: vi.fn(), get: vi.fn(), delete: vi.fn() } as never)).toEqual({ listed: 0, deleted: 0, done: true });
  });
});
