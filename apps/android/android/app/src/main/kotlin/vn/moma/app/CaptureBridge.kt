package vn.moma.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** "moma/notify_capture" channel, shared by the app, the share sheet and the background capture engine. */
object NotifyCaptureBridge {
    private const val PREFS = "moma_notify_capture"
    private const val KEY_AUTO = "auto"

    /** Auto-record switch mirrored from the app (default on, like the app). */
    fun autoRecord(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_AUTO, true)

    fun attach(messenger: BinaryMessenger, ctx: Context, onDone: (() -> Unit)? = null) {
        val app = ctx.applicationContext
        MethodChannel(messenger, "moma/notify_capture").setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> result.success(isListenerEnabled(app))
                "openPermissionSettings" -> {
                    try {
                        app.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // Supported bank / wallet apps installed on this phone (needs the <queries> list on Android 11+).
                "installedSupportedApps" -> result.success(installedSupportedApps(app))
                "setAutoRecord" -> {
                    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean(KEY_AUTO, call.argument<Boolean>("on") != false).apply()
                    result.success(null)
                }
                "pending" -> result.success(NotifyQueue.pending(app))
                "ack" -> {
                    val keys = call.argument<List<String>>("keys") ?: emptyList()
                    NotifyQueue.ack(app, keys)
                    result.success(null)
                }
                "done" -> {
                    result.success(null)
                    onDone?.invoke()
                }
                else -> result.notImplemented()
            }
        }
    }

    fun installedSupportedApps(ctx: Context): List<String> {
        val pm = ctx.packageManager
        return MomaNotificationListener.ALLOWED_PACKAGES.filter { pkg ->
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(pkg, 0)
                }
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    fun isListenerEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
        val mine = ComponentName(ctx, MomaNotificationListener::class.java)
        return flat.split(":").any { ComponentName.unflattenFromString(it) == mine }
    }
}

/**
 * Records captured notifications without opening MoMa: a short-lived headless Flutter engine runs `captureMain`
 * (parse + TX_CREATE + widget refresh), then signals "done". If the engine cannot run (battery savers, no
 * session, offline) the items simply stay in [NotifyQueue] and are recorded the next time MoMa opens.
 */
object BackgroundCapture {
    const val ENTRY_LIB = "package:moma/features/notify_capture/entrypoints.dart"
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false

    @Volatile
    private var again = false

    fun request(ctx: Context) {
        val app = ctx.applicationContext
        if (!NotifyCaptureBridge.autoRecord(app)) return
        // Bank apps often post a burst (notification + update): wait a moment and run once.
        handler.post {
            if (running) {
                again = true
                return@post
            }
            handler.removeCallbacksAndMessages(TOKEN)
            handler.postAtTime({ start(app) }, TOKEN, android.os.SystemClock.uptimeMillis() + 1500)
        }
    }

    private val TOKEN = Any()

    private fun start(app: Context) {
        if (running) return
        running = true
        again = false
        var engine: FlutterEngine? = null
        var finished = false
        val finish: () -> Unit = {
            if (!finished) {
                finished = true
                try {
                    engine?.destroy()
                } catch (_: Exception) {
                }
                running = false
                if (again) request(app)
            }
        }
        handler.postDelayed({ finish() }, 30_000)
        try {
            val e = FlutterEngine(app)
            engine = e
            NotifyCaptureBridge.attach(e.dartExecutor.binaryMessenger, app) { handler.post { finish() } }
            WidgetBridge.attach(e.dartExecutor.binaryMessenger, app, null)
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "captureMain"),
            )
        } catch (e: Exception) {
            finish()
        }
    }
}
