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
    }

    private var sampleRate = DEFAULT_SAMPLE_RATE
    private var frameMs = DEFAULT_FRAME_MS
    private var framesPerBuffer = 0
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

    private var recordDelayMs = 0
    private var playDelayMs = 0

    private val farEndQueue = ConcurrentLinkedQueue<ShortArray>()
    private val processedFrameQueue = ConcurrentLinkedQueue<ByteArray>()

    private var onProcessedFrameListener: ((ByteArray) -> Unit)? = null

    fun initialize(
        sampleRate: Int = DEFAULT_SAMPLE_RATE,
        frameMs: Int = DEFAULT_FRAME_MS,
        echoMode: Int = 3,
        cngMode: Boolean = false,
        enableNs: Boolean = true
    ): Boolean {
        this.sampleRate = sampleRate
        this.frameMs = frameMs
        this.framesPerBuffer = sampleRate * frameMs / 1000
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

            Log.i(TAG, "AecEngine initialized: sampleRate=$sampleRate, frameMs=$frameMs, enableNs=$enableNs")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AecEngine", e)
            false
        }
    }

    fun setOnProcessedFrameListener(listener: (ByteArray) -> Unit) {
        onProcessedFrameListener = listener
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
        if (pcmData.size != framesPerBuffer * 2) {
            Log.w(TAG, "Invalid farend frame size: ${pcmData.size}, expected: ${framesPerBuffer * 2}")
            return
        }

        // Convert bytes to shorts
        val shortArray = ShortArray(framesPerBuffer)
        for (i in 0 until framesPerBuffer) {
            val index = i * 2
            shortArray[i] = ((pcmData[index + 1].toInt() shl 8) or (pcmData[index].toInt() and 0xFF)).toShort()
        }

        farEndQueue.offer(shortArray)
        
        // Keep queue bounded
        while (farEndQueue.size > 10) {
            farEndQueue.poll()
        }

        // Feed to AECM
        aecm?.bufferFarend(shortArray, shortArray.size)
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
            var processedFrame = nearendFrame
            
            // Apply noise suppression if enabled
            if (enableNs && ns != null) {
                val nsResult = ns!!.process(nearendFrame, frameMs)
                if (nsResult != null) {
                    processedFrame = nsResult
                }
            }

            // Apply AEC
            val totalDelay = recordDelayMs + playDelayMs
            val aecResult = aecm?.process(nearendFrame, processedFrame, processedFrame.size, totalDelay)
            
            if (aecResult != null) {
                processedFrame = aecResult
            }

            // Convert to bytes and emit
            val byteArray = ByteArray(processedFrame.size * 2)
            for (i in processedFrame.indices) {
                val sample = processedFrame[i]
                byteArray[i * 2] = (sample.toInt() and 0xFF).toByte()
                byteArray[i * 2 + 1] = (sample.toInt() shr 8).toByte()
            }

            // Notify listener on main thread
            Handler(Looper.getMainLooper()).post {
                onProcessedFrameListener?.invoke(byteArray)
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

        processedFrameQueue.clear()
        farEndQueue.clear()
        
        Log.i(TAG, "AecEngine disposed")
    }
}