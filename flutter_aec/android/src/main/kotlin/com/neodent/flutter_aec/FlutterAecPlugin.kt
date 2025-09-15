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
  }

  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var context: Context? = null
  private val aecEngine = AecEngine()
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    
    methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, METHOD_CHANNEL)
    methodChannel.setMethodCallHandler(this)
    
    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, EVENT_CHANNEL)
    eventChannel.setStreamHandler(this)

    // Set up processed frame listener
    aecEngine.setOnProcessedFrameListener { frameData ->
      mainHandler.post {
        eventSink?.success(frameData)
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
          
          val success = aecEngine.initialize(sampleRate, frameMs, echoMode, cngMode, enableNs)
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
            aecEngine.bufferFarend(pcmData)
            result.success(true)
          } else {
            result.error("INVALID_ARGS", "pcmData is required", null)
          }
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
    aecEngine.dispose()
    context = null
  }
}
