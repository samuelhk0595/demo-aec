package com.neodent.flutter_webrtc_aec.aec

import android.os.Process
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Manages render and capture threads for full-duplex audio processing
 * Implements the threading architecture described in AEC.md
 */
class AudioThreads(
    private val audioSession: AudioSessionManager,
    private val apmEngine: ApmEngine
) {
    
    companion object {
        private const val TAG = "AudioThreads"
        private const val PLAYBACK_QUEUE_SIZE = 10 // Buffer up to 100ms of audio
    }
    
    private val isRunning = AtomicBoolean(false)
    private val isCaptureEnabled = AtomicBoolean(true)
    private var renderThread: Thread? = null
    private var captureThread: Thread? = null
    
    // Queue for playback audio data
    private val playbackQueue = ArrayBlockingQueue<ShortArray>(PLAYBACK_QUEUE_SIZE)
    
    // Callback for processed capture audio
    private var captureCallback: ((ShortArray) -> Unit)? = null
    
    // Audio buffers
    private val frameSize = audioSession.getFrameSize()
    private val stereoFrameSize = frameSize * 2
    private val tempStereoBuffer = ShortArray(stereoFrameSize)
    // Simple counters for diagnostics
    @Volatile private var renderFramesFed = 0L
    @Volatile private var captureFramesObserved = 0L
    private var lastRenderLogTime = 0L
    private var lastCaptureLogTime = 0L

    // When true, another component (e.g. decoded file playback thread) is already
    // pushing perfectly timed 10ms render frames into the APM. In that case we must
    // NOT also call pushRenderMono here for queued playback frames, otherwise the
    // render stream advances twice as fast causing continual -11 sync errors.
    private val externalRenderFeederActive = AtomicBoolean(false)

    fun setExternalRenderFeederActive(active: Boolean) {
        externalRenderFeederActive.set(active)
        Log.d(TAG, "External render feeder active=$active")
    }
    
    /**
     * Enable or disable capture processing
     * @param enabled true to enable capture, false to disable
     */
    fun setCaptureEnabled(enabled: Boolean) {
        isCaptureEnabled.set(enabled)
        Log.d(TAG, "Capture enabled=$enabled")
        if (enabled) {
            // Reset counters so AEC doesn't see huge historical render lead
            renderFramesFed = 0
            captureFramesObserved = 0
            apmEngine.resetSynchronization()
            // Provide fresh small render history (silent) so first capture frames can process immediately
            val silent = ShortArray(frameSize)
            repeat(5) { apmEngine.pushRenderMono(silent) }
            Log.d(TAG, "Capture enable sync reset applied")
        }
    }
    
    /**
     * Start both render and capture threads
     */
    fun start(): Boolean {
        if (isRunning.get()) {
            Log.w(TAG, "Audio threads already running")
            return true
        }
        
        if (!audioSession.isReady() || !apmEngine.isReady()) {
            Log.e(TAG, "Audio session or APM engine not ready")
            return false
        }
        
        try {
            isRunning.set(true)
            
            // Start audio playback and recording
            if (!audioSession.startAudio()) {
                Log.e(TAG, "Failed to start audio session")
                isRunning.set(false)
                return false
            }
            
            // Start render thread (playback)
            startRenderThread()
            
            // Start capture thread (recording with AEC)
            startCaptureThread()
            
            Log.d(TAG, "Audio threads started successfully")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error starting audio threads", e)
            stop()
            return false
        }
    }
    
    /**
     * Stop both threads and clean up
     */
    fun stop() {
        if (!isRunning.get()) {
            return
        }
        
        Log.d(TAG, "Stopping audio threads...")
        isRunning.set(false)
        
        // Clear playback queue to unblock render thread
        playbackQueue.clear()
        
        // Wait for threads to finish
        try {
            renderThread?.join(1000)
            captureThread?.join(1000)
        } catch (e: InterruptedException) {
            Log.w(TAG, "Thread join interrupted", e)
        }
        
        // Stop audio session
        audioSession.stopAudio()
        
        renderThread = null
        captureThread = null
        
        Log.d(TAG, "Audio threads stopped")
    }
    
    /**
     * Queue audio data for playback
     * @param audioData PCM audio data (stereo or mono)
     */
    fun queuePlaybackAudio(audioData: ShortArray): Boolean {
        if (!isRunning.get()) {
            return false
        }
        
        return try {
            // Non-blocking offer - drop frame if queue is full
            val success = playbackQueue.offer(audioData.copyOf())
            if (!success) {
                Log.w(TAG, "Playback queue full, dropping frame")
            }
            success
        } catch (e: Exception) {
            Log.e(TAG, "Error queuing playback audio", e)
            false
        }
    }
    
    /**
     * Set callback for processed capture audio
     */
    fun setCaptureCallback(callback: (ShortArray) -> Unit) {
        this.captureCallback = callback
    }
    
    private fun startRenderThread() {
        renderThread = thread(name = "AudioRender") {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d(TAG, "Render thread started")
            
            val monoBuffer = ShortArray(frameSize)
            val silenceBuffer = ShortArray(frameSize) // For when no audio is available
            silenceBuffer.fill(0) // Fill with silence
            val nanosPerFrame = 10_000_000L
            var nextDeadline = System.nanoTime()
            
            try {
                while (isRunning.get()) {
                    try {
                        // If capture disabled, avoid advancing render stream to prevent large ratio gaps.
                        if (!isCaptureEnabled.get()) {
                            Thread.sleep(10)
                            continue
                        }
                        // Try to get audio data from queue (non-blocking with timeout)
                        val audioData = playbackQueue.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS)
                        
                        // Snapshot capture count from ApmEngine perspective is not directly accessible;
                        // we'll approximate using internal counters updated by capture thread via callback hook later if needed.
                        if (audioData != null) {
                            // Convert to mono for AEC reference
                            val monoAudio = convertToMono(audioData, monoBuffer)
                            if (!externalRenderFeederActive.get()) {
                                apmEngine.pushRenderMono(monoAudio)
                                renderFramesFed++
                            }
                            // Ensure playback buffer matches AudioTrack channel config
                            val playbackData = if (audioData.size == frameSize && stereoFrameSize != frameSize) {
                                // Duplicate mono -> stereo only if AudioTrack expects stereo
                                if (audioData.size == frameSize && stereoFrameSize == frameSize * 2 && audioSession.isStereoPlayback()) {
                                    var i = 0
                                    for (s in audioData) {
                                        tempStereoBuffer[i++] = s
                                        tempStereoBuffer[i++] = s
                                    }
                                    tempStereoBuffer
                                } else audioData
                            } else audioData
                            val bytesWritten = audioSession.writePlaybackData(playbackData)
                            
                            if (bytesWritten < 0) {
                                Log.w(TAG, "Failed to write playback data")
                            }
                        } else {
                            // Maintain device playback pacing with silence
                            val playbackSilence: ShortArray = if (audioSession.isStereoPlayback()) {
                                var i = 0
                                while (i < tempStereoBuffer.size) {
                                    tempStereoBuffer[i++] = 0
                                    tempStereoBuffer[i++] = 0
                                }
                                tempStereoBuffer
                            } else {
                                // mono
                                for (i in 0 until monoBuffer.size) monoBuffer[i] = 0
                                monoBuffer
                            }
                            val bytesWritten = audioSession.writePlaybackData(playbackSilence)
                            if (bytesWritten < 0) {
                                Log.w(TAG, "Failed to write silence to playback")
                            }

                            if (!externalRenderFeederActive.get()) {
                                apmEngine.pushRenderMono(silenceBuffer)
                                renderFramesFed++
                            }
                        }

                        val nowMs = System.currentTimeMillis()
                        if (nowMs - lastRenderLogTime > 5000) {
                            val ratio = if (captureFramesObserved > 0) renderFramesFed.toDouble() / captureFramesObserved else 0.0
                            Log.d(TAG, "Render pacing diag: render=${renderFramesFed} capture=${captureFramesObserved} ratio=${"%.2f".format(ratio)} queue=${playbackQueue.size}")
                            lastRenderLogTime = nowMs
                        }

                        // Precise pacing: aim for one iteration per 10ms without cumulative drift
                        nextDeadline += nanosPerFrame
                        val now = System.nanoTime()
                        var sleepNanos = nextDeadline - now
                        if (sleepNanos < 0) {
                            // We're late; reset schedule to now to avoid spiral of lateness
                            nextDeadline = now
                            sleepNanos = 0
                        }
                        if (sleepNanos > 0) {
                            Thread.sleep(sleepNanos / 1_000_000L, (sleepNanos % 1_000_000L).toInt())
                        }
                        
                    } catch (e: InterruptedException) {
                        // Thread interrupted, exit loop
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in render thread", e)
                        // Continue processing other frames
                    }
                }
            } finally {
                Log.d(TAG, "Render thread finished")
            }
        }
    }
    
    private fun startCaptureThread() {
        captureThread = thread(name = "AudioCapture") {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d(TAG, "Capture thread started")
            
            val inputBuffer = ShortArray(frameSize)
            val outputBuffer = ShortArray(frameSize)
            val nanosPerFrame = 10_000_000L
            var nextDeadline = System.nanoTime()
            
            try {
                while (isRunning.get()) {
                    try {
                        // Read audio from microphone
                        var totalRead = 0
                        while (totalRead < frameSize && isRunning.get()) {
                            val remaining = frameSize - totalRead
                            val samplesRead = audioSession.readCaptureData(inputBuffer, totalRead, remaining)
                            if (samplesRead > 0) {
                                totalRead += samplesRead
                            } else if (samplesRead == 0) {
                                // Yield briefly to avoid busy-spin if driver returns 0
                                Thread.sleep(2)
                            } else {
                                Log.w(TAG, "Error reading capture data: $samplesRead")
                                break
                            }
                        }
                        // (Removed additional pacing sleep; rely on blocking read timing to naturally pace capture)
                        val nowMs = System.currentTimeMillis()
                        if (nowMs - lastCaptureLogTime > 5000) {
                            val ratio = if (captureFramesObserved > 0) renderFramesFed.toDouble() / captureFramesObserved else 0.0
                            Log.d(TAG, "Capture pacing diag: render=${renderFramesFed} capture=${captureFramesObserved} ratio=${"%.2f".format(ratio)}")
                            lastCaptureLogTime = nowMs
                        }
                        
                        if (totalRead == frameSize) {
                            // Process with AEC only if capture is enabled
                            if (isCaptureEnabled.get()) {
                                val processSuccess = apmEngine.processCaptureMono(inputBuffer, outputBuffer)
                                captureFramesObserved++
                                // Send processed audio to callback
                                captureCallback?.invoke(outputBuffer.copyOf())
                                if (!processSuccess) {
                                    Log.w(TAG, "APM processing failed for capture frame")
                                }
                            }
                            // If capture is disabled, we still read from microphone to prevent buffer overflow
                            // but we don't process or send the audio
                        }
                        
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in capture thread", e)
                        // Continue processing
                    }
                }
            } finally {
                Log.d(TAG, "Capture thread finished")
            }
        }
    }

    
    /**
     * Convert stereo or mono audio to mono for AEC reference
     */
    private fun convertToMono(audioData: ShortArray, outputBuffer: ShortArray): ShortArray {
        return when {
            audioData.size == frameSize -> {
                // Already mono
                System.arraycopy(audioData, 0, outputBuffer, 0, frameSize)
                outputBuffer
            }
            audioData.size == stereoFrameSize -> {
                // Convert stereo to mono by averaging L and R channels
                for (i in 0 until frameSize) {
                    val left = audioData[i * 2].toInt()
                    val right = audioData[i * 2 + 1].toInt()
                    outputBuffer[i] = ((left + right) / 2).toShort()
                }
                outputBuffer
            }
            else -> {
                Log.w(TAG, "Unexpected audio data size: ${audioData.size}, expected: $frameSize or $stereoFrameSize")
                // Fill with silence
                outputBuffer.fill(0)
                outputBuffer
            }
        }
    }
    
    /**
     * Check if threads are running
     */
    fun isActive(): Boolean = isRunning.get()
    
    /**
     * Get playback queue usage
     */
    fun getPlaybackQueueSize(): Int = playbackQueue.size

    /**
     * Clear queued playback frames (used to immediately halt playback on user speech)
     */
    fun clearPlaybackQueue() {
        playbackQueue.clear()
    }
}
