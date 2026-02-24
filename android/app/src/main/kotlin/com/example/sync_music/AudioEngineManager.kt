package com.example.sync_music

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Android 音频引擎实现（基于 MediaPlayer + 扩展 ExoPlayer）
 * 当前阶段先用 MediaPlayer 实现基本功能，后续可升级为 ExoPlayer
 */
class AudioEngineManager(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "com.syncmusic/audio_engine"
        const val EVENT_CHANNEL = "com.syncmusic/audio_engine/events"
        const val POSITION_CHANNEL = "com.syncmusic/audio_engine/position"

        @Volatile
        private var instance: AudioEngineManager? = null

        fun getInstance(context: Context): AudioEngineManager {
            return instance ?: synchronized(this) {
                instance ?: AudioEngineManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var positionChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var positionSink: EventChannel.EventSink? = null

    private var mediaPlayer: MediaPlayer? = null
    private var playbackState = AudioPlaybackState.IDLE
    private var currentRate = 1.0f
    private var durationMs = 0
    private var currentPositionMs = 0
    private var isSeeking = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private var positionRunnable: Runnable? = null

    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false

    enum class AudioPlaybackState {
        IDLE, LOADING, READY, PLAYING, PAUSED, COMPLETED, ERROR
    }

    fun registerChannels(flutterEngine: FlutterEngine) {
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        positionChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, POSITION_CHANNEL)
        positionChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                positionSink = events
            }

            override fun onCancel(arguments: Any?) {
                positionSink = null
            }
        })

        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager?
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> handleLoad(call, result)
            "play" -> handlePlay(call, result)
            "pause" -> handlePause(result)
            "seek" -> handleSeek(call, result)
            "getPosition" -> handleGetPosition(result)
            "setRate" -> handleSetRate(call, result)
            "dispose" -> handleDispose(result)
            "configureSession" -> handleConfigureSession(call, result)
            "activateSession" -> handleActivateSession(result)
            "deactivateSession" -> handleDeactivateSession(result)
            else -> result.notImplemented()
        }
    }

    private fun handleLoad(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<Map<String, Any>>("source")
        if (source == null) {
            result.error("INVALID_SOURCE", "Missing source", null)
            return
        }

        val type = source["type"] as? String
        val path = when (type) {
            "network" -> source["url"] as? String
            "file" -> source["path"] as? String
            "asset" -> "file:///android_asset/${source["asset"]}"
            else -> null
        }

        if (path == null) {
            result.error("INVALID_SOURCE", "Invalid source type or path", null)
            return
        }

        updateState(AudioPlaybackState.LOADING)

        try {
            cleanupPlayer()

            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build()
                )

                setOnCompletionListener {
                    updateState(AudioPlaybackState.COMPLETED)
                    stopPositionUpdates()
                }

                setOnErrorListener { _, what, extra ->
                    updateState(AudioPlaybackState.ERROR)
                    sendEvent(mapOf(
                        "type" to "error",
                        "code" to "PLAYBACK_ERROR",
                        "message" to "Error: what=$what, extra=$extra"
                    ))
                    true
                }

                if (type == "network") {
                    // 网络音频：异步准备
                    setOnPreparedListener {
                        durationMs = it.duration
                        updateState(AudioPlaybackState.READY)
                        sendEvent(mapOf(
                            "type" to "durationChanged",
                            "durationMs" to durationMs
                        ))
                        result.success(true)
                    }
                    setDataSource(path)
                    prepareAsync()
                } else {
                    // 本地文件：同步准备
                    setDataSource(path)
                    prepare()
                    durationMs = this.duration
                    updateState(AudioPlaybackState.READY)
                    sendEvent(mapOf(
                        "type" to "durationChanged",
                        "durationMs" to durationMs
                    ))
                    result.success(true)
                }
            }
        } catch (e: IOException) {
            updateState(AudioPlaybackState.ERROR)
            result.error("LOAD_ERROR", e.message, null)
        }
    }

    private fun handlePlay(call: MethodCall, result: MethodChannel.Result) {
        val player = mediaPlayer ?: run {
            result.error("NOT_READY", "Audio not loaded", null)
            return
        }

        val atRoomTimeMs = call.argument<Number>("atRoomTimeMs")?.toLong()

        if (atRoomTimeMs != null) {
            val currentTime = synchronizedNowMs()
            val delayMs = (atRoomTimeMs - currentTime).coerceAtLeast(0L)

            if (delayMs > 0) {
                mainHandler.postDelayed({
                    // 延迟执行时需要重新检查播放器状态
                    try {
                        mediaPlayer?.let { player ->
                            if (playbackState == AudioPlaybackState.READY || 
                                playbackState == AudioPlaybackState.PAUSED) {
                                startPlayback(player)
                            } else {
                                android.util.Log.e("AudioEngineManager", "延迟播放时状态不正确: $playbackState")
                            }
                        }
                    } catch (e: IllegalStateException) {
                        android.util.Log.e("AudioEngineManager", "延迟播放失败: ${e.message}")
                    }
                }, delayMs)
                result.success(null)
                return
            }
        }

        try {
            startPlayback(player)
            result.success(null)
        } catch (e: IllegalStateException) {
            result.error("PLAYBACK_ERROR", e.message, null)
        }
    }

    private fun startPlayback(player: MediaPlayer) {
        try {
            requestAudioFocus()
            player.start()
            updateState(AudioPlaybackState.PLAYING)
            startPositionUpdates()
        } catch (e: IllegalStateException) {
            android.util.Log.e("AudioEngineManager", "startPlayback 失败: ${e.message}")
            updateState(AudioPlaybackState.ERROR)
            throw e
        }
    }

    private fun handlePause(result: MethodChannel.Result) {
        mediaPlayer?.let {
            if (it.isPlaying) {
                it.pause()
                currentPositionMs = it.currentPosition
                updateState(AudioPlaybackState.PAUSED)
                stopPositionUpdates()
            }
        }
        result.success(null)
    }

    private fun handleSeek(call: MethodCall, result: MethodChannel.Result) {
        val positionMs = call.argument<Number>("positionMs")?.toInt()
        if (positionMs == null) {
            result.error("INVALID_ARGS", "Missing positionMs", null)
            return
        }

        mediaPlayer?.let { player ->
            val clampedPosition = positionMs.coerceIn(0, durationMs)
            currentPositionMs = clampedPosition

            isSeeking = true
            player.seekTo(clampedPosition)

            player.setOnSeekCompleteListener {
                isSeeking = false
            }
        }

        result.success(null)
    }

    private fun handleGetPosition(result: MethodChannel.Result) {
        val position = getPrecisePosition()
        result.success(mapOf(
            "positionMs" to position.first,
            "roomTimeMs" to position.second,
            "isMonotonic" to position.third
        ))
    }

    private fun handleSetRate(call: MethodCall, result: MethodChannel.Result) {
        val rate = call.argument<Double>("rate")
        if (rate == null) {
            result.error("INVALID_ARGS", "Missing rate", null)
            return
        }

        currentRate = rate.coerceIn(0.5, 2.0).toFloat()

        // MediaPlayer 不支持原生变速，需要使用 ExoPlayer 或 SoundTouch
        // 这里先记录目标速率，后续切换到 ExoPlayer 实现
        mediaPlayer?.let { player ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    // Android 6.0+ 支持 PlaybackParams
                    val params = android.media.PlaybackParams()
                    params.speed = currentRate
                    params.pitch = 1.0f
                    player.playbackParams = params
                } catch (e: Exception) {
                    // 设备可能不支持
                    sendEvent(mapOf(
                        "type" to "error",
                        "code" to "RATE_CHANGE_ERROR",
                        "message" to e.message
                    ))
                }
            }
        }

        result.success(null)
    }

    private fun handleDispose(result: MethodChannel.Result) {
        cleanupPlayer()
        abandonAudioFocus()
        stopPositionUpdates()
        updateState(AudioPlaybackState.IDLE)
        result.success(null)
    }

    private fun handleConfigureSession(call: MethodCall, result: MethodChannel.Result) {
        val allowBluetooth = call.argument<Boolean>("allowBluetooth") ?: true
        // Android 音频会话配置已在初始化时完成
        // 后续可通过 AudioManager 调整路由
        result.success(null)
    }

    private fun handleActivateSession(result: MethodChannel.Result) {
        requestAudioFocus()
        result.success(null)
    }

    private fun handleDeactivateSession(result: MethodChannel.Result) {
        abandonAudioFocus()
        result.success(null)
    }

    // Position Tracking
    private fun startPositionUpdates() {
        stopPositionUpdates()

        positionRunnable = object : Runnable {
            override fun run() {
                broadcastPosition()
                mainHandler.postDelayed(this, 50) // 50ms 更新频率
            }
        }
        mainHandler.post(positionRunnable!!)
    }

    private fun stopPositionUpdates() {
        positionRunnable?.let {
            mainHandler.removeCallbacks(it)
        }
        positionRunnable = null
    }

    private fun broadcastPosition() {
        val position = getPrecisePosition()

        positionSink?.success(mapOf(
            "positionMs" to position.first,
            "roomTimeMs" to position.second,
            "isMonotonic" to position.third
        ))
    }

    private fun getPrecisePosition(): Triple<Int, Long, Boolean> {
        val player = mediaPlayer ?: return Triple(currentPositionMs, synchronizedNowMs(), true)

        val positionMs = if (player.isPlaying) {
            player.currentPosition
        } else {
            currentPositionMs
        }

        val roomTimeMs = synchronizedNowMs()
        val isMonotonic = positionMs >= currentPositionMs || isSeeking

        currentPositionMs = positionMs

        return Triple(positionMs, roomTimeMs, isMonotonic)
    }

    private fun synchronizedNowMs(): Long {
        // 使用 System.currentTimeMillis() 与 Dart 端 DateTime.now().millisecondsSinceEpoch 对齐
        return System.currentTimeMillis()
    }

    // Audio Focus
    private fun requestAudioFocus() {
        if (hasAudioFocus) return

        audioManager?.let { am ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAcceptsDelayedFocusGain(true)
                    .setOnAudioFocusChangeListener { focusChange ->
                        when (focusChange) {
                            AudioManager.AUDIOFOCUS_LOSS -> {
                                mediaPlayer?.pause()
                                updateState(AudioPlaybackState.PAUSED)
                            }
                            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                                mediaPlayer?.pause()
                            }
                            AudioManager.AUDIOFOCUS_GAIN -> {
                                mediaPlayer?.start()
                                updateState(AudioPlaybackState.PLAYING)
                            }
                        }
                    }
                    .build()
                    .also { am.requestAudioFocus(it) }
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    { focusChange ->
                        when (focusChange) {
                            AudioManager.AUDIOFOCUS_LOSS -> {
                                mediaPlayer?.pause()
                                updateState(AudioPlaybackState.PAUSED)
                            }
                            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                                mediaPlayer?.pause()
                            }
                            AudioManager.AUDIOFOCUS_GAIN -> {
                                mediaPlayer?.start()
                                updateState(AudioPlaybackState.PLAYING)
                            }
                        }
                    },
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
            }
            hasAudioFocus = true
        }
    }

    private fun abandonAudioFocus() {
        audioManager?.let { am ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        }
        hasAudioFocus = false
    }

    // Helpers
    private fun cleanupPlayer() {
        stopPositionUpdates()
        mediaPlayer?.let {
            if (it.isPlaying) {
                it.stop()
            }
            it.release()
        }
        mediaPlayer = null
    }

    private fun updateState(newState: AudioPlaybackState) {
        if (playbackState == newState) return
        playbackState = newState

        sendEvent(mapOf(
            "type" to "stateChanged",
            "state" to newState.name.lowercase()
        ))
    }

    private fun sendEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }
}
