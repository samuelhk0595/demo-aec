package com.neodent.flutter_aec

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.neodent.flutter_aec.WebRtcJni.WebRtcAecm
import com.neodent.flutter_aec.WebRtcJni.WebRtcNs
import com.neodent.flutter_aec.WebRtcJni.WebRtcVad
import com.neodent.flutter_aec.WebRtcJni.WebRtcAgc
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentLinkedQueue

class AecEngine {
    companion object {
        private const val TAG = "AecEngine"
        private const val DEFAULT_SAMPLE_RATE = 16000
        private const val DEFAULT_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val DEFAULT_CHANNEL_OUT_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        private const val DEFAULT_AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val DEFAULT_FRAME_MS = 20
        // Fallback playback delay guess (ms) when using external playback pipeline
        private const val DEFAULT_EXTERNAL_PLAY_DELAY_MS = 60
    }

    data class VadEvent(
        val active: Boolean,
        val timestampMs: Long,
        val mode: Int,
        val frameMs: Int,
        val hangoverMs: Int
    )

    private var sampleRate = DEFAULT_SAMPLE_RATE
    private var frameMs = DEFAULT_FRAME_MS
    private var framesPerBuffer = 0 // near-end processing frame (will be coerced to 10ms for AECM)
    private var aecmFrameSamples = 0 // 80 or 160 depending on sample rate (AECM constraint)
    private var enableNs = true
    private var echoMode = 3
    private var cngMode = false

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null

    private val isCapturing = AtomicBoolean(false)
    private val isPlaying = AtomicBoolean(false)

    private var aecm: WebRtcAecm? = null
    private var ns: WebRtcNs? = null
    private var vad: WebRtcVad? = null
    private var agc: WebRtcAgc? = null

    private var recordDelayMs = 0
    private var playDelayMs = 0
    private var externalPlaybackDelayMs: Int? = null

    private val farEndQueue = ConcurrentLinkedQueue<ShortArray>()

    private var onProcessedFrameListener: ((ByteArray) -> Unit)? = null
    private var onVadEventListener: ((VadEvent) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private var vadEnabled = false
    private var vadMode = 2
    private var vadFrameMs = 30
    private var vadFrameSamples = 0
    private var vadHangoverMs = 300
    private var vadHangoverEnabled = true
    private var vadActive = false
    private var vadBuffer: ShortArray? = null
    private var vadBufferIndex = 0

    private var agcEnabled = false
    private var agcMode = 2
    private var agcTargetLevelDbfs = 3
    private var agcCompressionGainDb = 9
    private var agcEnableLimiter = true
    private var agcMicLevel = 100

    fun initialize(
        sampleRate: Int = DEFAULT_SAMPLE_RATE,
        frameMs: Int = DEFAULT_FRAME_MS,
        echoMode: Int = 3,
        cngMode: Boolean = false,
        enableNs: Boolean = true,
        vadEnabled: Boolean = false,
        vadMode: Int = 2,
        vadFrameMs: Int = 30,
        vadHangoverMs: Int = 300,
        vadHangoverEnabled: Boolean = true,
        agcEnabled: Boolean = false,
        agcMode: Int = 2,
        agcTargetLevelDbfs: Int = 3,
        agcCompressionGainDb: Int = 9,
        agcEnableLimiter: Boolean = true
    ): Boolean {
        this.sampleRate = sampleRate
        // AECM only supports 80 or 160 sample frames (i.e. 10ms at 8/16k). Force 10ms internally.
        if (frameMs != 10) {
            Log.w(TAG, "AECM requires 10ms frames; overriding requested frameMs=$frameMs to 10ms")
        }
        this.frameMs = 10
        this.framesPerBuffer = sampleRate * this.frameMs / 1000
        // Determine AECM frame size (must be 80 or 160 samples)
        aecmFrameSamples = when (sampleRate) {
            8000 -> 80
            16000 -> 160
            else -> {
                Log.w(TAG, "Unsupported sampleRate=$sampleRate for AECM. Forcing 16k and 160-sample frames")
                this.sampleRate = DEFAULT_SAMPLE_RATE
                160
            }
        }
        this.enableNs = enableNs
        this.echoMode = echoMode
        this.cngMode = cngMode

        return try {
            // Initialize AECM
            aecm = WebRtcAecm(sampleRate, cngMode, echoMode)
            
            // Initialize NS if enabled
            if (enableNs) {
                ns = WebRtcNs(sampleRate, 2) // Mode 2 = Aggressive
            }

            val vadConfigured = configureVad(
                enabled = vadEnabled,
                mode = vadMode,
                frameMs = vadFrameMs,
                hangoverMs = vadHangoverMs,
                hangoverEnabled = vadHangoverEnabled,
                fromInitialize = true
            )
            if (!vadConfigured && vadEnabled) {
                Log.w(TAG, "VAD requested but failed to initialize; continuing without VAD")
            }

            val agcConfigured = configureAgc(
                enabled = agcEnabled,
                mode = agcMode,
                targetLevelDbfs = agcTargetLevelDbfs,
                compressionGainDb = agcCompressionGainDb,
                enableLimiter = agcEnableLimiter,
                fromInitialize = true
            )
            if (!agcConfigured && agcEnabled) {
                Log.w(TAG, "AGC requested but failed to initialize; continuing without AGC")
            }

            Log.i(TAG, "AecEngine initialized: sampleRate=${this.sampleRate}, frameMs=${this.frameMs}, framesPerBuffer=$framesPerBuffer (aecmFrameSamples=$aecmFrameSamples), enableNs=$enableNs, echoMode=$echoMode, cngMode=$cngMode, vadEnabled=$vadEnabled, agcEnabled=$agcEnabled")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AecEngine", e)
            false
        }
    }

    /**
     * Provide an estimated playback delay (ms) when NOT using the internal native playback.
     * Call this early (after audio output engine init) so AEC can use a realistic latency value.
     */
    fun setExternalPlaybackDelay(delayMs: Int) {
        externalPlaybackDelayMs = delayMs.coerceAtLeast(0)
        Log.i(TAG, "External playback delay set: $externalPlaybackDelayMs ms")
    }

    fun setOnProcessedFrameListener(listener: (ByteArray) -> Unit) {
        onProcessedFrameListener = listener
    }

    fun setOnVadEventListener(listener: ((VadEvent) -> Unit)?) {
        onVadEventListener = listener
    }

    @Synchronized
    fun configureVad(
        enabled: Boolean,
        mode: Int,
        frameMs: Int,
        hangoverMs: Int,
        hangoverEnabled: Boolean,
        fromInitialize: Boolean = false
    ): Boolean {
        vadEnabled = enabled
        vadMode = mode.coerceIn(0, 3)
        vadFrameMs = when (frameMs) {
            10, 20, 30 -> frameMs
            else -> {
                Log.w(TAG, "Unsupported VAD frameMs=$frameMs. Using 30ms")
                30
            }
        }
        vadHangoverMs = hangoverMs.coerceAtLeast(0)
        vadHangoverEnabled = hangoverEnabled
        vadFrameSamples = (sampleRate * vadFrameMs) / 1000

        if (vadFrameSamples <= 0) {
            Log.w(TAG, "Invalid VAD frame sample count: $vadFrameSamples. Disabling VAD")
            if (vadActive) {
                emitVadState(false, force = true)
            }
            releaseVad()
            return false
        }

        vadBuffer = ShortArray(vadFrameSamples)
        vadBufferIndex = 0

        if (!enabled) {
            if (vadActive) {
                emitVadState(false, force = true)
            }
            releaseVad()
            return true
        }

        return try {
            if (vad == null) {
                vad = WebRtcVad(vadMode)
            } else {
                vad?.setMode(vadMode)
            }
            vad?.setHangoverEnabled(vadHangoverEnabled)
            vad?.setHangoverDurationMs(vadHangoverMs)
            vad?.reset()
            if (!fromInitialize) {
                emitVadState(false, force = true)
            } else {
                vadActive = false
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error configuring VAD", e)
            emitVadState(false, force = vadActive)
            releaseVad()
            false
        }
    }

    fun setVadEnabled(enabled: Boolean): Boolean {
        return configureVad(
            enabled = enabled,
            mode = vadMode,
            frameMs = vadFrameMs,
            hangoverMs = vadHangoverMs,
            hangoverEnabled = vadHangoverEnabled
        )
    }

    @Synchronized
    fun configureAgc(
        enabled: Boolean,
        mode: Int,
        targetLevelDbfs: Int,
        compressionGainDb: Int,
        enableLimiter: Boolean,
        fromInitialize: Boolean = false
    ): Boolean {
        agcEnabled = enabled
        agcMode = mode.coerceIn(0, 3)
        agcTargetLevelDbfs = targetLevelDbfs.coerceIn(0, 31)
        agcCompressionGainDb = compressionGainDb.coerceIn(0, 90)
        agcEnableLimiter = enableLimiter

        if (!enabled) {
            releaseAgc()
            return true
        }

        return try {
            if (agc == null) {
                agc = WebRtcAgc(0, 255, agcMode, sampleRate)
            } else {
                releaseAgc()
                agc = WebRtcAgc(0, 255, agcMode, sampleRate)
            }
            agc?.setConfig(agcTargetLevelDbfs, agcCompressionGainDb, agcEnableLimiter)
            agcMicLevel = 100
            Log.i(TAG, "AGC configured: mode=$agcMode, targetLevel=$agcTargetLevelDbfs, compressionGain=$agcCompressionGainDb, limiter=$agcEnableLimiter")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error configuring AGC", e)
            releaseAgc()
            false
        }
    }

    fun setAgcEnabled(enabled: Boolean): Boolean {
        return configureAgc(
            enabled = enabled,
            mode = agcMode,
            targetLevelDbfs = agcTargetLevelDbfs,
            compressionGainDb = agcCompressionGainDb,
            enableLimiter = agcEnableLimiter
        )
    }

    fun currentVadConfig(): Map<String, Any?> = mapOf(
        "enabled" to vadEnabled,
        "mode" to vadMode,
        "frameMs" to vadFrameMs,
        "hangoverMs" to vadHangoverMs,
        "hangoverEnabled" to vadHangoverEnabled
    )

    fun currentVadState(): Boolean = vadActive

    fun currentAgcConfig(): Map<String, Any?> = mapOf(
        "enabled" to agcEnabled,
        "mode" to agcMode,
        "targetLevelDbfs" to agcTargetLevelDbfs,
        "compressionGainDb" to agcCompressionGainDb,
        "enableLimiter" to agcEnableLimiter
    )

    private fun processVadSamples(frame: ShortArray) {
        if (!vadEnabled) return
        val localVad = vad ?: return
        val targetSamples = vadFrameSamples
        val buffer = vadBuffer ?: return
        if (targetSamples <= 0) return

        var offset = 0
        while (offset < frame.size) {
            val remaining = frame.size - offset
            val copyCount = minOf(targetSamples - vadBufferIndex, remaining)
            System.arraycopy(frame, offset, buffer, vadBufferIndex, copyCount)
            vadBufferIndex += copyCount
            offset += copyCount

            if (vadBufferIndex == targetSamples) {
                val isActive = try {
                    localVad.process(sampleRate, buffer, vadHangoverEnabled, vadHangoverMs)
                } catch (e: Exception) {
                    Log.e(TAG, "VAD processing error", e)
                    false
                }
                handleVadResult(isActive)
                vadBufferIndex = 0
            }
        }
    }

    private fun handleVadResult(isActive: Boolean) {
        if (!vadEnabled) return
        emitVadState(isActive)
    }

    private fun emitVadState(isActive: Boolean, force: Boolean = false) {
        if (!force && vadActive == isActive) {
            return
        }
        vadActive = isActive
        val event = VadEvent(
            active = isActive,
            timestampMs = System.currentTimeMillis(),
            mode = vadMode,
            frameMs = vadFrameMs,
            hangoverMs = vadHangoverMs
        )
        mainHandler.post {
            onVadEventListener?.invoke(event)
        }
    }

    private fun releaseVad() {
        vad?.release()
        vad = null
        vadActive = false
        vadBuffer = null
        vadBufferIndex = 0
    }

    private fun releaseAgc() {
        agc?.release()
        agc = null
        agcMicLevel = 100
    }

    fun startNativeCapture(context: Context): Boolean {
        if (isCapturing.get()) {
            Log.w(TAG, "Capture already started")
            return false
        }

        // Check permission
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) 
            != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "RECORD_AUDIO permission not granted")
            return false
        }

        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, DEFAULT_CHANNEL_CONFIG, DEFAULT_AUDIO_FORMAT)
        if (bufferSize == AudioRecord.ERROR_BAD_VALUE) {
            Log.e(TAG, "Invalid audio parameters")
            return false
        }

        // Calculate delays
        val bytesPerSecond = sampleRate * 2 // 16-bit = 2 bytes per sample
        recordDelayMs = bufferSize * 1000 / bytesPerSecond

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            DEFAULT_CHANNEL_CONFIG,
            DEFAULT_AUDIO_FORMAT,
            bufferSize
        )

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord initialization failed")
            return false
        }

        isCapturing.set(true)
        audioRecord?.startRecording()

        captureThread = Thread {
            captureLoop()
        }.apply {
            name = "AecCaptureThread"
            start()
        }

        Log.i(TAG, "Native capture started with delay: ${recordDelayMs}ms")
        return true
    }

    fun startNativePlayback(): Boolean {
        if (isPlaying.get()) {
            Log.w(TAG, "Playback already started")
            return false
        }

        val bufferSize = AudioTrack.getMinBufferSize(sampleRate, DEFAULT_CHANNEL_OUT_CONFIG, DEFAULT_AUDIO_FORMAT)
        if (bufferSize == AudioTrack.ERROR_BAD_VALUE) {
            Log.e(TAG, "Invalid playback audio parameters")
            return false
        }

        // Calculate playback delay
        val bytesPerSecond = sampleRate * 2 // 16-bit = 2 bytes per sample
        playDelayMs = bufferSize * 1000 / bytesPerSecond

        audioTrack = AudioTrack(
            AudioManager.STREAM_MUSIC,
            sampleRate,
            DEFAULT_CHANNEL_OUT_CONFIG,
            DEFAULT_AUDIO_FORMAT,
            bufferSize,
            AudioTrack.MODE_STREAM
        )

        if (audioTrack?.state != AudioTrack.STATE_INITIALIZED) {
            Log.e(TAG, "AudioTrack initialization failed")
            return false
        }

        isPlaying.set(true)
        audioTrack?.play()

        playbackThread = Thread {
            playbackLoop()
        }.apply {
            name = "AecPlaybackThread"
            start()
        }

        Log.i(TAG, "Native playback started with delay: ${playDelayMs}ms")
        return true
    }

    fun stopNativeCapture() {
        if (!isCapturing.get()) {
            return
        }

        isCapturing.set(false)
        captureThread?.join(1000)
        captureThread = null

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null

        Log.i(TAG, "Native capture stopped")

        if (vadEnabled && vadActive) {
            emitVadState(false, force = true)
        }
    }

    fun stopNativePlayback() {
        if (!isPlaying.get()) {
            return
        }

        isPlaying.set(false)
        playbackThread?.join(1000)
        playbackThread = null

        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null

        farEndQueue.clear()
        Log.i(TAG, "Native playback stopped")
    }

    fun bufferFarend(pcmData: ByteArray) {
        if (pcmData.isEmpty()) return

        // Accept multiples of aecmFrameSamples * 2; split as needed
        if (pcmData.size % (aecmFrameSamples * 2) != 0) {
            Log.w(TAG, "Farend bytes length=${pcmData.size} not multiple of AECM frame (${aecmFrameSamples * 2} bytes). Dropping.")
            return
        }
        var offset = 0
        while (offset < pcmData.size) {
            val shortArray = ShortArray(aecmFrameSamples)
            var si = 0
            var bi = offset
            while (si < aecmFrameSamples) {
                shortArray[si] = ((pcmData[bi + 1].toInt() shl 8) or (pcmData[bi].toInt() and 0xFF)).toShort()
                si++
                bi += 2
            }
            farEndQueue.offer(shortArray)
            // Feed immediately to AECM to keep internal buffer fresh
            aecm?.bufferFarend(shortArray, shortArray.size)
            // Feed to AGC if enabled
            if (agcEnabled && agc != null) {
                try {
                    agc!!.addFarend(shortArray, shortArray.size)
                } catch (e: Exception) {
                    Log.e(TAG, "AGC addFarend error", e)
                }
            }
            offset += aecmFrameSamples * 2
        }
        val qSize = farEndQueue.size
        if (qSize % 50 == 0) {
            Log.d(TAG, "Far-end queue size=$qSize (every 50th enqueue)")
        }
        // Bound queue to a few frames (keep latency small)
        while (farEndQueue.size > 6) {
            farEndQueue.poll()
        }
    }

    private fun captureLoop() {
        val frameBuffer = ShortArray(framesPerBuffer)
        
        while (isCapturing.get()) {
            try {
                val bytesRead = audioRecord?.read(frameBuffer, 0, frameBuffer.size) ?: 0
                
                if (bytesRead > 0) {
                    processNearendFrame(frameBuffer)
                } else {
                    Log.w(TAG, "AudioRecord read failed: $bytesRead")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in capture loop", e)
                break
            }
        }
    }

    private fun processNearendFrame(nearendFrame: ShortArray) {
        try {
            // If input frame is larger (e.g. 20ms), slice into 10ms AECM frames
            if (nearendFrame.size % aecmFrameSamples != 0) {
                Log.w(TAG, "Near-end frame size=${nearendFrame.size} not multiple of AECM frame=$aecmFrameSamples; dropping")
                return
            }
            var offset = 0
            while (offset < nearendFrame.size) {
                val subFrame = if (nearendFrame.size == aecmFrameSamples) nearendFrame else nearendFrame.copyOfRange(offset, offset + aecmFrameSamples)
                var processedFrame = subFrame
                // Noise suppression (expects 10ms frame)
                if (enableNs && ns != null) {
                    val nsResult = ns!!.process(processedFrame, frameMs)
                    if (nsResult != null && nsResult.size == processedFrame.size) {
                        processedFrame = nsResult
                    }
                }
                // Effective delay
                val effectivePlayDelay = if (isPlaying.get()) playDelayMs else (externalPlaybackDelayMs ?: DEFAULT_EXTERNAL_PLAY_DELAY_MS)
                val totalDelay = recordDelayMs + effectivePlayDelay
                val aecResult = aecm?.process(subFrame, processedFrame, processedFrame.size, totalDelay)
                if (aecResult == null) {
                    Log.w(TAG, "AECM returned null (no echo cancellation this frame). totalDelay=$totalDelay, playDelayMs=$playDelayMs, externalDelay=$externalPlaybackDelayMs, subFrameSize=${subFrame.size}")
                } else {
                    processedFrame = aecResult
                }
                
                // AGC processing
                if (agcEnabled && agc != null) {
                    try {
                        agc!!.addMic(processedFrame, processedFrame.size)
                        val agcResult = agc!!.process(processedFrame, processedFrame.size, agcMicLevel, 0)
                        if (agcResult.ret == 0 && agcResult.out != null) {
                            processedFrame = agcResult.out
                            agcMicLevel = agcResult.outMicLevel
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "AGC processing error", e)
                    }
                }
                
                processVadSamples(processedFrame)
                val byteArray = ByteArray(processedFrame.size * 2)
                for (i in processedFrame.indices) {
                    val sample = processedFrame[i]
                    byteArray[i * 2] = (sample.toInt() and 0xFF).toByte()
                    byteArray[i * 2 + 1] = (sample.toInt() shr 8).toByte()
                }
                mainHandler.post {
                    onProcessedFrameListener?.invoke(byteArray)
                }
                offset += aecmFrameSamples
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error processing nearend frame", e)
        }
    }

    private fun playbackLoop() {
        while (isPlaying.get()) {
            try {
                val farFrame = farEndQueue.poll()
                if (farFrame != null) {
                    audioTrack?.write(farFrame, 0, farFrame.size)
                } else {
                    // No data to play, sleep briefly
                    Thread.sleep(frameMs.toLong())
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in playback loop", e)
                break
            }
        }
    }

    fun dispose() {
        stopNativeCapture()
        stopNativePlayback()
        
        aecm?.release()
        aecm = null
        
        ns?.release()
        ns = null
        releaseVad()
        releaseAgc()

        farEndQueue.clear()
        
        Log.i(TAG, "AecEngine disposed")
    }
}