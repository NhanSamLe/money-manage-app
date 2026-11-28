package vn.moma.app

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Data the app pushes for the home-screen widgets (channel "moma/widgets"). Widgets never call the network
 * themselves; they only render what is stored here, so they work offline and right after boot.
 */
object WidgetStore {
    private const val PREFS = "moma_widgets"
    private const val QR_FILE = "widget_qr.png"

    fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun save(ctx: Context, data: Map<String, Any?>, qrPng: ByteArray?) {
        val e = prefs(ctx).edit()
        for ((k, v) in data) {
            when (v) {
                null -> e.remove(k)
                is Boolean -> e.putBoolean(k, v)
                is Number -> e.putLong(k, v.toLong())
                else -> e.putString(k, v.toString())
            }
        }
        e.apply()
        if (qrPng != null) File(ctx.filesDir, QR_FILE).writeBytes(qrPng)
    }

    fun get(ctx: Context, key: String): Any? = prefs(ctx).all[key]

    /** Signed out: forget every number and the QR (the privacy choice is kept). */
    fun clear(ctx: Context) {
        val privacy = privacy(ctx)
        prefs(ctx).edit().clear().putBoolean("privacy", privacy).apply()
        File(ctx.filesDir, QR_FILE).delete()
    }

    fun privacy(ctx: Context) = prefs(ctx).getBoolean("privacy", false)

    fun qrPngBytes(ctx: Context): ByteArray? = try {
        File(ctx.filesDir, QR_FILE).takeIf { it.exists() }?.readBytes()
    } catch (_: Exception) {
        null
    }

    fun qrBitmap(ctx: Context): Bitmap? {
        val f = File(ctx.filesDir, QR_FILE)
        if (!f.exists()) return null
        return try {
            BitmapFactory.decodeFile(f.absolutePath)
        } catch (e: Exception) {
            null
        }
    }

    fun str(ctx: Context, key: String) = prefs(ctx).getString(key, null) ?: ""
    fun num(ctx: Context, key: String) = try {
        prefs(ctx).getLong(key, 0L)
    } catch (e: ClassCastException) {
        0L
    }
    fun flag(ctx: Context, key: String) = try {
        prefs(ctx).getBoolean(key, false)
    } catch (e: ClassCastException) {
        false
    }
}

object MomaWidgets {
    /** Dart library holding the overlay / background entry points. */
    const val ENTRY_LIB = "package:moma/features/widgets/entrypoints.dart"
    const val HIDDEN = "••••••"

    private val providers: List<Class<out MomaWidgetBase>> = listOf(
        MomaWidgetProvider::class.java,
        SpendWidgetProvider::class.java,
        QrWidgetProvider::class.java,
        AssistantWidgetProvider::class.java,
    )

    fun updateAll(ctx: Context) {
        val mgr = AppWidgetManager.getInstance(ctx)
        for (cls in providers) {
            val ids = mgr.getAppWidgetIds(ComponentName(ctx, cls))
            if (ids.isEmpty()) continue
            val p = cls.getDeclaredConstructor().newInstance()
            for (id in ids) p.push(ctx, mgr, id)
        }
    }

    fun providerFor(kind: String): Class<out MomaWidgetBase>? = when (kind) {
        "quick" -> MomaWidgetProvider::class.java
        "spend" -> SpendWidgetProvider::class.java
        "qr" -> QrWidgetProvider::class.java
        "ai" -> AssistantWidgetProvider::class.java
        else -> null
    }

    fun vnd(v: Long): String {
        val neg = v < 0
        val digits = (if (neg) -v else v).toString()
        val sb = StringBuilder()
        for (i in digits.indices) {
            if (i > 0 && (digits.length - i) % 3 == 0) sb.append('.')
            sb.append(digits[i])
        }
        return (if (neg) "-" else "") + sb + " ₫"
    }

    fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    fun daysLeftInMonth(): Int {
        val c = Calendar.getInstance()
        return c.getActualMaximum(Calendar.DAY_OF_MONTH) - c.get(Calendar.DAY_OF_MONTH)
    }

    private fun flags() = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    /** Opens the full app on a route (moma://app/<path>). */
    fun openApp(ctx: Context, path: String): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("moma://app/$path")).apply {
            component = ComponentName(ctx, MainActivity::class.java)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(ctx, path.hashCode(), intent, flags())
    }

    /** Translucent quick-entry sheet over the home screen (kind = expense | income). */
    fun quickEntry(ctx: Context, kind: String): PendingIntent {
        val intent = Intent(ctx, QuickEntryActivity::class.java).apply {
            action = "vn.moma.app.QUICK_ENTRY.$kind"
            putExtra(QuickEntryActivity.EXTRA_KIND, kind)
            putExtra("background_mode", "transparent")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        return PendingIntent.getActivity(ctx, ("qe$kind").hashCode(), intent, flags())
    }

    fun qrOverlay(ctx: Context): PendingIntent {
        val intent = Intent(ctx, QrOverlayActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        return PendingIntent.getActivity(ctx, 9101, intent, flags())
    }

    /** Copy icon on the QR widget: an invisible activity copies the account number and shows a toast. */
    fun copyNumber(ctx: Context): PendingIntent {
        val intent = Intent(ctx, CopyActivity::class.java).apply {
            putExtra(CopyActivity.EXTRA_WHAT, "number")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }
        return PendingIntent.getActivity(ctx, 9103, intent, flags())
    }

    fun refresh(ctx: Context): PendingIntent {
        val intent = Intent(ctx, WidgetActionReceiver::class.java).apply {
            action = WidgetActionReceiver.ACTION_REFRESH
        }
        return PendingIntent.getBroadcast(ctx, 9102, intent, flags())
    }
}

/**
 * Base for all MoMa widgets: picks a layout per size bucket. Android 12+ gets every bucket at once (the launcher
 * switches while resizing); older versions get the bucket matching the current size.
 */
abstract class MomaWidgetBase : AppWidgetProvider() {
    /** Smallest size (dp) each layout needs, smallest first. */
    abstract val buckets: List<Pair<SizeF, Int>>

    abstract fun bind(ctx: Context, views: RemoteViews, layout: Int)

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) push(ctx, mgr, id)
    }

    override fun onAppWidgetOptionsChanged(ctx: Context, mgr: AppWidgetManager, id: Int, options: Bundle) {
        push(ctx, mgr, id)
    }

    /** Optional replacement layout when there is nothing to show yet (see [useEmpty]). */
    open val emptyLayout: Int = 0
    open fun useEmpty(ctx: Context, layout: Int): Boolean = false
    open fun bindEmpty(ctx: Context, views: RemoteViews) {}

    private fun build(ctx: Context, layout: Int): RemoteViews {
        if (emptyLayout != 0 && useEmpty(ctx, layout)) {
            val e = RemoteViews(ctx.packageName, emptyLayout)
            bindEmpty(ctx, e)
            return e
        }
        val v = RemoteViews(ctx.packageName, layout)
        bind(ctx, v, layout)
        return v
    }

    fun push(ctx: Context, mgr: AppWidgetManager, id: Int) {
        val views = try {
            if (Build.VERSION.SDK_INT >= 31) {
                RemoteViews(buckets.associate { (size, layout) -> size to build(ctx, layout) })
            } else {
                val o = mgr.getAppWidgetOptions(id)
                val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0).toFloat()
                val h = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0).toFloat()
                val fit = buckets.filter { it.first.width <= w + 0.5f && it.first.height <= h + 0.5f }
                    .maxByOrNull { it.first.width * it.first.height } ?: buckets.first()
                build(ctx, fit.second)
            }
        } catch (e: Exception) {
            build(ctx, buckets.first().second)
        }
        mgr.updateAppWidget(id, views)
    }
}

/** Method channel shared by the main app, the quick-entry overlay and the background refresh engine. */
object WidgetBridge {
    fun attach(messenger: BinaryMessenger, ctx: Context, activity: Activity?, onDone: (() -> Unit)? = null) {
        val app = ctx.applicationContext
        MethodChannel(messenger, "moma/widgets").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "save" -> {
                        @Suppress("UNCHECKED_CAST")
                        val data = (call.argument<Map<String, Any?>>("data") ?: emptyMap())
                        WidgetStore.save(app, data, call.argument<ByteArray>("qrPng"))
                        MomaWidgets.updateAll(app)
                        result.success(true)
                    }
                    "get" -> result.success(WidgetStore.get(app, call.argument<String>("key") ?: ""))
                    "set" -> {
                        val key = call.argument<String>("key") ?: ""
                        WidgetStore.save(app, mapOf(key to call.argument<Any?>("value")), null)
                        result.success(true)
                    }
                    "copyImage" -> {
                        val png = call.argument<ByteArray>("png")
                        result.success(png != null && CopyActivity.copyImageToClipboard(app, png))
                    }
                    "getPrivacy" -> result.success(WidgetStore.privacy(app))
                    "setPrivacy" -> {
                        WidgetStore.save(app, mapOf("privacy" to (call.argument<Boolean>("value") == true)), null)
                        MomaWidgets.updateAll(app)
                        result.success(true)
                    }
                    "clear" -> {
                        WidgetStore.clear(app)
                        MomaWidgets.updateAll(app)
                        result.success(true)
                    }
                    "canPin" -> result.success(
                        Build.VERSION.SDK_INT >= 26 && AppWidgetManager.getInstance(app).isRequestPinAppWidgetSupported,
                    )
                    "pin" -> {
                        val cls = MomaWidgets.providerFor(call.argument<String>("kind") ?: "")
                        val ok = cls != null && Build.VERSION.SDK_INT >= 26 &&
                            AppWidgetManager.getInstance(app).requestPinAppWidget(ComponentName(app, cls), null, null)
                        result.success(ok)
                    }
                    "openPermissions" -> {
                        // Xiaomi/MIUI blocks pinning silently unless "Home screen shortcuts" is allowed: open its
                        // permission editor when present, else the standard app details screen.
                        val miui = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                            putExtra("extra_pkgname", app.packageName)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        val details = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = android.net.Uri.fromParts("package", app.packageName, null)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        val opened = try {
                            app.startActivity(miui)
                            true
                        } catch (_: Exception) {
                            try {
                                app.startActivity(details)
                                true
                            } catch (_: Exception) {
                                false
                            }
                        }
                        result.success(opened)
                    }
                    "openApp" -> {
                        val path = (call.argument<String>("path") ?: "home").trimStart('/')
                        MomaWidgets.openApp(app, path).send()
                        activity?.finish()
                        result.success(true)
                    }
                    "finish" -> {
                        activity?.finish()
                        result.success(true)
                    }
                    "done" -> {
                        result.success(true)
                        onDone?.invoke()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("WIDGET", e.message, null)
            }
        }
    }
}
