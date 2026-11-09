package `in`.komnivo.app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object LiveOpsBridge : EventChannel.StreamHandler {
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    fun emit(payload: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post { sink?.success(payload) }
    }
}
