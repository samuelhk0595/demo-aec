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
            
            try {
                while (isRunning.get()) {
                    try {
                        // Try to get audio data from queue (non-blocking with timeout)
                        val audioData = playbackQueue.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS)
                        
                        if (audioData != null) {
                            // Convert to mono for AEC reference
                            val monoAudio = convertToMono(audioData, monoBuffer)
                            // Feed mono ref ONLY if there is no dedicated external feeder
                            if (!externalRenderFeederActive.get()) {
                                apmEngine.pushRenderMono(monoAudio)
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
                            // No audio data available, feed silence to maintain APM timing
                            // This happens when MP3 is playing through MediaPlayer or we're starved.
                            // Even when an external feeder is active we still provide silence here
                            // to keep cadence if it temporarily stalls.
                            apmEngine.pushRenderMono(silenceBuffer)
                            
                            // Small delay to maintain 10ms frame timing
                            Thread.sleep(10)
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
            
            try {
                while (isRunning.get()) {
                    try {
                        // Read audio from microphone
                        var totalRead = 0
                        while (totalRead < frameSize && isRunning.get()) {
                            val samplesRead = audioSession.readCaptureData(
                                inputBuffer.sliceArray(totalRead until frameSize)
                            )
                            
                            if (samplesRead > 0) {
                                totalRead += samplesRead
                            } else if (samplesRead < 0) {
                                Log.w(TAG, "Error reading capture data: $samplesRead")
                                break
                            }
                        }
                        
                        if (totalRead == frameSize) {
                            // Process with AEC
                            val processSuccess = apmEngine.processCaptureMono(inputBuffer, outputBuffer)
                            
                            // Send processed audio to callback
                            captureCallback?.invoke(outputBuffer.copyOf())
                            
                            if (!processSuccess) {
                                Log.w(TAG, "APM processing failed for capture frame")
                            }
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
