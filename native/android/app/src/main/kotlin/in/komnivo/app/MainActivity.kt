package `in`.komnivo.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "in.komnivo.app/liveops"
        private const val EVENT_CHANNEL = "in.komnivo.app/liveops-events"
        private const val REQUEST_CAPTURE = 7104
        const val EXTRA_RESULT_CODE = "projection_result_code"
        const val EXTRA_RESULT_DATA = "projection_result_data"
    }

    private data class PendingSpeech(
        val text: String,
        val result: MethodChannel.Result,
    )

    private var pendingCaptureResult: MethodChannel.Result? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var ttsInitializing = false
    private val pendingSpeech = mutableListOf<PendingSpeech>()

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
                    "speak" -> speakOnDemand(call.argument<String>("text").orEmpty(), result)
                    "stopSpeaking" -> {
                        stopSpeaking()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(LiveOpsBridge)
    }

    // TextToSpeech connects to an Android system service. Create it only after
    // the player explicitly requests voice guidance inside LiveOps, never at app
    // startup where it can delay the first Flutter frame and splash animation.
    private fun speakOnDemand(text: String, result: MethodChannel.Result) {
        val cleanText = text.trim()
        if (cleanText.isEmpty()) {
            result.success(false)
            return
        }

        if (ttsReady && textToSpeech != null) {
            speakNow(cleanText, result)
            return
        }

        pendingSpeech.add(PendingSpeech(cleanText, result))
        if (ttsInitializing) return

        ttsInitializing = true
        android.util.Log.i("KOMNIVO_TTS", "Initializing Android TTS on demand for LiveOps.")
        try {
            textToSpeech = TextToSpeech(applicationContext) { status ->
                ttsInitializing = false
                if (status == TextToSpeech.SUCCESS) {
                    ttsReady = true
                    textToSpeech?.setLanguage(Locale.getDefault())
                    val queued = pendingSpeech.toList()
                    pendingSpeech.clear()
                    queued.forEach { speakNow(it.text, it.result) }
                } else {
                    ttsReady = false
                    textToSpeech?.shutdown()
                    textToSpeech = null
                    val queued = pendingSpeech.toList()
                    pendingSpeech.clear()
                    queued.forEach {
                        it.result.error(
                            "TTS_INIT_FAILED",
                            "The Android text-to-speech engine could not initialize.",
                            null,
                        )
                    }
                }
            }
        } catch (error: Exception) {
            ttsInitializing = false
            ttsReady = false
            textToSpeech?.shutdown()
            textToSpeech = null
            val queued = pendingSpeech.toList()
            pendingSpeech.clear()
            queued.forEach {
                it.result.error("TTS_INIT_FAILED", error.message, null)
            }
        }
    }

    private fun speakNow(text: String, result: MethodChannel.Result) {
        val engine = textToSpeech
        if (!ttsReady || engine == null) {
            result.error("TTS_NOT_READY", "The Android voice engine is not ready.", null)
            return
        }

        val status = engine.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "komnivo_${SystemClock.elapsedRealtime()}",
        )
        if (status == TextToSpeech.SUCCESS) {
            result.success(true)
        } else {
            result.error("TTS_SPEAK_FAILED", "Android could not start voice playback.", null)
        }
    }

    private fun stopSpeaking() {
        pendingSpeech.forEach { it.result.success(false) }
        pendingSpeech.clear()
        textToSpeech?.stop()
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

    override fun onDestroy() {
        stopSpeaking()
        textToSpeech?.shutdown()
        textToSpeech = null
        ttsReady = false
        ttsInitializing = false
        super.onDestroy()
    }
}
