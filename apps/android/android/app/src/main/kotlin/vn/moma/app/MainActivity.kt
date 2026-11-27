package vn.moma.app

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) because local_auth's BiometricPrompt needs a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Back at the root route sends the app to the background instead of finishing the activity, so reopening
        // resumes it (no cold start, no splash replay). Registered before super.onCreate so the Flutter fragment's
        // own callback (added when it attaches) stays on top and still pops inner routes first; Flutter falls through
        // to this one only when nothing is left to pop.
        onBackPressedDispatcher.addCallback(object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                moveTaskToBack(true)
            }
        })
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WidgetBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext, null)
        ApkInstaller.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext) // in-app update
        NotifyCaptureBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // App lock: "Ẩn nội dung khi chuyển ứng dụng" (blank thumbnail in recents, no screenshots).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "moma/secure").setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecure" -> {
                    if (call.argument<Boolean>("on") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
