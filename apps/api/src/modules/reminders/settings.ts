import { z } from "zod";

// Reminder settings: one JSON document per owner. Stored documents are merged over the defaults on every read,
// so new reminder kinds get sensible values without a data migration.

const TIME = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "HH:mm");
const timed = z.object({ enabled: z.boolean(), time: TIME });

export const ReminderSettings = z.object({
  meals: z.object({ breakfast: timed, lunch: timed, dinner: timed }),
  cash_check: timed,
  daily_review: timed,
  weekly_review: timed.extend({ weekday: z.number().int().min(1).max(7) }),
  monthly_review: timed,
  budget_alerts: z.object({ enabled: z.boolean() }),
});
export type ReminderSettings = z.infer<typeof ReminderSettings>;

/** PUT body: the same shape; every field optional, merged over the current settings. */
export const ReminderSettingsPatch = z.object({
  meals: z.object({ breakfast: timed.partial(), lunch: timed.partial(), dinner: timed.partial() }).partial().optional(),
  cash_check: timed.partial().optional(),
  daily_review: timed.partial().optional(),
  weekly_review: timed.extend({ weekday: z.number().int().min(1).max(7) }).partial().optional(),
  monthly_review: timed.partial().optional(),
  budget_alerts: z.object({ enabled: z.boolean() }).partial().optional(),
});
export type ReminderSettingsPatch = z.infer<typeof ReminderSettingsPatch>;

export const DEFAULT_SETTINGS: ReminderSettings = {
  meals: {
    breakfast: { enabled: true, time: "09:30" },
    lunch: { enabled: true, time: "13:00" },
    dinner: { enabled: true, time: "20:00" },
  },
  cash_check: { enabled: true, time: "21:30" },
  daily_review: { enabled: true, time: "22:00" },
  weekly_review: { enabled: true, weekday: 7, time: "20:00" },
  monthly_review: { enabled: true, time: "20:00" },
  budget_alerts: { enabled: true },
};

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function deepMerge(base: unknown, over: unknown): unknown {
  if (!isObj(base)) return over === undefined ? base : over;
  if (!isObj(over)) return base;
  const out: Record<string, unknown> = { ...base };
  for (const k of Object.keys(base)) if (k in over) out[k] = deepMerge(base[k], over[k]);
  return out;
}

/** Stored (possibly partial or outdated) document -> full valid settings. Invalid stored values fall back to defaults. */
export function resolveSettings(stored: unknown, patch?: unknown): ReminderSettings {
  const merged = deepMerge(deepMerge(DEFAULT_SETTINGS, stored), patch);
  const ok = ReminderSettings.safeParse(merged);
  if (ok.success) return ok.data;
  // A corrupt stored value must never break reminders: apply only the patch over the defaults.
  const fallback = ReminderSettings.safeParse(deepMerge(DEFAULT_SETTINGS, patch));
  return fallback.success ? fallback.data : DEFAULT_SETTINGS;
}
