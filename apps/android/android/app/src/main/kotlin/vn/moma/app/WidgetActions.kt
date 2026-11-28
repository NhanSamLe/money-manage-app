package vn.moma.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Widget buttons that need no screen (e.g. "refresh" on the spending widget). Runs a short-lived headless Flutter
 * engine with the `widgetRefreshMain` entry point, which fetches the numbers and pushes them back over the
 * "moma/widgets" channel, then signals "done".
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REFRESH) return
        if (running) return
        running = true
        val app = context.applicationContext
        val pending = goAsync()
        WidgetStore.save(app, mapOf("refreshing" to true), null)
        MomaWidgets.updateAll(app)
        val handler = Handler(Looper.getMainLooper())
        var engine: FlutterEngine? = null
        var finished = false
        val finish: () -> Unit = {
            if (!finished) {
                finished = true
                WidgetStore.save(app, mapOf("refreshing" to false), null)
                MomaWidgets.updateAll(app)
                handler.post {
                    try {
                        engine?.destroy()
                    } catch (_: Exception) {
                    }
                }
                running = false
                pending.finish()
            }
        }
        handler.postDelayed({ finish() }, 25_000)
        try {
            val e = FlutterEngine(app)
            engine = e
            WidgetBridge.attach(e.dartExecutor.binaryMessenger, app, null) { handler.post { finish() } }
            val loader = FlutterInjector.instance().flutterLoader()
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "widgetRefreshMain"),
            )
        } catch (e: Exception) {
            finish()
        }
    }

    companion object {
        const val ACTION_REFRESH = "vn.moma.app.WIDGET_REFRESH"

        @Volatile
        private var running = false
    }
}

/**
 * Compact quick-entry sheet over the home screen (Flutter entry point `quickEntryMain`), started by the widget
 * buttons "Ghi chi" / "Ghi thu". Transparent background, own task, not in recents.
 */
class QuickEntryActivity : FlutterActivity() {
    override fun getDartEntrypointFunctionName(): String = "quickEntryMain"

    // Entry points live in the root library (lib/main.dart): URI lookup fails in release builds.
    override fun getDartEntrypointLibraryUri(): String? = null

    override fun getDartEntrypointArgs(): List<String> =
        listOf(intent?.getStringExtra(EXTRA_KIND) ?: "expense")

    override fun shouldHandleDeeplinking(): Boolean = false

    // Translucent window over the home screen: Flutter must render with a transparent background.
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    private var uiShown = false
    private val watchdog = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Safety net: if the Dart side never draws (entry point missing, init failure), close instead of leaving an
        // invisible window that swallows every touch.
        watchdog.postDelayed({ if (!uiShown && !isFinishing) finish() }, 6000)
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        uiShown = true
    }

    override fun onDestroy() {
        watchdog.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WidgetBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext, this)
    }

    companion object {
        const val EXTRA_KIND = "kind"
    }
}

/** Enlarged receive-QR over the home screen (native, instant). Tap outside or "Đóng" to close. */
class QrOverlayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_qr_overlay)
        findViewById<View>(R.id.qo_root).setOnClickListener { finish() }
        findViewById<View>(R.id.qo_close).setOnClickListener { finish() }
        val state = WidgetStore.str(this, "qr_state")
        val bmp = if (state == "ok") WidgetStore.qrBitmap(this) else null
        val primary = findViewById<TextView>(R.id.qo_primary)
        if (bmp != null) {
            findViewById<ImageView>(R.id.qo_qr).setImageBitmap(bmp)
            // Like bank apps: tapping the code copies the QR picture itself.
            findViewById<View>(R.id.qo_qr_frame).setOnClickListener {
                val png = WidgetStore.qrPngBytes(this)
                val ok = png != null && CopyActivity.copyImageToClipboard(this, png)
                Toast.makeText(this, if (ok) R.string.wg_copied_image else R.string.wg_copy_image_failed, Toast.LENGTH_SHORT)
                    .show()
            }
            findViewById<TextView>(R.id.qo_bank).text = WidgetStore.str(this, "qr_bank")
            val masked = WidgetStore.str(this, "qr_masked")
            val holder = WidgetStore.str(this, "qr_holder")
            findViewById<TextView>(R.id.qo_masked).text = if (holder.isEmpty()) masked else "$masked · $holder"
            primary.setOnClickListener { open("receive") }
            bindCopy(masked)
        } else {
            findViewById<View>(R.id.qo_number_row).visibility = View.GONE
            findViewById<View>(R.id.qo_copy_row).visibility = View.GONE
            findViewById<View>(R.id.qo_qr_frame).visibility = View.GONE
            findViewById<View>(R.id.qo_tap_hint).visibility = View.GONE
            findViewById<View>(R.id.qo_bank).visibility = View.GONE
            findViewById<View>(R.id.qo_masked).visibility = View.GONE
            val unlinked = state == "unlinked"
            findViewById<TextView>(R.id.qo_subtitle).text =
                getString(if (unlinked) R.string.wg_qr_overlay_unlinked else R.string.wg_open_to_update)
            primary.text = getString(if (unlinked) R.string.wg_qr_link_long else R.string.wg_qr_open_btn)
            primary.setOnClickListener { open(if (unlinked) "banks" else "receive") }
        }
    }

    /** Full account number (masked until the eye is tapped) and the two copy buttons. */
    private fun bindCopy(masked: String) {
        val number = WidgetStore.str(this, "qr_number")
        val payload = WidgetStore.str(this, "qr_payload")
        val numberView = findViewById<TextView>(R.id.qo_number)
        val reveal = findViewById<ImageView>(R.id.qo_reveal)
        if (number.isEmpty()) {
            findViewById<View>(R.id.qo_number_row).visibility = View.GONE
            findViewById<View>(R.id.qo_copy_number).visibility = View.GONE
        } else {
            var shown = false
            val render = {
                numberView.text = if (shown) number else masked.ifEmpty { "•••• ${number.takeLast(4)}" }
                reveal.setImageResource(if (shown) R.drawable.ic_wg_eye_off else R.drawable.ic_wg_eye)
                reveal.contentDescription = getString(if (shown) R.string.wg_hide else R.string.wg_reveal)
            }
            render()
            reveal.setOnClickListener {
                shown = !shown
                render()
            }
            findViewById<View>(R.id.qo_copy_number).setOnClickListener {
                CopyActivity.copyToClipboard(this, number, "STK")
                Toast.makeText(this, R.string.wg_copied_number, Toast.LENGTH_SHORT).show()
            }
        }
        if (payload.isEmpty()) {
            findViewById<View>(R.id.qo_copy_payload).visibility = View.GONE
        } else {
            findViewById<View>(R.id.qo_copy_payload).setOnClickListener {
                CopyActivity.copyToClipboard(this, payload, "VietQR")
                Toast.makeText(this, R.string.wg_copied_payload, Toast.LENGTH_SHORT).show()
            }
        }
        if (number.isEmpty() && payload.isEmpty()) findViewById<View>(R.id.qo_copy_row).visibility = View.GONE
    }

    private fun open(path: String) {
        try {
            MomaWidgets.openApp(this, path).send()
        } catch (_: Exception) {
        }
        finish()
    }
}
