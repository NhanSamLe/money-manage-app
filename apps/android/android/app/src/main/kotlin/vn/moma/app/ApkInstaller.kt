package vn.moma.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Own subclass so the manifest entry never collides with a plugin's FileProvider declaration. */
class MomaUpdateFileProvider : FileProvider()

/**
 * In-app update: hands a downloaded APK (in cache/updates, see res/xml/update_file_paths.xml) to the system
 * installer. Android itself refuses an APK whose package name or signing key differs from the installed app.
 */
object ApkInstaller {
    private const val CHANNEL = "moma/updater"

    fun attach(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateDir" -> result.success(File(app.cacheDir, "updates").apply { mkdirs() }.absolutePath)
                "canInstall" -> result.success(canInstall(app))
                "openInstallSettings" -> result.success(openInstallSettings(app))
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success("error")
                    } else {
                        result.success(install(app, File(path)))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun install(context: Context, apk: File): String {
        if (!apk.exists()) return "error"
        if (!canInstall(context)) return "needs_permission"
        return try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.moma_update", apk)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            "started"
        } catch (e: Exception) {
            "error"
        }
    }
}
