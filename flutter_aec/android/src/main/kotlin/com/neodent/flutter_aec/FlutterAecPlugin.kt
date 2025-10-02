package com.neodent.flutter_aec

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterAecPlugin */
class FlutterAecPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  companion object {
    private const val TAG = "FlutterAecPlugin"
    private const val METHOD_CHANNEL = "com.neodent.flutter_aec/methods"
    private const val EVENT_CHANNEL = "com.neodent.flutter_aec/processed_frames"
    private const val VAD_EVENT_CHANNEL = "com.neodent.flutter_aec/vad_events"
  }

  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var vadEventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var vadEventSink: EventChannel.EventSink? = null
  private var context: Context? = null
  private val aecEngine = AecEngine()
  private val mainHandler = Handler(Looper.getMainLooper())

  private val vadStreamHandler = object : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
      vadEventSink = events
      Log.d(TAG, "VAD event channel listener attached")
    }

    override fun onCancel(arguments: Any?) {
      vadEventSink = null
      Log.d(TAG, "VAD event channel listener detached")
    }
  }

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    
    methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, METHOD_CHANNEL)
    methodChannel.setMethodCallHandler(this)
    
    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, EVENT_CHANNEL)
    eventChannel.setStreamHandler(this)

    vadEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, VAD_EVENT_CHANNEL)
    vadEventChannel.setStreamHandler(vadStreamHandler)

    // Set up processed frame listener
    aecEngine.setOnProcessedFrameListener { frameData ->
      mainHandler.post {
        eventSink?.success(frameData)
      }
    }

    aecEngine.setOnVadEventListener { vadEvent ->
      val payload = mapOf(
        "active" to vadEvent.active,
        "timestampMs" to vadEvent.timestampMs,
        "mode" to vadEvent.mode,
        "frameMs" to vadEvent.frameMs,
        "hangoverMs" to vadEvent.hangoverMs
      )
      mainHandler.post {
        vadEventSink?.success(payload)
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    try {
      when (call.method) {
        "initialize" -> {
          val sampleRate = call.argument<Int>("sampleRate") ?: 16000
          val frameMs = call.argument<Int>("frameMs") ?: 20
          val echoMode = call.argument<Int>("echoMode") ?: 3
          val cngMode = call.argument<Boolean>("cngMode") ?: false
          val enableNs = call.argument<Boolean>("enableNs") ?: true
          val vadConfig = call.argument<Map<String, Any?>>("vadConfig")
          val vadEnabled = vadConfig?.get("enabled") as? Boolean ?: false
          val vadMode = vadConfig?.get("mode") as? Int ?: 2
          val vadFrameMs = vadConfig?.get("frameMs") as? Int ?: 30
          val vadHangoverMs = vadConfig?.get("hangoverMs") as? Int ?: 300
          val vadHangoverEnabled = vadConfig?.get("hangoverEnabled") as? Boolean ?: true
          val agcConfig = call.argument<Map<String, Any?>>("agcConfig")
          val agcEnabled = agcConfig?.get("enabled") as? Boolean ?: false
          val agcMode = agcConfig?.get("mode") as? Int ?: 2
          val agcTargetLevelDbfs = agcConfig?.get("targetLevelDbfs") as? Int ?: 3
          val agcCompressionGainDb = agcConfig?.get("compressionGainDb") as? Int ?: 9
          val agcEnableLimiter = agcConfig?.get("enableLimiter") as? Boolean ?: true
          
          val success = aecEngine.initialize(
            sampleRate,
            frameMs,
            echoMode,
            cngMode,
            enableNs,
            vadEnabled,
            vadMode,
            vadFrameMs,
            vadHangoverMs,
            vadHangoverEnabled,
            agcEnabled,
            agcMode,
            agcTargetLevelDbfs,
            agcCompressionGainDb,
            agcEnableLimiter
          )
          result.success(success)
        }
        
        "startNativeCapture" -> {
          context?.let { ctx ->
            val success = aecEngine.startNativeCapture(ctx)
            result.success(success)
          } ?: result.error("NO_CONTEXT", "Context not available", null)
        }
        
        "startNativePlayback" -> {
          val success = aecEngine.startNativePlayback()
          result.success(success)
        }
        
        "stopNativeCapture" -> {
          aecEngine.stopNativeCapture()
          result.success(true)
        }
        
        "stopNativePlayback" -> {
          aecEngine.stopNativePlayback()
          result.success(true)
        }
        
        "bufferFarend" -> {
          val pcmData = call.argument<ByteArray>("pcmData")
          if (pcmData != null) {
            if (pcmData.size % 640 == 0) {
              Log.d(TAG, "bufferFarend received ${pcmData.size} bytes")
            }
            aecEngine.bufferFarend(pcmData)
            result.success(true)
          } else {
            result.error("INVALID_ARGS", "pcmData is required", null)
          }
        }
        "setExternalPlaybackDelay" -> {
          val delayMs = call.argument<Int>("delayMs") ?: 0
          Log.d(TAG, "setExternalPlaybackDelay($delayMs)")
          aecEngine.setExternalPlaybackDelay(delayMs)
          result.success(true)
        }

        "configureVad" -> {
          val config = call.argument<Map<String, Any?>>("config")
          if (config == null) {
            result.error("INVALID_ARGS", "config is required", null)
          } else {
            val enabled = config["enabled"] as? Boolean ?: false
            val mode = config["mode"] as? Int ?: 2
            val frameMsConfig = config["frameMs"] as? Int ?: 30
            val hangoverMs = config["hangoverMs"] as? Int ?: 300
            val hangoverEnabled = config["hangoverEnabled"] as? Boolean ?: true
            val success = aecEngine.configureVad(enabled, mode, frameMsConfig, hangoverMs, hangoverEnabled)
            result.success(success)
          }
        }

        "setVadEnabled" -> {
          val enabled = call.argument<Boolean>("enabled") ?: false
          val success = aecEngine.setVadEnabled(enabled)
          result.success(success)
        }

        "configureAgc" -> {
          val config = call.argument<Map<String, Any?>>("config")
          if (config == null) {
            result.error("INVALID_ARGS", "config is required", null)
          } else {
            val enabled = config["enabled"] as? Boolean ?: false
            val mode = config["mode"] as? Int ?: 2
            val targetLevelDbfs = config["targetLevelDbfs"] as? Int ?: 3
            val compressionGainDb = config["compressionGainDb"] as? Int ?: 9
            val enableLimiter = config["enableLimiter"] as? Boolean ?: true
            val success = aecEngine.configureAgc(enabled, mode, targetLevelDbfs, compressionGainDb, enableLimiter)
            result.success(success)
          }
        }

        "setAgcEnabled" -> {
          val enabled = call.argument<Boolean>("enabled") ?: false
          val success = aecEngine.setAgcEnabled(enabled)
          result.success(success)
        }

        "getVadState" -> {
          result.success(
            mapOf(
              "config" to aecEngine.currentVadConfig(),
              "active" to aecEngine.currentVadState()
            )
          )
        }

        "getAgcState" -> {
          result.success(
            mapOf(
              "config" to aecEngine.currentAgcConfig()
            )
          )
        }

        "dispose" -> {
          aecEngine.dispose()
          result.success(true)
        }
        
        else -> {
          result.notImplemented()
        }
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error handling method call: ${call.method}", e)
      result.error("PLUGIN_ERROR", e.message, e.stackTraceToString())
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    Log.d(TAG, "Event channel listener attached")
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
    Log.d(TAG, "Event channel listener detached")
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    vadEventChannel.setStreamHandler(null)
    vadEventSink = null
    aecEngine.setOnVadEventListener(null)
    aecEngine.dispose()
    context = null
  }
}
