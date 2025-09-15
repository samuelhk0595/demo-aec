
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Configuration class for AEC engine initialization
class AecConfig {
  /// Sample rate in Hz (16000 recommended)
  final int sampleRate;
  
  /// Frame duration in milliseconds (10 or 20)
  final int frameMs;
  
  /// Echo cancellation mode (0-4, 3 is default)
  final int echoMode;
  
  /// Enable comfort noise generation
  final bool cngMode;
  
  /// Enable noise suppression
  final bool enableNs;

  const AecConfig({
    this.sampleRate = 16000,
    this.frameMs = 20,
    this.echoMode = 3,
    this.cngMode = false,
    this.enableNs = true,
  });

  /// Calculate frame size in bytes (PCM16 mono)
  int get frameSizeBytes => sampleRate * frameMs ~/ 1000 * 2;
  
  /// Calculate frame size in samples
  int get frameSizeSamples => sampleRate * frameMs ~/ 1000;
}

/// Main Flutter AEC plugin class
/// 
/// Provides real-time acoustic echo cancellation for calling and walkie-talkie apps.
/// Uses a native pipeline approach (Option A) where audio capture, processing, and 
/// playback are handled on the native side for minimal latency.
class FlutterAec {
  static const MethodChannel _methodChannel = 
      MethodChannel('com.neodent.flutter_aec/methods');
  static const EventChannel _eventChannel = 
      EventChannel('com.neodent.flutter_aec/processed_frames');

  static FlutterAec? _instance;
  StreamSubscription<dynamic>? _processedFrameSubscription;
  StreamController<Uint8List>? _processedFrameController;
  
  AecConfig? _config;
  bool _isInitialized = false;
  bool _isCaptureStarted = false;
  bool _isPlaybackStarted = false;

  /// Get singleton instance
  static FlutterAec get instance {
    _instance ??= FlutterAec._();
    return _instance!;
  }

  FlutterAec._() {
    print('[FlutterAec] Instance created');
  }

  /// Stream of processed near-end frames (microphone after AEC processing)
  /// 
  /// Each frame is PCM16 mono audio data that has been processed for echo 
  /// cancellation and optionally noise suppression. Send these frames over 
  /// your network connection in VoIP/walkie-talkie applications.
  Stream<Uint8List> get processedNearStream {
    _processedFrameController ??= StreamController<Uint8List>.broadcast();
    return _processedFrameController!.stream;
  }

  /// Initialize the AEC engine with the specified configuration
  /// 
  /// Must be called before any other operations. Returns true if successful.
  /// 
  /// [config] - AEC configuration parameters
  Future<bool> initialize([AecConfig config = const AecConfig()]) async {
    print('[FlutterAec] initialize() called with config: sampleRate=${config.sampleRate}, frameMs=${config.frameMs}, echoMode=${config.echoMode}, cngMode=${config.cngMode}, enableNs=${config.enableNs}');
    
    if (_isInitialized) {
      print('[FlutterAec] Already initialized, skipping');
      return true;
    }

    try {
      print('[FlutterAec] Calling native initialize method...');
      final result = await _methodChannel.invokeMethod<bool>('initialize', {
        'sampleRate': config.sampleRate,
        'frameMs': config.frameMs,
        'echoMode': config.echoMode,
        'cngMode': config.cngMode,
        'enableNs': config.enableNs,
      });

      print('[FlutterAec] Native initialize returned: $result');

      if (result == true) {
        _config = config;
        _isInitialized = true;
        _setupEventStream();
        print('[FlutterAec] AEC engine initialized successfully');
      } else {
        print('[FlutterAec] Native initialize failed');
      }

      return result ?? false;
    } catch (e) {
      throw AecException('Failed to initialize AEC engine: $e');
    }
  }

  /// Start native audio capture
  /// 
  /// Begins capturing microphone audio using the native pipeline. 
  /// Processed frames will be emitted via [processedNearStream].
  /// Requires RECORD_AUDIO permission.
  Future<bool> startNativeCapture() async {
    print('[FlutterAec] startNativeCapture() called');
    _checkInitialized();
    
    if (_isCaptureStarted) {
      print('[FlutterAec] Capture already started, skipping');
      return true;
    }

    try {
      print('[FlutterAec] Calling native startNativeCapture...');
      final result = await _methodChannel.invokeMethod<bool>('startNativeCapture');
      print('[FlutterAec] Native startNativeCapture returned: $result');
      
      if (result == true) {
        _isCaptureStarted = true;
        print('[FlutterAec] Native capture started successfully');
      } else {
        print('[FlutterAec] Native capture failed to start');
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in startNativeCapture: $e');
      throw AecException('Failed to start native capture: $e');
    }
  }

  /// Start native audio playback
  /// 
  /// Begins the native audio playback pipeline. Far-end audio frames
  /// buffered via [bufferFarend] will be played through the speaker.
  Future<bool> startNativePlayback() async {
    print('[FlutterAec] startNativePlayback() called');
    _checkInitialized();
    
    if (_isPlaybackStarted) {
      print('[FlutterAec] Playback already started, skipping');
      return true;
    }

    try {
      print('[FlutterAec] Calling native startNativePlayback...');
      final result = await _methodChannel.invokeMethod<bool>('startNativePlayback');
      print('[FlutterAec] Native startNativePlayback returned: $result');
      
      if (result == true) {
        _isPlaybackStarted = true;
        print('[FlutterAec] Native playback started successfully');
      } else {
        print('[FlutterAec] Native playback failed to start');
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in startNativePlayback: $e');
      throw AecException('Failed to start native playback: $e');
    }
  }

  /// Provide an estimated external playback delay (in milliseconds) when you are
  /// NOT using the plugin's native playback pipeline but an app-level audio player.
  /// This helps the AEC tune echo path delay. Call after your playback engine is ready.
  Future<void> setExternalPlaybackDelay(int delayMs) async {
    _checkInitialized();
    if (delayMs < 0) delayMs = 0;
    try {
      print('[FlutterAec] setExternalPlaybackDelay($delayMs)');
      await _methodChannel.invokeMethod('setExternalPlaybackDelay', {
        'delayMs': delayMs,
      });
    } catch (e) {
      print('[FlutterAec] Exception in setExternalPlaybackDelay: $e');
      throw AecException('Failed to set external playback delay: $e');
    }
  }

  /// Stop native audio capture
  Future<void> stopNativeCapture() async {
    print('[FlutterAec] stopNativeCapture() called');
    if (!_isCaptureStarted) {
      print('[FlutterAec] Capture not started, skipping stop');
      return;
    }

    try {
      print('[FlutterAec] Calling native stopNativeCapture...');
      await _methodChannel.invokeMethod('stopNativeCapture');
      _isCaptureStarted = false;
      print('[FlutterAec] Native capture stopped successfully');
    } catch (e) {
      print('[FlutterAec] Exception in stopNativeCapture: $e');
      throw AecException('Failed to stop native capture: $e');
    }
  }

  /// Stop native audio playback
  Future<void> stopNativePlayback() async {
    print('[FlutterAec] stopNativePlayback() called');
    if (!_isPlaybackStarted) {
      print('[FlutterAec] Playback not started, skipping stop');
      return;
    }

    try {
      print('[FlutterAec] Calling native stopNativePlayback...');
      await _methodChannel.invokeMethod('stopNativePlayback');
      _isPlaybackStarted = false;
      print('[FlutterAec] Native playback stopped successfully');
    } catch (e) {
      print('[FlutterAec] Exception in stopNativePlayback: $e');
      throw AecException('Failed to stop native playback: $e');
    }
  }

  /// Buffer far-end audio frame for playback and echo cancellation
  /// 
  /// Call this method with each incoming audio frame from the remote party
  /// just before playing it. The same frame data will be used internally
  /// for echo cancellation reference.
  /// 
  /// [pcmFrame] - PCM16 mono audio frame. Size must match config.frameSizeBytes
  Future<void> bufferFarend(Uint8List pcmFrame) async {
    _checkInitialized();
    
    if (pcmFrame.length != _config!.frameSizeBytes) {
      print('[FlutterAec] Invalid frame size: ${pcmFrame.length}, expected: ${_config!.frameSizeBytes}');
      throw ArgumentError(
        'Invalid frame size: ${pcmFrame.length}, expected: ${_config!.frameSizeBytes}'
      );
    }

    try {
      await _methodChannel.invokeMethod('bufferFarend', {
        'pcmData': pcmFrame,
      });
      // Don't log every frame as it's too verbose, but log occasionally
      // print('[FlutterAec] Buffered farend frame: ${pcmFrame.length} bytes');
    } catch (e) {
      print('[FlutterAec] Exception in bufferFarend: $e');
      throw AecException('Failed to buffer farend: $e');
    }
  }

  /// Dispose the AEC engine and clean up resources
  /// 
  /// Stops all audio operations and releases native resources.
  /// The engine must be reinitialized before use after disposal.
  Future<void> dispose() async {
    if (!_isInitialized) return;

    try {
      await stopNativeCapture();
      await stopNativePlayback();
      await _methodChannel.invokeMethod('dispose');

      _processedFrameSubscription?.cancel();
      _processedFrameController?.close();
      
      _processedFrameSubscription = null;
      _processedFrameController = null;
      _config = null;
      _isInitialized = false;
      _isCaptureStarted = false;
      _isPlaybackStarted = false;
    } catch (e) {
      throw AecException('Failed to dispose AEC engine: $e');
    }
  }

  /// Get current configuration
  AecConfig? get config => _config;

  /// Check if engine is initialized
  bool get isInitialized => _isInitialized;

  /// Check if capture is active
  bool get isCaptureStarted => _isCaptureStarted;

  /// Check if playback is active  
  bool get isPlaybackStarted => _isPlaybackStarted;

  void _setupEventStream() {
    print('[FlutterAec] Setting up event stream...');
    _processedFrameController ??= StreamController<Uint8List>.broadcast();
    
    _processedFrameSubscription = _eventChannel
        .receiveBroadcastStream()
        .cast<Uint8List>()
        .listen(
          (frameData) {
            print('[FlutterAec] Received processed frame: ${frameData.length} bytes');
            _processedFrameController?.add(frameData);
          },
          onError: (error) {
            print('[FlutterAec] Event stream error: $error');
            _processedFrameController?.addError(
              AecException('Processed frame stream error: $error')
            );
          },
          onDone: () {
            print('[FlutterAec] Event stream finished');
          },
        );
    print('[FlutterAec] Event stream setup complete');
  }

  void _checkInitialized() {
    if (!_isInitialized) {
      throw StateError('AEC engine not initialized. Call initialize() first.');
    }
  }
}

/// Exception thrown by FlutterAec operations
class AecException implements Exception {
  final String message;
  
  const AecException(this.message);
  
  @override
  String toString() => 'AecException: $message';
}
