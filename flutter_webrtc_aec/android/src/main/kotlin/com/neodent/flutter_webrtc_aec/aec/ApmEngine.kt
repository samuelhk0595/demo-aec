package com.neodent.flutter_webrtc_aec.aec

import android.util.Log
import com.bk.webrtc.Apm
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Wrapper around WebRTC APM library for easier integration
 * Handles thread-safe audio processing with echo cancellation
 */
class ApmEngine(private val sampleRateHz: Int = 16000) {
    
    companion object {
        private const val TAG = "ApmEngine"
        private const val FRAME_DURATION_MS = 10
        private const val RENDER_BUFFER_FRAMES = 5 // Buffer 5 frames to ensure sync
    }
    
    private var apm: Apm? = null
    private val lock = ReentrantLock()
    private val frameSamples = sampleRateHz / 100 // 10ms worth of samples
    
    // Buffers for audio processing
    private val renderBuffer = ShortArray(frameSamples)
    private val captureBuffer = ShortArray(frameSamples)
    
    // Render stream tracking for better synchronization
    private var renderFrameCount = 0L
    private var captureFrameCount = 0L
    private var lastRenderTime = 0L
    private var lastDelayUpdateCaptureFrame = 0L
    private var consecutiveLibErrors = 0
    private var usingMobileAECM = true
    
    @Volatile
    private var isInitialized = false
    
    /**
     * Initialize the APM engine with default settings optimized for mobile
     */
    fun initialize(): Boolean {
        return lock.withLock {
            try {
                // Create APM with configuration from AEC.md recommendations
                apm = Apm(
                    true,   // aecExtendFilter (help robust echo paths)
                    true,   // speechIntelligibilityEnhance
                    true,   // delayAgnostic
                    false,  // beamforming
                    false,  // nextGenerationAec
                    false,  // experimentalNs
                    false   // experimentalAgc
                )
                // Start with mobile AECM; can auto-switch to full AEC if needed
                apm?.AECMSetSuppressionLevel(Apm.AECM_RoutingMode.Speakerphone)
                apm?.AECM(true)
                usingMobileAECM = true
                
                // Enable noise suppression with high level
                apm?.NSSetLevel(Apm.NS_Level.High)
                apm?.NS(true)
                
                // Enable high-pass filter to remove low-frequency noise
                apm?.HighPassFilter(true)
                
                isInitialized = true
                Log.d(TAG, "APM Engine initialized successfully at ${sampleRateHz}Hz")
                true
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize APM Engine", e)
                false
            }
        }
    }
    
    /**
     * Process render stream (playback audio for AEC reference)
     * Must be called for every 10ms frame of playback audio
     * @param audioMono10ms mono audio data (10ms frame)
     */
    fun pushRenderMono(audioMono10ms: ShortArray) {
        if (!isInitialized) {
            return
        }
        
        if (audioMono10ms.size != frameSamples) {
            Log.w(TAG, "Invalid render frame size: ${audioMono10ms.size}, expected=$frameSamples")
            return
        }
        
        lock.withLock {
            try {
                System.arraycopy(audioMono10ms, 0, renderBuffer, 0, frameSamples)
                val result = apm?.ProcessRenderStream(renderBuffer, 0) ?: -1
                if (renderFrameCount % 200L == 0L) {
                    var peak = 0
                    for (s in renderBuffer) {
                        val a = kotlin.math.abs(s.toInt())
                        if (a > peak) peak = a
                    }
                    Log.d(TAG, "Render frame=${renderFrameCount} peak=$peak")
                }
                
                // Track render stream timing
                renderFrameCount++
                lastRenderTime = System.currentTimeMillis()
                
                if (result != 0) {
                    Log.d(TAG, "Render stream processing result: $result")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error processing render stream", e)
            }
        }
    }
    
    /**
     * Process capture stream (microphone audio with AEC applied)
     * @param inputMono10ms input microphone audio (10ms frame)
     * @param outputMono10ms output buffer for processed audio
     * @return true if processing successful
     */
    fun processCaptureMono(inputMono10ms: ShortArray, outputMono10ms: ShortArray): Boolean {
        if (!isInitialized || 
            inputMono10ms.size != frameSamples || 
            outputMono10ms.size != frameSamples) {
            Log.w(TAG, "Invalid capture frame sizes")
            return false
        }
        
        return lock.withLock {
            try {
                // Check if we have recent render data for proper AEC synchronization
                val timeSinceLastRender = System.currentTimeMillis() - lastRenderTime
                val hasRecentRenderData = timeSinceLastRender < 100 // 100ms tolerance
                
                // Check frame ratio to detect if render is being fed too fast
                val frameRatio = if (captureFrameCount > 0) renderFrameCount.toDouble() / captureFrameCount else 0.0
                val isRenderTooFast = frameRatio > 1.5 // Render is 50% faster than capture
                
                captureFrameCount++
                
                // Copy input to internal buffer
                System.arraycopy(inputMono10ms, 0, captureBuffer, 0, frameSamples)
                
                // Only attempt AEC processing if synchronization is good
                var skipped = false
                val result = if (hasRecentRenderData && renderFrameCount > RENDER_BUFFER_FRAMES && !isRenderTooFast) {
                    // Dynamic delay estimate (rough): time since last render; update every 50 capture frames
                    if (captureFrameCount - lastDelayUpdateCaptureFrame >= 50) {
                        val est = timeSinceLastRender.toInt().coerceIn(0, 300)
                        try { apm?.SetStreamDelay(est) } catch (_: Exception) {}
                        lastDelayUpdateCaptureFrame = captureFrameCount
                    }
                    apm?.ProcessCaptureStream(captureBuffer, 0) ?: -1
                } else {
                    skipped = true
                    if (!hasRecentRenderData) {
                        if (captureFrameCount % 100 == 1L) {
                            Log.d(TAG, "Skipping AEC(sync): no recent render data (${timeSinceLastRender}ms)")
                        }
                    } else if (isRenderTooFast) {
                        if (captureFrameCount % 100 == 1L) {
                            Log.d(TAG, "Skipping AEC(sync): render too fast ratio=${String.format("%.2f", frameRatio)} r=$renderFrameCount c=$captureFrameCount")
                        }
                    } else {
                        if (captureFrameCount % 100 == 1L) {
                            Log.d(TAG, "Skipping AEC(sync): waiting render buffer r=$renderFrameCount/${RENDER_BUFFER_FRAMES}")
                        }
                    }
                    -11
                }
                
                if (captureFrameCount % 200L == 0L) {
                    var peakIn = 0
                    for (s in inputMono10ms) {
                        val a = kotlin.math.abs(s.toInt())
                        if (a > peakIn) peakIn = a
                    }
                    var peakOut = 0
                    for (s in captureBuffer) {
                        val a = kotlin.math.abs(s.toInt())
                        if (a > peakOut) peakOut = a
                    }
                    Log.d(TAG, "Capture frame=${captureFrameCount} peakIn=$peakIn peakOut=$peakOut ratio=${String.format("%.2f", if (captureFrameCount>0) renderFrameCount.toDouble()/captureFrameCount else 0.0)} recentRender=${hasRecentRenderData} renderTooFast=$isRenderTooFast")
                }

                if (result == 0) {
                    consecutiveLibErrors = 0
                    // Copy processed audio to output
                    System.arraycopy(captureBuffer, 0, outputMono10ms, 0, frameSamples)
                    true
                } else {
                    if (skipped) {
                        // We intentionally skipped; minimal logging already done
                    } else {
                        consecutiveLibErrors++
                        if (captureFrameCount % 50 == 1L) {
                            Log.w(TAG, "APM library returned error code: $result (consec=$consecutiveLibErrors) r=$renderFrameCount c=$captureFrameCount mode=${if (usingMobileAECM) "AECM" else "AEC"}")
                        }
                        // Attempt auto-switch from AECM to full AEC if persistent failures
                        if (usingMobileAECM && consecutiveLibErrors == 200) {
                            try {
                                Log.w(TAG, "Switching from AECM to full AEC due to persistent errors")
                                apm?.AECM(false)
                                apm?.AEC(true)
                                usingMobileAECM = false
                                consecutiveLibErrors = 0
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed switching to full AEC", e)
                            }
                        }
                    }
                    // Fallback: copy input directly to output
                    System.arraycopy(inputMono10ms, 0, outputMono10ms, 0, frameSamples)
                    true // Still return true to continue processing
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error processing capture stream", e)
                false
            }
        }
    }
    
    /**
     * Enable or disable AEC processing
     */
    fun enableAec(enabled: Boolean) {
        lock.withLock {
            try {
                apm?.AECM(enabled)
                Log.d(TAG, "AEC ${if (enabled) "enabled" else "disabled"}")
            } catch (e: Exception) {
                Log.e(TAG, "Error toggling AEC", e)
            }
        }
    }
    
    /**
     * Set stream delay for better AEC performance
     * @param delayMs delay in milliseconds between render and capture
     */
    fun setStreamDelay(delayMs: Int) {
        lock.withLock {
            try {
                apm?.SetStreamDelay(delayMs)
                Log.d(TAG, "Stream delay set: ${delayMs}ms")
            } catch (e: Exception) {
                Log.e(TAG, "Error setting stream delay", e)
            }
        }
    }
    
    /**
     * Reset synchronization counters - call when starting a new session
     */
    fun resetSynchronization() {
        lock.withLock {
            renderFrameCount = 0
            captureFrameCount = 0
            lastRenderTime = 0
            Log.d(TAG, "Synchronization counters reset")
        }
    }
    
    /**
     * Release APM resources
     */
    fun release() {
        lock.withLock {
            try {
                apm?.close()
                apm = null
                isInitialized = false
                Log.d(TAG, "APM Engine released")
            } catch (e: Exception) {
                Log.e(TAG, "Error releasing APM Engine", e)
            }
        }
    }
    
    /**
     * Get the expected frame size for this sample rate
     */
    fun getFrameSize(): Int = frameSamples
    
    /**
     * Check if engine is properly initialized
     */
    fun isReady(): Boolean = isInitialized
}
