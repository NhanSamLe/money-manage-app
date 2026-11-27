import { DEFAULT_ONESIGNAL_APP_ID, type Config } from "../../bootstrap/config";

export const ONESIGNAL_URL = "https://api.onesignal.com/notifications?c=push";
const TIMEOUT_MS = 5_000;

export interface PushMessage {
  /** OneSignal external_id = the owner's Supabase auth user id (the app calls OneSignal.login(userId)). */
  ownerId: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  androidGroup?: string;
  /** Android/iOS action buttons (OneSignal `buttons`, max 3). The tapped button's id reaches the app's click listener. */
  buttons?: { id: string; text: string }[];
}

/**
 * Best effort: never throws. Returns true when OneSignal accepted the request.
 * Disabled (returns false, no request) when the REST key is not configured.
 */
export async function sendPush(
  cfg: Pick<Config, "onesignalAppId" | "onesignalRestKey"> & Partial<Pick<Config, "supabaseUrl" | "serviceRoleKey">>,
  fetchImpl: typeof fetch = fetch,
  msg: PushMessage,
): Promise<boolean> {
  if (!msg.ownerId) return false;
  // The in-app bell shows the same item (stored even when push delivery is off or fails).
  await saveToInbox(cfg, msg);
  if (!cfg.onesignalRestKey) return false;
  try {
    const res = await fetchImpl(ONESIGNAL_URL, {
      method: "POST",
      headers: { authorization: `Key ${cfg.onesignalRestKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        app_id: cfg.onesignalAppId || DEFAULT_ONESIGNAL_APP_ID,
        target_channel: "push",
        include_aliases: { external_id: [msg.ownerId] },
        headings: { en: msg.title, vi: msg.title },
        contents: { en: msg.body, vi: msg.body },
        ...(msg.data ? { data: msg.data } : {}),
        ...(msg.androidGroup ? { android_group: msg.androidGroup } : {}),
        ...(msg.buttons?.length ? { buttons: msg.buttons.slice(0, 3).map((b) => ({ id: b.id, text: b.text })) } : {}),
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) {
      // Status only: the response body may echo ids, and the request carries the key.
      console.log(JSON.stringify({ op: "push.onesignal", outcome: "error", upstream_status: res.status }));
      return false;
    }
    return true;
  } catch (e) {
    console.log(JSON.stringify({ op: "push.onesignal", outcome: "error", err: (e as Error)?.name ?? "Error" }));
    return false;
  }
}

/** Where a notification opens in the app; every pushed item carries one. */
export function routeFor(msg: PushMessage): string {
  const r = msg.data?.route;
  if (typeof r === "string" && r.startsWith("/")) return r;
  return "/notifications";
}

/** Stores the push in pf_notification (migration 012). Best effort: never throws, 3 s timeout. */
async function saveToInbox(
  cfg: Partial<Pick<Config, "supabaseUrl" | "serviceRoleKey">>,
  msg: PushMessage,
): Promise<void> {
  if (!cfg.supabaseUrl || !cfg.serviceRoleKey) return;
  try {
    const res = await fetch(`${cfg.supabaseUrl}/rest/v1/rpc/pf_notification_add`, {
      method: "POST",
      headers: {
        apikey: cfg.serviceRoleKey,
        authorization: `Bearer ${cfg.serviceRoleKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_owner: msg.ownerId,
        p_type: String(msg.data?.type ?? "general"),
        p_title: msg.title,
        p_body: msg.body,
        p_data: { ...(msg.data ?? {}), route: routeFor(msg) },
      }),
      signal: AbortSignal.timeout(3_000),
    });
    if (!res.ok) console.log(JSON.stringify({ op: "push.inbox", outcome: "error", upstream_status: res.status }));
  } catch (e) {
    console.log(JSON.stringify({ op: "push.inbox", outcome: "error", err: (e as Error)?.name ?? "Error" }));
  }
}

/** 1500000 -> "1.500.000" (Vietnamese thousands separator). */
export function formatVnd(amount: number): string {
  const n = Math.round(Math.abs(amount));
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

/** Notification for one applied bank event: "Tiền vào +1.500.000 đ" / "Tiền ra -200.000 đ". */
export function bankEventPush(
  ownerId: string,
  ev: { direction: "in" | "out"; amount: number; bankName: string; content: string },
  txId?: string,
): PushMessage {
  const isIn = ev.direction === "in";
  const title = `${isIn ? "Tiền vào +" : "Tiền ra -"}${formatVnd(ev.amount)} đ`;
  const content = ev.content.trim();
  const short = content.length > 80 ? `${content.slice(0, 79)}…` : content;
  const bank = ev.bankName.trim() || "Ngân hàng";
  const body = short ? `${bank} • ${short}` : bank;
  return {
    ownerId,
    title,
    body,
    data: {
      type: "bank_tx",
      direction: ev.direction,
      amount: String(ev.amount),
      ...(txId ? { tx_id: txId } : {}),
      // Tapping opens the recorded transaction (or the list when the id is unknown).
      route: txId ? `/tx/${txId}` : "/home",
    },
    androidGroup: "moma_bank",
  };
}
