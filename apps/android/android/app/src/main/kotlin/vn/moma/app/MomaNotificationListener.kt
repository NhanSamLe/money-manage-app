package vn.moma.app

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * Reads balance-change notifications from Vietnamese bank / e-wallet apps (only the allow-listed packages below;
 * every other notification is ignored and never stored). Captured items go to a small persistent queue so nothing
 * is lost while MoMa is closed; the Flutter side reads it through the "moma/notify_capture" channel.
 */
class MomaNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        val pkg = n.packageName ?: return
        if (pkg !in ALLOWED_PACKAGES) return
        val notification = n.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val text = big.ifEmpty { extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty() }
        if (text.isEmpty()) return
        // A cheap pre-filter: a balance-change message always carries a number.
        if (!text.any { it.isDigit() }) return
        NotifyQueue.add(applicationContext, pkg, title, text, n.postTime)
    }

    companion object {
        /**
         * Package ids of popular Vietnamese banks / wallets.
         * Verified (Play Store listing / well-known): com.VCB, com.mbmobile, com.tpb.mb.gprsandroid, com.vnpay.bidv,
         * com.vietinbank.ipay, mobile.acb.com.vn, com.vnpay.vpbankonline, com.vnpay.Agribank3g,
         * com.mservice.momotransfer, vn.com.vng.zalopay, vn.com.techcombank.bb.app,
         * com.sacombank.ewallet (Sacombank Pay, third-party listing sites), com.beeasy.toppay (ShopeePay VN, third-party
         * docs). Unverified (best knowledge, not checked against the store): the "others" block.
         */
        val ALLOWED_PACKAGES = setOf(
            "com.VCB",
            "vn.com.techcombank.bb.app",
            "com.mbmobile",
            "com.tpb.mb.gprsandroid",
            "com.vnpay.bidv",
            "com.vietinbank.ipay",
            "mobile.acb.com.vn",
            "com.vnpay.vpbankonline",
            "com.sacombank.ewallet",
            "com.vnpay.Agribank3g",
            "com.mservice.momotransfer",
            "vn.com.vng.zalopay",
            "com.beeasy.toppay",
            // others (unverified)
            "com.vib.myvib2",
            "com.vnpay.hdbank",
            "vn.com.msb.smartBanking",
            "vn.com.ocb.awe",
            "xyz.be.cake",
            "vn.com.seabank.mb1",
        )
    }
}

/** SharedPreferences-backed JSON queue: capped, de-duplicated by a stable content key. */
object NotifyQueue {
    private const val PREFS = "moma_notify_capture"
    private const val KEY_QUEUE = "queue"
    private const val KEY_SEEN = "seen"
    private const val CAP = 200
    private const val SEEN_CAP = 500

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Same app + same title + same text = same event (bank texts carry time / balance, so real repeats differ). */
    private fun keyOf(pkg: String, title: String, text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest("$pkg\n$title\n$text".toByteArray())
        return digest.take(16).joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    fun add(ctx: Context, pkg: String, title: String, text: String, postTime: Long) {
        val key = keyOf(pkg, title, text)
        val p = prefs(ctx)
        val seen = JSONArray(p.getString(KEY_SEEN, "[]"))
        for (i in 0 until seen.length()) if (seen.optString(i) == key) return
        val queue = JSONArray(p.getString(KEY_QUEUE, "[]"))
        for (i in 0 until queue.length()) if (queue.optJSONObject(i)?.optString("key") == key) return
        queue.put(
            JSONObject()
                .put("key", key)
                .put("package", pkg)
                .put("title", title)
                .put("text", text)
                .put("postTime", postTime),
        )
        val trimmed = JSONArray()
        val start = maxOf(0, queue.length() - CAP)
        for (i in start until queue.length()) trimmed.put(queue.get(i))
        p.edit().putString(KEY_QUEUE, trimmed.toString()).apply()
    }

    @Synchronized
    fun pending(ctx: Context): List<Map<String, Any>> {
        val queue = JSONArray(prefs(ctx).getString(KEY_QUEUE, "[]"))
        val out = ArrayList<Map<String, Any>>()
        for (i in 0 until queue.length()) {
            val o = queue.optJSONObject(i) ?: continue
            out.add(
                mapOf(
                    "key" to o.optString("key"),
                    "package" to o.optString("package"),
                    "title" to o.optString("title"),
                    "text" to o.optString("text"),
                    "postTime" to o.optLong("postTime"),
                ),
            )
        }
        return out
    }

    /** Removes the given items and remembers their keys so a re-posted copy is not queued again. */
    @Synchronized
    fun ack(ctx: Context, keys: Collection<String>) {
        if (keys.isEmpty()) return
        val p = prefs(ctx)
        val queue = JSONArray(p.getString(KEY_QUEUE, "[]"))
        val kept = JSONArray()
        for (i in 0 until queue.length()) {
            val o = queue.optJSONObject(i) ?: continue
            if (o.optString("key") !in keys) kept.put(o)
        }
        val seen = JSONArray(p.getString(KEY_SEEN, "[]"))
        for (k in keys) seen.put(k)
        val seenTrimmed = JSONArray()
        val start = maxOf(0, seen.length() - SEEN_CAP)
        for (i in start until seen.length()) seenTrimmed.put(seen.get(i))
        p.edit().putString(KEY_QUEUE, kept.toString()).putString(KEY_SEEN, seenTrimmed.toString()).apply()
    }
}
