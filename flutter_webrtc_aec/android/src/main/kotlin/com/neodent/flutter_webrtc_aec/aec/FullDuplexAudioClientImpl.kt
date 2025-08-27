package com.neodent.flutter_webrtc_aec.aec

import android.content.Context
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Complete implementation of full-duplex audio with WebRTC AEC
 * Enhanced for Flutter plugin with MP3 support and speech detection
 */
class FullDuplexAudioClientImpl(
    private val context: Context,
    private val sampleRate: Int = 16000,
    private val enableStereoPlayback: Boolean = true
) : FullDuplexAudioClient {
    
    companion object {
        private const val TAG = "FullDuplexAudioClient"
        private const val SPEECH_SILENCE_THRESHOLD_MS = 1200
        private const val INITIAL_SPEECH_ENERGY_THRESHOLD = 800
        private const val ZERO_CROSS_MIN = 20
        private const val ENERGY_SMOOTH_ALPHA = 0.05f
        private const val NOISE_FLOOR_DECAY = 0.995f
    }
    
    // Core components
    private val audioManager: AudioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    
    private val apmEngine = ApmEngine(sampleRate)
    private val audioSession = AudioSessionManager(sampleRate, enableStereoPlayback)
    private lateinit var audioThreads: AudioThreads
    
    // State tracking
    private val isActive = AtomicBoolean(false)
    private val isInitialized = AtomicBoolean(false)
    
    // MP3 playback
    private var mediaPlayer: MediaPlayer? = null
    private val isMp3Playing = AtomicBoolean(false)
    
    // Audio file processing for AEC reference
    private var audioFileData: ShortArray? = null
    private var audioFilePlaybackPosition = 0
    private var audioFileThread: Thread? = null
    
    // Speech detection
    private var speechDetectionCallback: ((Boolean) -> Unit)? = null
    private val isUserSpeaking = AtomicBoolean(false)
    private var lastSpeechTime = 0L
    private var speechDetectionThread: Thread? = null
    private var adaptiveEnergyThreshold = INITIAL_SPEECH_ENERGY_THRESHOLD.toDouble()
    private var noiseFloorEstimate = INITIAL_SPEECH_ENERGY_THRESHOLD * 0.25
    private var longTermEnergy = INITIAL_SPEECH_ENERGY_THRESHOLD.toDouble()
    
    // Callback for processed capture frames
    private var captureFrameCallback: ((ShortArray) -> Unit)? = null

    // Arbitrary stream buffer (PCM16 LE); accumulate until frame boundary
    private val streamBuffer = ArrayList<Byte>()
    private val frameSamples = sampleRate / 100 // 10ms
    private val frameBytesMono = frameSamples * 2 // bytes for mono 10ms frame
    private val tempShortFrame = ShortArray(frameSamples)
    private val stereoDownMixBuffer = ShortArray(frameSamples * 2)
    
    /**
     * Initialize all components but don't start audio processing yet
     */
    private fun initialize(): Boolean {
        if (isInitialized.get()) {
            return true
        }
        
        try {
            // Initialize APM engine
            if (!apmEngine.initialize()) {
                Log.e(TAG, "Failed to initialize APM engine")
                return false
            }
            
            // Reset synchronization counters for a fresh start
            apmEngine.resetSynchronization()
            
            // Initialize audio session
            if (!audioSession.initializeSession(audioManager)) {
                Log.e(TAG, "Failed to initialize audio session")
                apmEngine.release()
                return false
            }
            
            // Create audio threads
            audioThreads = AudioThreads(audioSession, apmEngine)
            
            // Set up capture callback forwarding and speech detection
            audioThreads.setCaptureCallback { processedAudio ->
                captureFrameCallback?.invoke(processedAudio)
                detectSpeech(processedAudio)
            }
            
            isInitialized.set(true)
            Log.d(TAG, "FullDuplexAudioClient initialized successfully")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error during initialization", e)
            cleanup()
            return false
        }
    }
    
    override fun start() {
        if (isActive.get()) {
            Log.w(TAG, "Audio client already started")
            return
        }
        
        if (!initialize()) {
            Log.e(TAG, "Failed to initialize before starting")
            return
        }
        
        try {
            // Start audio processing threads
            if (audioThreads.start()) {
                isActive.set(true)
                startSpeechDetectionThread()
                Log.d(TAG, "FullDuplexAudioClient started successfully")
            } else {
                Log.e(TAG, "Failed to start audio threads")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Error starting audio client", e)
        }
    }
    
    override fun stop() {
        if (!isActive.get()) {
            return
        }
        
        Log.d(TAG, "Stopping FullDuplexAudioClient...")
        
        try {
            // Stop MP3 playback
            stopMp3Loop()
            
            // Stop speech detection
            stopSpeechDetectionThread()
            
            // Stop audio threads
            if (::audioThreads.isInitialized) {
                audioThreads.stop()
            }
            
            isActive.set(false)
            Log.d(TAG, "FullDuplexAudioClient stopped")
            
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio client", e)
        }
    }
    
    override fun setAecEnabled(enabled: Boolean) {
        try {
            apmEngine.enableAec(enabled)
            Log.d(TAG, "AEC ${if (enabled) "enabled" else "disabled"}")
        } catch (e: Exception) {
            Log.e(TAG, "Error setting AEC enabled state", e)
        }
    }
    
    override fun setCaptureEnabled(enabled: Boolean) {
        try {
            if (::audioThreads.isInitialized) {
                audioThreads.setCaptureEnabled(enabled)
            }
            Log.d(TAG, "Capture ${if (enabled) "enabled" else "disabled"}")
        } catch (e: Exception) {
            Log.e(TAG, "Error setting capture enabled", e)
        }
    }
    
    override fun pushPlaybackPcm10ms(audioData: ShortArray) {
        if (!isActive.get()) {
            Log.w(TAG, "Cannot push audio - client not active")
            return
        }
        
        try {
            audioThreads.queuePlaybackAudio(audioData)
        } catch (e: Exception) {
            Log.e(TAG, "Error pushing playback PCM", e)
        }
    }

    override fun pushPlaybackPcmBytes(pcmBytes: ByteArray) {
        if (!isActive.get()) return
        synchronized(streamBuffer) {
            for (b in pcmBytes) streamBuffer.add(b)
            // Process as many full mono frames as possible
            while (true) {
                // Determine if data is mono or stereo by external contract? Assume mono unless size even multiple of 4 and stereo flag later.
                if (streamBuffer.size < frameBytesMono) break
                // Extract one 10ms mono frame
                for (i in 0 until frameBytesMono) {
                    stereoDownMixBuffer[i] = 0 // reuse later if needed
                }
                val frameByteArray = ByteArray(frameBytesMono)
                for (i in 0 until frameBytesMono) frameByteArray[i] = streamBuffer[i]
                // Remove consumed bytes
                repeat(frameBytesMono) { streamBuffer.removeAt(0) }
                // Convert LE bytes to shorts
                var si = 0
                var bi = 0
                while (si < frameSamples) {
                    val lo = frameByteArray[bi++].toInt() and 0xFF
                    val hi = frameByteArray[bi++].toInt()
                    tempShortFrame[si++] = ((hi shl 8) or lo).toShort()
                }
                // Push frame
                pushPlaybackPcm10ms(tempShortFrame.copyOf())
            }
        }
    }
    
    override fun onCaptureFrame(callback: (ShortArray) -> Unit) {
        this.captureFrameCallback = callback
    }
    
    override fun getAudioSessionInfo(): AudioSessionInfo {
        return if (isInitialized.get()) {
            audioSession.getSessionInfo()
        } else {
            AudioSessionInfo(0, sampleRate, sampleRate / 100, false)
        }
    }
    
    override fun isActive(): Boolean = isActive.get()
    
    override fun playMp3Loop(filePath: String): Boolean {
        return try {
            stopMp3Loop() // Stop any existing playback
            
            val file = File(filePath)
            if (!file.exists()) {
                Log.e(TAG, "Audio file not found: $filePath")
                return false
            }
            
            if (file.length() == 0L) {
                Log.e(TAG, "Audio file is empty: $filePath")
                return false
            }
            
            Log.d(TAG, "Audio file info: path=$filePath, size=${file.length()} bytes, exists=${file.exists()}, canRead=${file.canRead()}")
            
            // Decode audio file for AEC reference
            audioFileData = decodeAudioFile(filePath)
            if (audioFileData == null) {
                Log.e(TAG, "Failed to decode audio file for AEC reference")
                // Fall back to MediaPlayer without AEC reference
                return startMediaPlayerPlayback(filePath)
            }
            
            Log.d(TAG, "Audio file decoded: ${audioFileData!!.size} samples")
            
            // Start audio file playback thread for precise AEC reference
            isMp3Playing.set(true)
            // Tell audio threads that we (this class) will push render frames directly
            if (::audioThreads.isInitialized) {
                audioThreads.setExternalRenderFeederActive(true)
            }
            startAudioFilePlayback()
            
            Log.d(TAG, "Audio loop started with AEC reference: $filePath")
            true
            
        } catch (e: Exception) {
            Log.e(TAG, "Error starting audio loop", e)
            false
        }
    }
    
    /**
     * Fallback MediaPlayer approach when audio decoding fails
     */
    private fun startMediaPlayerPlayback(filePath: String): Boolean {
        return try {
            mediaPlayer = MediaPlayer().apply {
                try {
                    // Set audio stream type to media/music instead of voice call
                    setAudioStreamType(AudioManager.STREAM_MUSIC)
                    setDataSource(filePath) // Use file path directly instead of URI
                    isLooping = true
                    setOnPreparedListener { player ->
                        player.start()
                        isMp3Playing.set(true)
                        Log.d(TAG, "MediaPlayer fallback started: $filePath")
                    }
                    setOnErrorListener { _, what, extra ->
                        Log.e(TAG, "MediaPlayer error: what=$what, extra=$extra")
                        isMp3Playing.set(false)
                        true
                    }
                    setOnInfoListener { _, what, extra ->
                        Log.d(TAG, "MediaPlayer info: what=$what, extra=$extra")
                        false
                    }
                    prepareAsync()
                } catch (e: Exception) {
                    Log.e(TAG, "Error setting MediaPlayer data source", e)
                    return false
                }
            }
            
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error starting MediaPlayer fallback", e)
            false
        }
    }
    
    override fun stopMp3Loop(): Boolean {
        return try {
            // Stop audio file playback first
            isMp3Playing.set(false)

            if (::audioThreads.isInitialized) {
                audioThreads.setExternalRenderFeederActive(false)
            }
            
            // Stop audio file thread
            audioFileThread?.let { thread ->
                thread.interrupt()
                try {
                    thread.join(1000) // Wait up to 1 second
                } catch (e: InterruptedException) {
                    Log.w(TAG, "Interrupted while waiting for audio file thread to stop")
                }
                audioFileThread = null
            }
            
            // Stop MediaPlayer if it's being used
            mediaPlayer?.let { player ->
                if (player.isPlaying) {
                    player.stop()
                }
                player.release()
                mediaPlayer = null
            }
            
            // Clear audio file data
            audioFileData = null
            audioFilePlaybackPosition = 0
            
            Log.d(TAG, "Audio loop stopped")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio loop", e)
            false
        }
    }
    
    override fun isUserSpeaking(): Boolean = isUserSpeaking.get()
    
    override fun setSpeechDetectionCallback(callback: (Boolean) -> Unit) {
        this.speechDetectionCallback = callback
    }
    
    private fun detectSpeech(audioData: ShortArray) {
        var sum = 0.0
        var zeroCross = 0
        var prev = audioData[0].toInt()
        for (s in audioData) {
            val v = s.toInt()
            sum += (v * v)
            if ((v > 0 && prev < 0) || (v < 0 && prev > 0)) zeroCross++
            prev = v
        }
        val rms = kotlin.math.sqrt(sum / audioData.size)
        longTermEnergy = (1 - ENERGY_SMOOTH_ALPHA) * longTermEnergy + ENERGY_SMOOTH_ALPHA * rms
        if (rms < longTermEnergy * 0.8) {
            noiseFloorEstimate = noiseFloorEstimate * NOISE_FLOOR_DECAY + rms * (1 - NOISE_FLOOR_DECAY)
        }
        val minThreshold = noiseFloorEstimate * 3.0
        val target = maxOf(minThreshold, longTermEnergy * 0.55)
        adaptiveEnergyThreshold = (adaptiveEnergyThreshold * 0.9) + target * 0.1
        val speakingDetected = rms > adaptiveEnergyThreshold && zeroCross >= ZERO_CROSS_MIN
        val currentTime = System.currentTimeMillis()
        if (speakingDetected) {
            lastSpeechTime = currentTime
            if (!isUserSpeaking.get()) {
                isUserSpeaking.set(true)
                handleSpeechStateChange(true)
            }
        }
    }
    
    private fun startSpeechDetectionThread() {
        speechDetectionThread = thread(name = "SpeechDetection") {
            try {
                while (isActive.get()) {
                    val currentTime = System.currentTimeMillis()
                    if (isUserSpeaking.get() && (currentTime - lastSpeechTime) > SPEECH_SILENCE_THRESHOLD_MS) {
                        isUserSpeaking.set(false)
                        handleSpeechStateChange(false)
                    }
                    if (currentTime % 3000L < 120) {
                        Log.d(TAG, "VAD dbg: thr=${"%.1f".format(adaptiveEnergyThreshold)} lt=${"%.1f".format(longTermEnergy)} noise=${"%.1f".format(noiseFloorEstimate)} speaking=${isUserSpeaking.get()}")
                    }
                    Thread.sleep(100)
                }
            } catch (e: InterruptedException) {
                Log.d(TAG, "Speech detection thread interrupted")
            } catch (e: Exception) {
                Log.e(TAG, "Error in speech detection thread", e)
            }
        }
    }
    
    private fun stopSpeechDetectionThread() {
        speechDetectionThread?.interrupt()
        speechDetectionThread = null
    }
    
    private fun handleSpeechStateChange(speaking: Boolean) {
        Log.d(TAG, "Speech state changed: ${if (speaking) "speaking" else "silent"}")
        
        // Pause/resume MP3 based on speech detection
        if (isMp3Playing.get()) {
            if (audioFileData == null) {
                mediaPlayer?.let { player ->
                    try {
                        if (speaking && player.isPlaying) {
                            player.pause()
                            Log.d(TAG, "MediaPlayer paused due to speech detection")
                        } else if (!speaking && !player.isPlaying) {
                            player.start()
                            Log.d(TAG, "MediaPlayer resumed after silence period")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error controlling MediaPlayer playback", e)
                    }
                }
            } else {
                if (speaking) {
                    if (::audioThreads.isInitialized) {
                        audioThreads.clearPlaybackQueue()
                        Log.d(TAG, "Cleared playback queue on speech start")
                    }
                }
            }
        }
        
        // Notify callback
        speechDetectionCallback?.invoke(speaking)
    }
    
    private fun cleanup() {
        try {
            if (isInitialized.get()) {
                audioSession.releaseSessionAndRestoreAudio(audioManager)
                apmEngine.release()
                isInitialized.set(false)
            }
            stopMp3Loop()
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }
    
    /**
     * Decode audio file to PCM data for AEC reference
     */
    private fun decodeAudioFile(filePath: String): ShortArray? {
        return try {
            val retriever = MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            
            // Get audio format information
            val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val bitRate = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            
            Log.d(TAG, "Audio file: duration=${duration}ms, bitrate=${bitRate}")
            
            // For WAV files, we can read the PCM data directly
            if (filePath.endsWith(".wav", ignoreCase = true)) {
                decodeWavFile(filePath)
            } else {
                // For other formats, we'll use a simplified approach
                // In production, you'd want to use MediaExtractor and MediaCodec
                Log.w(TAG, "Non-WAV files require MediaExtractor implementation")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error decoding audio file", e)
            null
        }
    }
    
    /**
     * WAV decoder with header parsing, channel handling and resampling to 16kHz mono (linear interpolation)
     */
    private fun decodeWavFile(filePath: String): ShortArray? {
        return try {
            FileInputStream(File(filePath)).use { inputStream ->
                val header = ByteArray(44)
                if (inputStream.read(header) != 44) {
                    Log.e(TAG, "Invalid WAV header")
                    return null
                }
                val bb = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                // RIFF header check
                if (header[0] != 'R'.code.toByte() || header[1] != 'I'.code.toByte()) {
                    Log.e(TAG, "Not a RIFF file")
                    return null
                }
                val audioFormat = ((header[20].toInt() and 0xFF) or ((header[21].toInt() and 0xFF) shl 8))
                val numChannels = ((header[22].toInt() and 0xFF) or ((header[23].toInt() and 0xFF) shl 8))
                val sampleRate = (header[24].toInt() and 0xFF) or ((header[25].toInt() and 0xFF) shl 8) or ((header[26].toInt() and 0xFF) shl 16) or ((header[27].toInt() and 0xFF) shl 24)
                val bitsPerSample = ((header[34].toInt() and 0xFF) or ((header[35].toInt() and 0xFF) shl 8))
                Log.d(TAG, "WAV header parsed: format=$audioFormat channels=$numChannels rate=$sampleRate bps=$bitsPerSample")
                if (audioFormat != 1 || bitsPerSample != 16) {
                    Log.e(TAG, "Unsupported WAV format (only PCM 16-bit supported)")
                    return null
                }
                val pcmBytes = inputStream.readBytes()
                val samples = ShortArray(pcmBytes.size / 2)
                ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
                // If stereo, down-mix
                val monoSamples = if (numChannels == 2) {
                    val out = ShortArray(samples.size / 2)
                    var o = 0
                    var i = 0
                    while (i < samples.size - 1) {
                        out[o++] = (((samples[i].toInt() + samples[i+1].toInt()) / 2)).toShort()
                        i += 2
                    }
                    out
                } else samples
                // Resample if needed
                return if (sampleRate != this.sampleRate) {
                    resampleLinear(monoSamples, sampleRate, this.sampleRate)
                } else monoSamples
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error decoding WAV file", e)
            null
        }
    }

    private fun resampleLinear(input: ShortArray, srcRate: Int, dstRate: Int): ShortArray {
        val ratio = dstRate.toDouble() / srcRate.toDouble()
        val outLength = (input.size * ratio).toInt()
        val out = ShortArray(outLength)
        for (i in 0 until outLength) {
            val srcPos = i / ratio
            val idx = srcPos.toInt()
            val frac = srcPos - idx
            val s1 = input[idx].toInt()
            val s2 = if (idx + 1 < input.size) input[idx + 1].toInt() else s1
            out[i] = (s1 + ((s2 - s1) * frac)).toInt().coerceIn(-32768, 32767).toShort()
        }
        Log.d(TAG, "Resampled audio: srcRate=$srcRate dstRate=$dstRate in=${input.size} out=${out.size}")
        return out
    }
    
    /**
     * Start audio file playback thread that feeds data to both MediaPlayer and AEC
     */
    private fun startAudioFilePlayback() {
        audioFileThread = thread {
            val frameSize = sampleRate / 100 // 10ms frames
            val nanosPerFrame = 10_000_000L
            var nextDeadline = System.nanoTime()
            var framesPushed = 0L
            var lastLogTime = System.currentTimeMillis()
            val delayEstimateMs = 40 // initial guess for speaker->mic path
            apmEngine.setStreamDelay(delayEstimateMs)
            Log.d(TAG, "Initial stream delay set to ${delayEstimateMs}ms")

            try {
                audioFilePlaybackPosition = 0
                while (isMp3Playing.get() && audioFileData != null) {
                    val speaking = isUserSpeaking.get()
                    val currentData = audioFileData!!

                    if (!speaking) {
                        val frameStart = audioFilePlaybackPosition
                        val frameEnd = minOf(frameStart + frameSize, currentData.size)
                        if (frameStart < currentData.size) {
                            val frame = ShortArray(frameSize)
                            val actualFrameSize = frameEnd - frameStart
                            System.arraycopy(currentData, frameStart, frame, 0, actualFrameSize)
                            if (actualFrameSize < frameSize) {
                                for (i in actualFrameSize until frameSize) frame[i] = 0
                            }
                            apmEngine.pushRenderMono(frame)
                            audioThreads.queuePlaybackAudio(frame)
                            audioFilePlaybackPosition += frameSize
                            if (audioFilePlaybackPosition >= currentData.size) audioFilePlaybackPosition = 0
                            framesPushed++
                        } else {
                            audioFilePlaybackPosition = 0
                        }
                    } // else skip pushing frames to effectively pause playback during speech

                    // Drift-corrected sleep until next 10ms boundary
                    nextDeadline += nanosPerFrame
                    val now = System.nanoTime()
                    var sleepNanos = nextDeadline - now
                    if (sleepNanos < 0) {
                        // We are late; reset schedule
                        nextDeadline = now
                        sleepNanos = 0
                    }
                    if (sleepNanos > 0) {
                        try {
                            Thread.sleep(sleepNanos / 1_000_000L, (sleepNanos % 1_000_000L).toInt())
                        } catch (_: InterruptedException) { break }
                    }

                    // Periodic diagnostics
                    val ct = System.currentTimeMillis()
                    if (ct - lastLogTime > 5000) { // every 5s
                        Log.d(TAG, "Playback feeder stats: framesPushed=$framesPushed pos=$audioFilePlaybackPosition speaking=${speaking}")
                        lastLogTime = ct
                    }
                }
            } catch (ie: InterruptedException) {
                Log.d(TAG, "Audio file playback thread interrupted")
            } catch (e: Exception) {
                Log.e(TAG, "Error in audio file playback thread", e)
            } finally {
                Log.d(TAG, "Audio file playback thread finished")
            }
        }
    }
    
    /**
     * Clean up resources when the client is no longer needed
     */
    fun release() {
        stop()
        cleanup()
        Log.d(TAG, "FullDuplexAudioClient released")
    }
}
