package vn.moma.app

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moma/notify_capture").setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> result.success(isListenerEnabled())
                "openPermissionSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "pending" -> result.success(NotifyQueue.pending(applicationContext))
                "ack" -> {
                    val keys = call.argument<List<String>>("keys") ?: emptyList()
                    NotifyQueue.ack(applicationContext, keys)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val mine = ComponentName(this, MomaNotificationListener::class.java)
        return flat.split(":").any { ComponentName.unflattenFromString(it) == mine }
    }
}
