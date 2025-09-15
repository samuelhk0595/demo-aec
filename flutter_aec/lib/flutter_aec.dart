
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

  FlutterAec._();

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
    if (_isInitialized) {
      throw StateError('AEC engine already initialized');
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('initialize', {
        'sampleRate': config.sampleRate,
        'frameMs': config.frameMs,
        'echoMode': config.echoMode,
        'cngMode': config.cngMode,
        'enableNs': config.enableNs,
      });

      if (result == true) {
        _config = config;
        _isInitialized = true;
        _setupEventStream();
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
    _checkInitialized();
    
    if (_isCaptureStarted) {
      throw StateError('Capture already started');
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('startNativeCapture');
      if (result == true) {
        _isCaptureStarted = true;
      }
      return result ?? false;
    } catch (e) {
      throw AecException('Failed to start native capture: $e');
    }
  }

  /// Start native audio playback
  /// 
  /// Begins the native audio playback pipeline. Far-end audio frames
  /// buffered via [bufferFarend] will be played through the speaker.
  Future<bool> startNativePlayback() async {
    _checkInitialized();
    
    if (_isPlaybackStarted) {
      throw StateError('Playback already started');
    }

    try {
      final result = await _methodChannel.invokeMethod<bool>('startNativePlayback');
      if (result == true) {
        _isPlaybackStarted = true;
      }
      return result ?? false;
    } catch (e) {
      throw AecException('Failed to start native playback: $e');
    }
  }

  /// Stop native audio capture
  Future<void> stopNativeCapture() async {
    if (!_isCaptureStarted) return;

    try {
      await _methodChannel.invokeMethod('stopNativeCapture');
      _isCaptureStarted = false;
    } catch (e) {
      throw AecException('Failed to stop native capture: $e');
    }
  }

  /// Stop native audio playback
  Future<void> stopNativePlayback() async {
    if (!_isPlaybackStarted) return;

    try {
      await _methodChannel.invokeMethod('stopNativePlayback');
      _isPlaybackStarted = false;
    } catch (e) {
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
      throw ArgumentError(
        'Invalid frame size: ${pcmFrame.length}, expected: ${_config!.frameSizeBytes}'
      );
    }

    try {
      await _methodChannel.invokeMethod('bufferFarend', {
        'pcmData': pcmFrame,
      });
    } catch (e) {
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
    _processedFrameController ??= StreamController<Uint8List>.broadcast();
    
    _processedFrameSubscription = _eventChannel
        .receiveBroadcastStream()
        .cast<Uint8List>()
        .listen(
          (frameData) {
            _processedFrameController?.add(frameData);
          },
          onError: (error) {
            _processedFrameController?.addError(
              AecException('Processed frame stream error: $error')
            );
          },
        );
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
