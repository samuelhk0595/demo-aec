package com.neodent.flutter_webrtc_aec

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.neodent.flutter_webrtc_aec.aec.FullDuplexAudioClient
import com.neodent.flutter_webrtc_aec.aec.FullDuplexAudioClientImpl
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterWebrtcAecPlugin */
class FlutterWebrtcAecPlugin: FlutterPlugin, MethodCallHandler {
    companion object {
        private const val TAG = "FlutterWebrtcAecPlugin"
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var audioClient: FullDuplexAudioClient? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_webrtc_aec")
        channel.setMethodCallHandler(this)
        context = flutterPluginBinding.applicationContext
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> {
                    val success = startAudioProcessing()
                    result.success(success)
                }
                "stop" -> {
                    val success = stopAudioProcessing()
                    result.success(success)
                }
                "setAecEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val success = setAecEnabled(enabled)
                    result.success(success)
                }
                "playAudio" -> {
                    val audioData = call.argument<IntArray>("audioData")
                    val success = playAudio(audioData)
                    result.success(success)
                }
                "queueAudioBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val success = queueAudioBytes(bytes)
                    result.success(success)
                }
                "isActive" -> {
                    val active = isActive()
                    result.success(active)
                }
                "playMp3Loop" -> {
                    val filePath = call.argument<String>("filePath") ?: ""
                    val success = playMp3Loop(filePath)
                    result.success(success)
                }
                "stopMp3Loop" -> {
                    val success = stopMp3Loop()
                    result.success(success)
                }
                "isUserSpeaking" -> {
                    val speaking = isUserSpeaking()
                    result.success(speaking)
                }
                else -> {
                    result.notImplemented()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling method call: ${call.method}", e)
            result.error("ERROR", e.message, null)
        }
    }

    private fun startAudioProcessing(): Boolean {
        return try {
            if (audioClient == null) {
                // Use mono playback for consistent frame size and to prevent pitch changes
                audioClient = FullDuplexAudioClientImpl(context, 16000, false)
                
                // Set up callbacks
                audioClient?.onCaptureFrame { processedAudio ->
                    // Convert ShortArray to IntArray for Flutter
                    val audioData = processedAudio.map { it.toInt() }.toIntArray()
                    mainHandler.post {
                        channel.invokeMethod("onCaptureFrame", mapOf("audioData" to audioData))
                    }
                }
                
                audioClient?.setSpeechDetectionCallback { isSpeaking ->
                    mainHandler.post {
                        channel.invokeMethod("onSpeechDetection", mapOf("isSpeaking" to isSpeaking))
                    }
                }
            }
            
            audioClient?.start()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error starting audio processing", e)
            false
        }
    }

    private fun stopAudioProcessing(): Boolean {
        return try {
            audioClient?.stop()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio processing", e)
            false
        }
    }

    private fun setAecEnabled(enabled: Boolean): Boolean {
        return try {
            audioClient?.setAecEnabled(enabled)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error setting AEC enabled", e)
            false
        }
    }

    private fun playAudio(audioData: IntArray?): Boolean {
        return try {
            if (audioData != null && audioClient != null) {
                // Convert IntArray to ShortArray
                val shortArray = audioData.map { it.toShort() }.toShortArray()
                audioClient?.pushPlaybackPcm10ms(shortArray)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error playing audio", e)
            false
        }
    }

    private fun queueAudioBytes(bytes: ByteArray?): Boolean {
        return try {
            if (bytes != null && audioClient != null) {
                audioClient?.pushPlaybackPcmBytes(bytes)
                true
            } else false
        } catch (e: Exception) {
            Log.e(TAG, "Error queueing audio bytes", e)
            false
        }
    }

    private fun isActive(): Boolean {
        return audioClient?.isActive() ?: false
    }

    private fun playMp3Loop(filePath: String): Boolean {
        Log.d(TAG, "playMp3Loop called with path: $filePath")
        val result = audioClient?.playMp3Loop(filePath) ?: false
        Log.d(TAG, "playMp3Loop result: $result")
        return result
    }

    private fun stopMp3Loop(): Boolean {
        return audioClient?.stopMp3Loop() ?: false
    }

    private fun isUserSpeaking(): Boolean {
        return audioClient?.isUserSpeaking() ?: false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            audioClient?.stop()
            (audioClient as? FullDuplexAudioClientImpl)?.release()
            audioClient = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
        channel.setMethodCallHandler(null)
    }
}
