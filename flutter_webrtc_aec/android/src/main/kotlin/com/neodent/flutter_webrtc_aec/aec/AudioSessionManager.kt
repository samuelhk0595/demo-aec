package com.neodent.flutter_webrtc_aec.aec

import android.media.*
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Manages AudioTrack and AudioRecord with shared session for full-duplex audio
 * Based on the architecture from AEC.md document
 */
class AudioSessionManager(
    private val sampleRate: Int = 16000,
    private val enableStereoPlayback: Boolean = true
) {
    
    companion object {
        private const val TAG = "AudioSessionManager"
        private const val FRAME_DURATION_MS = 10
    }
    
    private var audioTrack: AudioTrack? = null
    private var audioRecord: AudioRecord? = null
    private var audioSessionId: Int = AudioManager.AUDIO_SESSION_ID_GENERATE
    private var originalAudioMode: Int = AudioManager.MODE_NORMAL
    private var originalSpeakerphoneState: Boolean = false
    
    // Audio format parameters
    private val frameSize = sampleRate / 100 // 10ms worth of samples
    private val playbackChannels = if (enableStereoPlayback) 2 else 1
    private val playbackBufferSize = frameSize * playbackChannels * 2 * 4 // 4 frames buffer
    private val captureBufferSize = frameSize * 2 * 4 // mono capture, 4 frames buffer
    
    private val isSessionActive = AtomicBoolean(false)
    
    /**
     * Initialize audio session with shared session ID
     * Sets up both AudioTrack and AudioRecord for full-duplex operation
     */
    fun initializeSession(audioManager: AudioManager): Boolean {
        try {
            // Store original audio settings
            originalAudioMode = audioManager.mode
            originalSpeakerphoneState = audioManager.isSpeakerphoneOn
            
            // Set audio mode for normal media playback with microphone access
            audioManager.mode = AudioManager.MODE_NORMAL
            audioManager.isSpeakerphoneOn = true // Ensure speaker is used for playback
            
            // Use default session ID for compatibility
            audioSessionId = AudioManager.AUDIO_SESSION_ID_GENERATE
            Log.d(TAG, "Generated audio session ID: $audioSessionId")
            
            // Initialize AudioRecord for capture
            if (!initializeAudioRecord()) {
                Log.e(TAG, "Failed to initialize AudioRecord")
                return false
            }
            
            // Initialize AudioTrack for playback
            if (!initializeAudioTrack()) {
                Log.e(TAG, "Failed to initialize AudioTrack")
                releaseAudioRecord()
                return false
            }
            
            isSessionActive.set(true)
            Log.d(TAG, "Audio session initialized successfully")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing audio session", e)
            return false
        }
    }
    
    private fun initializeAudioRecord(): Boolean {
        try {
            val audioFormat = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            
            audioRecord = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                AudioRecord.Builder()
                    .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                    .setAudioFormat(audioFormat)
                    .setBufferSizeInBytes(captureBufferSize)
                    .build()
            } else {
                // Fallback for older API levels
                AudioRecord(
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    captureBufferSize
                )
            }
            
            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord not properly initialized")
                return false
            }
            
            Log.d(TAG, "AudioRecord initialized: ${sampleRate}Hz, mono, buffer=${captureBufferSize}bytes")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error creating AudioRecord", e)
            return false
        }
    }
    
    private fun initializeAudioTrack(): Boolean {
        try {
            val channelMask = if (enableStereoPlayback) {
                AudioFormat.CHANNEL_OUT_STEREO
            } else {
                AudioFormat.CHANNEL_OUT_MONO
            }
            
            val audioFormat = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(channelMask)
                .build()
            
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            
            audioTrack = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                AudioTrack.Builder()
                    .setAudioAttributes(audioAttributes)
                    .setAudioFormat(audioFormat)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(playbackBufferSize)
                    .build()
            } else {
                // Fallback for older API levels
                AudioTrack(
                    AudioManager.STREAM_VOICE_CALL,
                    sampleRate,
                    channelMask,
                    AudioFormat.ENCODING_PCM_16BIT,
                    playbackBufferSize,
                    AudioTrack.MODE_STREAM
                )
            }
            
            if (audioTrack?.state != AudioTrack.STATE_INITIALIZED) {
                Log.e(TAG, "AudioTrack not properly initialized")
                return false
            }
            
            Log.d(TAG, "AudioTrack initialized: ${sampleRate}Hz, ${if (enableStereoPlayback) "stereo" else "mono"}, buffer=${playbackBufferSize}bytes")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error creating AudioTrack", e)
            return false
        }
    }
    
    /**
     * Start audio playback and recording
     */
    fun startAudio(): Boolean {
        if (!isSessionActive.get()) {
            Log.e(TAG, "Session not initialized")
            return false
        }
        
        try {
            // Start playback first
            audioTrack?.play()
            
            // Then start recording
            audioRecord?.startRecording()
            
            Log.d(TAG, "Audio playback and recording started")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error starting audio", e)
            return false
        }
    }
    
    /**
     * Stop audio playback and recording
     */
    fun stopAudio() {
        try {
            audioRecord?.stop()
            audioTrack?.stop()
            Log.d(TAG, "Audio stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio", e)
        }
    }
    
    /**
     * Write audio data to playback track
     * @param audioData PCM audio data to play
     * @return number of bytes written
     */
    fun writePlaybackData(audioData: ShortArray): Int {
        return try {
            audioTrack?.write(audioData, 0, audioData.size, AudioTrack.WRITE_BLOCKING) ?: -1
        } catch (e: Exception) {
            Log.e(TAG, "Error writing playback data", e)
            -1
        }
    }
    
    /**
     * Read audio data from capture microphone
     * @param buffer buffer to fill with captured audio
     * @return number of samples read
     */
    fun readCaptureData(buffer: ShortArray): Int {
        return try {
            audioRecord?.read(buffer, 0, buffer.size) ?: -1
        } catch (e: Exception) {
            Log.e(TAG, "Error reading capture data", e)
            -1
        }
    }
    
    /**
     * Release audio session and all resources
     */
    fun releaseSession() {
        stopAudio()
        releaseAudioRecord()
        releaseAudioTrack()
        isSessionActive.set(false)
        Log.d(TAG, "Audio session released")
    }
    
    /**
     * Release session and restore original audio settings
     */
    fun releaseSessionAndRestoreAudio(audioManager: AudioManager) {
        releaseSession()
        
        try {
            // Restore original audio settings
            audioManager.mode = originalAudioMode
            audioManager.isSpeakerphoneOn = originalSpeakerphoneState
            Log.d(TAG, "Audio settings restored")
        } catch (e: Exception) {
            Log.e(TAG, "Error restoring audio settings", e)
        }
    }
    
    private fun releaseAudioRecord() {
        try {
            audioRecord?.release()
            audioRecord = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing AudioRecord", e)
        }
    }
    
    private fun releaseAudioTrack() {
        try {
            audioTrack?.release()
            audioTrack = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing AudioTrack", e)
        }
    }
    
    /**
     * Get audio session info
     */
    fun getSessionInfo(): AudioSessionInfo {
        return AudioSessionInfo(
            sessionId = audioSessionId,
            sampleRate = sampleRate,
            frameSize = frameSize,
            isAecEnabled = true // This will be managed by ApmEngine
        )
    }
    
    /**
     * Get the frame size in samples for 10ms
     */
    fun getFrameSize(): Int = frameSize

    fun isStereoPlayback(): Boolean = playbackChannels == 2
    
    /**
     * Check if session is active
     */
    fun isActive(): Boolean = isSessionActive.get()
    
    /**
     * Check if both AudioTrack and AudioRecord are ready
     */
    fun isReady(): Boolean {
        return isSessionActive.get() && 
               audioTrack?.state == AudioTrack.STATE_INITIALIZED &&
               audioRecord?.state == AudioRecord.STATE_INITIALIZED
    }
}
