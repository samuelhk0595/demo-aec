package com.neodent.flutter_webrtc_aec.aec

/**
 * High-level interface for full-duplex audio processing with WebRTC AEC
 * Based on the architecture described in AEC.md
 */
interface FullDuplexAudioClient {
    
    /**
     * Start full-duplex audio processing
     * - Initializes AudioTrack and AudioRecord with shared session
     * - Starts render and capture threads
     * - Enables AEC processing
     */
    fun start()
    
    /**
     * Stop audio processing and release resources
     */
    fun stop()
    
    /**
     * Enable or disable Acoustic Echo Cancellation
     * @param enabled true to enable AEC, false to disable
     */
    fun setAecEnabled(enabled: Boolean)
    
    /**
     * Enable or disable microphone capture processing
     * Playback will continue independently
     * @param enabled true to enable capture, false to disable
     */
    fun setCaptureEnabled(enabled: Boolean)
    
    /**
     * Push playback PCM data (10ms frames)
     * This audio will be played and used as AEC reference
     * @param audioData PCM data (stereo or mono supported)
     */
    fun pushPlaybackPcm10ms(audioData: ShortArray)

    /**
     * Push arbitrary PCM16 little-endian byte stream. Will be internally buffered
     * and sliced into 10ms mono frames for playback + AEC reference.
     * @param pcmBytes raw PCM16 LE bytes (mono or stereo interleaved). If stereo, will be down-mixed.
     */
    fun pushPlaybackPcmBytes(pcmBytes: ByteArray)
    
    /**
     * Set callback for processed capture frames
     * Receives AEC-processed microphone audio ready for transmission
     * @param callback function to handle processed audio frames
     */
    fun onCaptureFrame(callback: (ShortArray) -> Unit)
    
    /**
     * Get current audio session configuration
     */
    fun getAudioSessionInfo(): AudioSessionInfo
    
    /**
     * Check if audio processing is currently active
     */
    fun isActive(): Boolean

    /**
     * Play MP3 file in loop
     */
    fun playMp3Loop(filePath: String): Boolean

    /**
     * Stop MP3 loop
     */
    fun stopMp3Loop(): Boolean

    /**
     * Check if user is speaking
     */
    fun isUserSpeaking(): Boolean

    /**
     * Set speech detection callback
     */
    fun setSpeechDetectionCallback(callback: (Boolean) -> Unit)
}

/**
 * Audio session configuration information
 */
data class AudioSessionInfo(
    val sessionId: Int,
    val sampleRate: Int,
    val frameSize: Int,
    val isAecEnabled: Boolean
)
