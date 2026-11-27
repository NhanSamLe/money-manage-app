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
        val email = pkg in EMAIL_PACKAGES
        if (pkg !in ALLOWED_PACKAGES && !email) return
        val notification = n.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim().orEmpty()
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.joinToString("\n") { it.toString().trim() }?.trim().orEmpty()
        val text = big.ifEmpty { lines }
            .ifEmpty { extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty() }
        if (text.isEmpty() && title.isEmpty()) return
        if (email) {
            // Email apps: only MoMo's own transaction emails are kept (sender / subject / body naming MoMo);
            // every other email notification is dropped right here and never stored.
            val sub = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString().orEmpty()
            if (!isMomoEmail(title, text, sub)) return
            // Stored under MoMo's package so it maps to the MoMo account; "via" tells the app it came by email.
            // A MoMo transaction code (Mã giao dịch) dedupes the same transfer reported twice.
            NotifyQueue.add(applicationContext, MOMO_PACKAGE, title, text, n.postTime, via = "email", dedupe = momoTxCode(text))
            BackgroundCapture.request(applicationContext)
            return
        }
        if (text.isEmpty()) return
        // A cheap pre-filter: a balance-change message always carries a number.
        if (!text.any { it.isDigit() }) return
        NotifyQueue.add(applicationContext, pkg, title, text, n.postTime)
        // Record right away in the background (the queue stays the fallback when that cannot run).
        BackgroundCapture.request(applicationContext)
    }

    companion object {
        const val MOMO_PACKAGE = "com.mservice.momotransfer"

        /** Email apps whose notifications are read ONLY when they are MoMo transaction emails. */
        val EMAIL_PACKAGES = setOf("com.google.android.gm", "com.microsoft.office.outlook")

        private val MOMO_SENDER = Regex("""(?i)(\bmomo\b|momo\.vn|v[ií] momo)""")
        private val MOMO_TX_CODE = Regex("""(?i)m[aã]\s*giao\s*d[iị]ch\s*[:#]?\s*([0-9]{6,20})""")

        fun isMomoEmail(title: String, text: String, sub: String): Boolean =
            MOMO_SENDER.containsMatchIn(title) || MOMO_SENDER.containsMatchIn(sub) ||
                MOMO_SENDER.containsMatchIn(text.take(200))

        fun momoTxCode(text: String): String? = MOMO_TX_CODE.find(text)?.groupValues?.get(1)

        /**
         * Package ids of popular Vietnamese banks / wallets.
         * Verified (Play Store listing / well-known): com.VCB, com.mbmobile, com.tpb.mb.gprsandroid, com.vnpay.bidv,
         * com.vietinbank.ipay, mobile.acb.com.vn, com.vnpay.vpbankonline, com.vnpay.Agribank3g,
         * com.mservice.momotransfer, vn.com.vng.zalopay, vn.com.techcombank.bb.app,
         * com.sacombank.ewallet (Sacombank Pay, third-party listing sites), com.beeasy.toppay (ShopeePay VN, third-party
         * docs). Unverified (best knowledge, not checked against the store): the "others" blocks.
         * Keep in sync with the <queries> list in AndroidManifest.xml (app detection on Android 11+) and with
         * notifyBankNames / the brand registry on the Flutter side.
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
            MOMO_PACKAGE,
            "vn.com.vng.zalopay",
            "com.beeasy.toppay",
            // others (unverified)
            "com.vib.myvib2",
            "com.vnpay.hdbank",
            "vn.com.msb.smartBanking",
            "vn.com.ocb.awe",
            "xyz.be.cake",
            "vn.com.seabank.mb1",
            // from the brand registry (unverified)
            "vn.shb.saha.mbanking",
            "vn.shb.mbanking",
            "com.vnpay.EximBankOmni",
            "io.lifestyle.plus",
            "com.bplus.vtpay",
            "vnptpay.vnptmedia.vnpt.com.vnptpay",
            "vn.com.lpbank.digibank",
            "vn.com.lpb.lienviet24h",
            "vnpay.smartacccount",
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
    fun add(ctx: Context, pkg: String, title: String, text: String, postTime: Long, via: String = "app", dedupe: String? = null) {
        // A provider transaction code (MoMo "Mã giao dịch") identifies the event whatever the wording.
        val key = if (dedupe != null) keyOf(pkg, "tx", dedupe) else keyOf(pkg, title, text)
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
                .put("postTime", postTime)
                .put("via", via),
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
                    "via" to o.optString("via", "app"),
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
