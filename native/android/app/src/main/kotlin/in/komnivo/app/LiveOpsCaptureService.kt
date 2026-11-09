package in.komnivo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageFormat
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

class LiveOpsCaptureService : Service() {
    companion object {
        private const val CHANNEL_ID = "komnivo_liveops_capture"
        private const val NOTIFICATION_ID = 7105
        private const val MIN_FRAME_INTERVAL_MS = 1000L
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var workerThread: HandlerThread? = null
    private var worker: Handler? = null
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }
    @Volatile private var processing = false
    @Volatile private var lastFrameAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP_CAPTURE") {
            stopSelf()
            return START_NOT_STICKY
        }
        startCaptureNotification()

        val resultCode = intent?.getIntExtra(MainActivity.EXTRA_RESULT_CODE, 0) ?: 0
        val resultData = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(MainActivity.EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(MainActivity.EXTRA_RESULT_DATA)
        }
        if (resultData == null) {
            LiveOpsBridge.emit(mapOf("state" to "capture_error", "text" to "Missing screen-capture permission result."))
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = manager.getMediaProjection(resultCode, resultData)
            projection?.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    LiveOpsBridge.emit(mapOf("state" to "capture_stopped", "text" to "Android stopped screen capture."))
                    stopSelf()
                }
            }, Handler(mainLooper))
            startFramePipeline()
            LiveOpsBridge.emit(mapOf("state" to "capturing", "text" to "Screen observation is active."))
        } catch (error: Exception) {
            LiveOpsBridge.emit(mapOf("state" to "capture_error", "text" to (error.message ?: "Unable to start screen capture.")))
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCaptureNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "KOMNIVO LiveOps", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification: Notification = builder
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("KOMNIVO LiveOps is observing")
            .setContentText("Visible screen text is analysed on this device. Stop in KOMNIVO to end.")
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startFramePipeline() {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager).defaultDisplay.getRealMetrics(metrics)

        val sourceWidth = metrics.widthPixels.coerceAtLeast(1)
        val sourceHeight = metrics.heightPixels.coerceAtLeast(1)
        val width = sourceWidth.coerceAtMost(720)
        val height = (sourceHeight.toFloat() * width / sourceWidth).toInt().coerceAtLeast(1)

        workerThread = HandlerThread("KOMNIVO-LiveOps-OCR").also { it.start() }
        worker = Handler(workerThread!!.looper)
        imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2)
        imageReader?.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            val now = SystemClock.elapsedRealtime()
            if (processing || now - lastFrameAt < MIN_FRAME_INTERVAL_MS) {
                image.close()
                return@setOnImageAvailableListener
            }
            processing = true
            lastFrameAt = now
            processFrame(image)
        }, worker)

        virtualDisplay = projection?.createVirtualDisplay(
            "KOMNIVO-LiveOps",
            width,
            height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface,
            null,
            worker,
        )
    }

    private fun processFrame(image: android.media.Image) {
        try {
            val input = InputImage.fromMediaImage(image, 0)
            recognizer.process(input)
                .addOnSuccessListener { result ->
                    val text = result.text.trim()
                    if (text.isNotEmpty()) {
                        LiveOpsBridge.emit(
                            mapOf(
                                "state" to "text_detected",
                                "text" to text.take(12000),
                                "observed_at" to System.currentTimeMillis(),
                            ),
                        )
                    }
                }
                .addOnFailureListener { error ->
                    LiveOpsBridge.emit(mapOf("state" to "ocr_error", "text" to (error.message ?: "On-device text recognition failed.")))
                }
                .addOnCompleteListener {
                    image.close()
                    processing = false
                }
        } catch (error: Exception) {
            image.close()
            processing = false
            LiveOpsBridge.emit(mapOf("state" to "ocr_error", "text" to (error.message ?: "Unable to process screen frame.")))
        }
    }

    override fun onDestroy() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.setOnImageAvailableListener(null, null)
        imageReader?.close()
        imageReader = null
        projection?.stop()
        projection = null
        try { recognizer.close() } catch (_: Exception) { }
        workerThread?.quitSafely()
        workerThread = null
        worker = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
