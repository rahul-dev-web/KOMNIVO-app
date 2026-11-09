package in.komnivo.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "in.komnivo.app/liveops"
        private const val EVENT_CHANNEL = "in.komnivo.app/liveops-events"
        private const val REQUEST_CAPTURE = 7104
        const val EXTRA_RESULT_CODE = "projection_result_code"
        const val EXTRA_RESULT_DATA = "projection_result_data"
    }

    private var pendingCaptureResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> requestCapturePermission(result)
                    "stopCapture" -> {
                        stopService(Intent(this, LiveOpsCaptureService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(LiveOpsBridge)
    }

    private fun requestCapturePermission(result: MethodChannel.Result) {
        if (pendingCaptureResult != null) {
            result.error("CAPTURE_PENDING", "A screen-capture request is already open.", null)
            return
        }
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingCaptureResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE)
    }

    @Deprecated("Deprecated in Android, retained for MediaProjection consent result compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CAPTURE) return
        val callback = pendingCaptureResult
        pendingCaptureResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            callback?.success(false)
            return
        }
        val serviceIntent = Intent(this, LiveOpsCaptureService::class.java).apply {
            putExtra(EXTRA_RESULT_CODE, resultCode)
            putExtra(EXTRA_RESULT_DATA, data)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent)
        else startService(serviceIntent)
        callback?.success(true)
    }
}
