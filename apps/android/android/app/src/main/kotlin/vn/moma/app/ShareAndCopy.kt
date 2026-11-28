package vn.moma.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import java.io.File

/**
 * Android share target ("Chia sẻ" a MoMo / bank receipt screenshot or a transaction text to MoMa). Opens the compact
 * Flutter sheet `shareEntryMain` over the sharing app: args = ["text", <text>] or ["image", <cached file path>].
 * Images are copied to MoMa's cache first (the sender's URI grant ends with this activity) and read on the device.
 */
class ShareReceiveActivity : FlutterActivity() {
    private var args: List<String> = listOf("none", "")

    override fun onCreate(savedInstanceState: Bundle?) {
        args = readShare(intent)
        super.onCreate(savedInstanceState)
        watchdog.postDelayed({ if (!uiShown && !isFinishing) finish() }, 8000)
    }

    override fun getDartEntrypointFunctionName(): String = "shareEntryMain"

    // Entry points live in the root library (lib/main.dart): URI lookup fails in release builds.
    override fun getDartEntrypointLibraryUri(): String? = null

    override fun getDartEntrypointArgs(): List<String> = args

    override fun shouldHandleDeeplinking(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    private var uiShown = false
    private val watchdog = Handler(Looper.getMainLooper())

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
        NotifyCaptureBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    private fun readShare(i: Intent?): List<String> {
        if (i?.action != Intent.ACTION_SEND) return listOf("none", "")
        val type = i.type.orEmpty()
        if (type.startsWith("image/")) {
            val uri: Uri? = if (Build.VERSION.SDK_INT >= 33) {
                i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                i.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            val path = uri?.let { copyToCache(it) }
            return if (path != null) listOf("image", path) else listOf("none", "")
        }
        val text = listOfNotNull(i.getStringExtra(Intent.EXTRA_SUBJECT), i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
            .joinToString("\n").trim()
        return if (text.isEmpty()) listOf("none", "") else listOf("text", text.take(4000))
    }

    private fun copyToCache(uri: Uri): String? = try {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        // Keep only the latest few shared images.
        dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(3)?.forEach { it.delete() }
        val out = File(dir, "share_${System.currentTimeMillis()}.img")
        contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
        if (out.length() > 0) out.absolutePath else null
    } catch (_: Exception) {
        null
    }

    companion object {
        const val ENTRY_LIB = BackgroundCapture.ENTRY_LIB
    }
}

/**
 * Invisible activity behind the copy icon on the QR widget: copies the stored account number, shows a toast and
 * finishes at once. An activity (not a broadcast receiver) so the clipboard write happens from the foreground.
 */
class CopyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val what = intent?.getStringExtra(EXTRA_WHAT) ?: "number"
        val value = WidgetStore.str(this, if (what == "payload") "qr_payload" else "qr_number")
        if (value.isEmpty()) {
            Toast.makeText(this, getString(R.string.wg_copy_missing), Toast.LENGTH_SHORT).show()
        } else {
            copyToClipboard(this, value, label = if (what == "payload") "VietQR" else "STK")
            Toast.makeText(
                this,
                getString(if (what == "payload") R.string.wg_copied_payload else R.string.wg_copied_number),
                Toast.LENGTH_SHORT,
            ).show()
        }
        finish()
    }

    companion object {
        const val EXTRA_WHAT = "what"

        fun copyToClipboard(ctx: Context, text: String, label: String) {
            val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText(label, text))
        }

        /**
         * Puts a PNG on the clipboard as an image (paste into Zalo, Messenger, notes...). The file lives in
         * cache/clip/ and is exposed read-only through MoMa's FileProvider; the clipboard grants the pasting app access.
         */
        fun copyImageToClipboard(ctx: Context, png: ByteArray): Boolean = try {
            val dir = File(ctx.cacheDir, "clip").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            val file = File(dir, "MoMa-QR-${System.currentTimeMillis()}.png")
            file.writeBytes(png)
            val uri = androidx.core.content.FileProvider.getUriForFile(ctx, "${ctx.packageName}.moma_update", file)
            val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newUri(ctx.contentResolver, "MoMa QR", uri))
            true
        } catch (_: Exception) {
            false
        }
    }
}
