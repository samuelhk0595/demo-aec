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
    }
    
    private var apm: Apm? = null
    private val lock = ReentrantLock()
    private val frameSamples = sampleRateHz / 100 // 10ms worth of samples
    
    // Buffers for audio processing
    private val renderBuffer = ShortArray(frameSamples)
    private val captureBuffer = ShortArray(frameSamples)
    
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
                    false,  // aecExtendFilter
                    true,   // speechIntelligibilityEnhance
                    true,   // delayAgnostic
                    false,  // beamforming
                    false,  // nextGenerationAec (use AECM for mobile)
                    false,  // experimentalNs
                    false   // experimentalAgc
                )
                
                // Configure AECM for mobile/speakerphone use
                apm?.AECMSetSuppressionLevel(Apm.AECM_RoutingMode.Speakerphone)
                apm?.AECM(true)
                
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
                // Copy input to internal buffer
                System.arraycopy(inputMono10ms, 0, captureBuffer, 0, frameSamples)
                
                // Process with APM (modifies buffer in-place)
                val result = apm?.ProcessCaptureStream(captureBuffer, 0) ?: -1
                
                if (result == 0) {
                    // Copy processed audio to output
                    System.arraycopy(captureBuffer, 0, outputMono10ms, 0, frameSamples)
                    true
                } else {
                    // APM processing failed, but continue with unprocessed audio
                    // This can happen if render stream is not properly synchronized
                    if (result == -11) {
                        Log.d(TAG, "APM processing failed (render stream sync issue): $result")
                    } else {
                        Log.w(TAG, "APM processing failed with code: $result")
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
