package vn.moma.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.StatusBarManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.json.JSONArray

/**
 * Quick-entry surfaces outside the app (D-026): the "Thanh ghi nhanh" persistent notification, the Quick Settings tile
 * "Ghi chi nhanh" and the boot hook that restores the notification. All of them only open the existing translucent
 * quick-entry sheet (QuickEntryActivity / quickEntryMain) or the QR overlay; nothing records without that sheet, so
 * the MoMa app lock (checked by the sheet) and the offline outbox apply unchanged.
 */
object QuickBar {
    private const val CHANNEL = "moma_quickbar"
    const val NOTIFICATION_ID = 4711

    fun enabled(ctx: Context) = WidgetStore.flag(ctx, "quickbar")

    fun setEnabled(ctx: Context, on: Boolean): Boolean {
        WidgetStore.save(ctx, mapOf("quickbar" to on), null)
        refresh(ctx)
        return !on || notificationsAllowed(ctx)
    }

    fun notificationsAllowed(ctx: Context): Boolean =
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()

    /** Posts (or removes) the bar with the latest widget data. Safe to call often. */
    fun refresh(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!enabled(ctx) || !notificationsAllowed(ctx)) {
            nm.cancel(NOTIFICATION_ID)
            return
        }
        try {
            nm.notify(NOTIFICATION_ID, build(ctx))
        } catch (_: Exception) {
            // Missing permission on some ROMs: the toggle in the app explains how to enable it.
        }
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL) != null) return
        val ch = NotificationChannel(CHANNEL, ctx.getString(R.string.quickbar_channel), NotificationManager.IMPORTANCE_LOW).apply {
            description = ctx.getString(R.string.quickbar_channel_desc)
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        nm.createNotificationChannel(ch)
    }

    @Suppress("DEPRECATION")
    private fun builder(ctx: Context): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else Notification.Builder(ctx).setPriority(Notification.PRIORITY_LOW)

    /** Learned routine options still valid now: [(key, label)] (at most [max]). */
    fun routineOptions(ctx: Context, max: Int, nowMs: Long = System.currentTimeMillis()): List<Triple<String, String, String>> {
        val slot = WidgetStore.str(ctx, "routine_slot")
        val until = WidgetStore.num(ctx, "routine_until")
        val raw = WidgetStore.str(ctx, "routine_opts")
        if (slot.isEmpty() || raw.isEmpty() || nowMs >= until) return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until minOf(arr.length(), max)).mapNotNull { i ->
                val o = arr.getJSONObject(i)
                val key = o.optString("key")
                val amount = o.optLong("amount")
                if (key.isEmpty() || amount <= 0) null else Triple(slot, key, "${o.optString("label")} ${short(amount)}")
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun short(v: Long): String = when {
        v >= 1_000_000 -> {
            val t = Math.round(v / 100_000.0) / 10.0
            (if (t == Math.floor(t)) t.toLong().toString() else t.toString()).replace('.', ',') + "tr"
        }
        v >= 1_000 -> "${Math.round(v / 1000.0)}k"
        else -> "${v}đ"
    }

    fun build(ctx: Context): Notification {
        ensureChannel(ctx)
        val hide = WidgetStore.privacy(ctx)
        val today = MomaWidgets.today()
        val sameDay = WidgetStore.flag(ctx, "has_data") && WidgetStore.str(ctx, "day") == today
        val spend = WidgetStore.num(ctx, "today_spend")
        val safeOk = WidgetStore.str(ctx, "safe_day") == today && WidgetStore.get(ctx, "safe_today") != null
        val safe = WidgetStore.num(ctx, "safe_today")
        fun money(v: Long) = if (hide) MomaWidgets.HIDDEN else MomaWidgets.vnd(v)
        val title = if (sameDay) "Hôm nay đã chi ${money(spend)}" else ctx.getString(R.string.quickbar_title_idle)
        val routine = routineOptions(ctx, 2)
        val text = when {
            routine.isNotEmpty() -> WidgetStore.str(ctx, "routine_q").ifEmpty { ctx.getString(R.string.quickbar_text_idle) }
            safeOk -> "Còn tiêu được hôm nay ~${money(safe)}"
            else -> ctx.getString(R.string.quickbar_text_idle)
        }
        // Lock screen: never amounts, only the shortcut.
        val publicVersion = builder(ctx)
            .setSmallIcon(R.drawable.ic_wg_add)
            .setContentTitle("MoMa")
            .setContentText(ctx.getString(R.string.quickbar_text_idle))
            .build()
        val b = builder(ctx)
            .setSmallIcon(R.drawable.ic_wg_add)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(MomaWidgets.quickEntry(ctx, "expense"))
        val actions = mutableListOf<Notification.Action>()
        for ((slot, key, label) in routine) {
            actions += action(ctx, R.drawable.ic_wg_add, label, MomaWidgets.quickEntryRoutine(ctx, slot, key))
        }
        actions += action(ctx, R.drawable.ic_wg_out, ctx.getString(R.string.quickbar_expense), MomaWidgets.quickEntry(ctx, "expense"))
        if (routine.isEmpty()) {
            actions += action(ctx, R.drawable.ic_wg_in, ctx.getString(R.string.quickbar_income), MomaWidgets.quickEntry(ctx, "income"))
            actions += action(ctx, R.drawable.ic_wg_qr, ctx.getString(R.string.quickbar_receive), MomaWidgets.qrOverlay(ctx))
        }
        for (a in actions.take(3)) b.addAction(a)
        return b.build()
    }

    private fun action(ctx: Context, icon: Int, label: String, pi: PendingIntent): Notification.Action =
        Notification.Action.Builder(Icon.createWithResource(ctx, icon), label, pi).build()

    /** Android 13+: asks the system to add the tile (the user confirms). False = add by hand from the editor. */
    fun requestTile(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        return try {
            val sbm = ctx.getSystemService(StatusBarManager::class.java) ?: return false
            sbm.requestAddTileService(
                ComponentName(ctx, QuickEntryTileService::class.java),
                ctx.getString(R.string.tile_quick_entry),
                Icon.createWithResource(ctx, R.drawable.ic_wg_add),
                ctx.mainExecutor,
            ) { }
            true
        } catch (_: Exception) {
            false
        }
    }
}

/** Quick Settings tile "Ghi chi nhanh": opens the translucent quick-entry sheet (after the phone is unlocked). */
class QuickEntryTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let {
            it.state = Tile.STATE_INACTIVE
            it.label = getString(R.string.tile_quick_entry)
            if (Build.VERSION.SDK_INT >= 29) it.subtitle = getString(R.string.tile_quick_entry_sub)
            it.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    @Suppress("DEPRECATION")
    private fun open() {
        val pi = MomaWidgets.quickEntry(this, "expense")
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(pi)
        } else {
            val intent = Intent(this, QuickEntryActivity::class.java).apply {
                action = "vn.moma.app.QUICK_ENTRY.expense"
                putExtra(QuickEntryActivity.EXTRA_KIND, "expense")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }
            startActivityAndCollapse(intent)
        }
    }
}

/** Restores the quick bar after a reboot / app update (notifications do not survive either). */
class QuickBarBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> QuickBar.refresh(context.applicationContext)
        }
    }
}
