
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Configuration for the WebRTC Voice Activity Detector.
class VadConfig {
  /// Whether the VAD should be enabled.
  final bool enabled;

  /// Aggressiveness mode (0-3) where higher is more restrictive.
  final int mode;

  /// Frame duration (ms) fed into the VAD. Supported: 10, 20, 30.
  final int frameMs;

  /// Duration (ms) to keep reporting speech after the last detection.
  final int hangoverMs;

  /// Whether hangover behaviour is enabled.
  final bool hangoverEnabled;

  const VadConfig({
    this.enabled = false,
    this.mode = 2,
    this.frameMs = 30,
    this.hangoverMs = 300,
    this.hangoverEnabled = true,
  });

  VadConfig copyWith({
    bool? enabled,
    int? mode,
    int? frameMs,
    int? hangoverMs,
    bool? hangoverEnabled,
  }) {
    return VadConfig(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      frameMs: frameMs ?? this.frameMs,
      hangoverMs: hangoverMs ?? this.hangoverMs,
      hangoverEnabled: hangoverEnabled ?? this.hangoverEnabled,
    );
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'mode': mode,
        'frameMs': frameMs,
        'hangoverMs': hangoverMs,
        'hangoverEnabled': hangoverEnabled,
      };
}

/// Configuration for the WebRTC Automatic Gain Control.
class AgcConfig {
  /// Whether AGC should be enabled.
  final bool enabled;

  /// AGC mode: 0=unchanged, 1=adaptive analog, 2=adaptive digital, 3=fixed digital (default: 2)
  final int mode;

  /// Target output level in dBFS (0-31, default: 3)
  final int targetLevelDbfs;

  /// Maximum compression gain in dB (0-90, default: 9)
  final int compressionGainDb;

  /// Enable output limiter to prevent clipping
  final bool enableLimiter;

  const AgcConfig({
    this.enabled = false,
    this.mode = 2,
    this.targetLevelDbfs = 3,
    this.compressionGainDb = 9,
    this.enableLimiter = true,
  });

  AgcConfig copyWith({
    bool? enabled,
    int? mode,
    int? targetLevelDbfs,
    int? compressionGainDb,
    bool? enableLimiter,
  }) {
    return AgcConfig(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      targetLevelDbfs: targetLevelDbfs ?? this.targetLevelDbfs,
      compressionGainDb: compressionGainDb ?? this.compressionGainDb,
      enableLimiter: enableLimiter ?? this.enableLimiter,
    );
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'mode': mode,
        'targetLevelDbfs': targetLevelDbfs,
        'compressionGainDb': compressionGainDb,
        'enableLimiter': enableLimiter,
      };
}

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

  /// Voice activity detector configuration.
  final VadConfig vadConfig;

  /// Automatic gain control configuration.
  final AgcConfig agcConfig;

  const AecConfig({
    this.sampleRate = 16000,
    this.frameMs = 20,
    this.echoMode = 3,
    this.cngMode = false,
    this.enableNs = true,
    this.vadConfig = const VadConfig(),
    this.agcConfig = const AgcConfig(),
  });

  /// Calculate frame size in bytes (PCM16 mono)
  int get frameSizeBytes => sampleRate * frameMs ~/ 1000 * 2;
  
  /// Calculate frame size in samples
  int get frameSizeSamples => sampleRate * frameMs ~/ 1000;
}

/// Event dispatched whenever voice activity state changes.
class VoiceActivityEvent {
  /// True when speech is currently detected.
  final bool isActive;

  /// Timestamp (UTC) when this decision was made.
  final DateTime timestamp;

  /// Aggressiveness mode used by the detector.
  final int mode;

  /// Frame size (ms) used for VAD processing.
  final int frameMs;

  /// Hangover duration (ms) configured for VAD.
  final int hangoverMs;

  const VoiceActivityEvent({
    required this.isActive,
    required this.timestamp,
    required this.mode,
    required this.frameMs,
    required this.hangoverMs,
  });

  factory VoiceActivityEvent.fromMap(Map<dynamic, dynamic> map) {
    final timestampMs = map['timestampMs'];
    final intTimestamp = timestampMs is int
        ? timestampMs
        : (timestampMs is double ? timestampMs.round() : DateTime.now().millisecondsSinceEpoch);
    return VoiceActivityEvent(
      isActive: map['active'] == true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(intTimestamp, isUtc: true),
      mode: map['mode'] is int ? map['mode'] as int : 2,
      frameMs: map['frameMs'] is int ? map['frameMs'] as int : 30,
      hangoverMs: map['hangoverMs'] is int ? map['hangoverMs'] as int : 300,
    );
  }

  @override
  String toString() =>
      'VoiceActivityEvent(isActive: $isActive, timestamp: $timestamp, mode: $mode, frameMs: $frameMs, hangoverMs: $hangoverMs)';
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
  static const EventChannel _vadEventChannel = 
    EventChannel('com.neodent.flutter_aec/vad_events');

  static FlutterAec? _instance;
  StreamSubscription<dynamic>? _processedFrameSubscription;
  StreamController<Uint8List>? _processedFrameController;
  StreamSubscription<dynamic>? _vadEventSubscription;
  StreamController<VoiceActivityEvent>? _vadEventController;
  void Function(VoiceActivityEvent event)? _vadCallback;
  
  AecConfig? _config;
  VadConfig? _vadConfig;
  AgcConfig? _agcConfig;
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

  /// Stream emitting voice activity state changes.
  Stream<VoiceActivityEvent> get voiceActivityStream {
    _vadEventController ??= StreamController<VoiceActivityEvent>.broadcast();
    return _vadEventController!.stream;
  }

  /// Register a callback that runs whenever the voice activity state changes.
  void setVoiceActivityCallback(void Function(VoiceActivityEvent event)? callback) {
    _vadCallback = callback;
  }

  /// Initialize the AEC engine with the specified configuration
  /// 
  /// Must be called before any other operations. Returns true if successful.
  /// 
  /// [config] - AEC configuration parameters
  Future<bool> initialize([AecConfig config = const AecConfig()]) async {
    print('[FlutterAec] initialize() called with config: sampleRate=${config.sampleRate}, frameMs=${config.frameMs}, echoMode=${config.echoMode}, cngMode=${config.cngMode}, enableNs=${config.enableNs}, vadEnabled=${config.vadConfig.enabled}, agcEnabled=${config.agcConfig.enabled}');
    
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
        'vadConfig': config.vadConfig.toMap(),
        'agcConfig': config.agcConfig.toMap(),
      });

      print('[FlutterAec] Native initialize returned: $result');

      if (result == true) {
        _config = config;
        _vadConfig = config.vadConfig;
        _agcConfig = config.agcConfig;
        _isInitialized = true;
        _setupEventStream();
        print('[FlutterAec] AEC engine initialized successfully');
      } else {
        print('[FlutterAec] Native initialize failed');
      }

      return result ?? false;
    } catch (e) {
      throw AecException('Failed to query VAD state: $e');
    }
  }

  /// Query the native layer for the current AGC configuration.
  Future<AgcConfig?> getCurrentAgcState() async {
    _checkInitialized();
    try {
      final response = await _methodChannel.invokeMapMethod<String, dynamic>('getAgcState');
      if (response == null) {
        return null;
      }
      final configMap = response['config'];
      if (configMap is Map) {
        _agcConfig = AgcConfig(
          enabled: configMap['enabled'] == true,
          mode: configMap['mode'] is int ? configMap['mode'] as int : _agcConfig?.mode ?? 2,
          targetLevelDbfs: configMap['targetLevelDbfs'] is int ? configMap['targetLevelDbfs'] as int : _agcConfig?.targetLevelDbfs ?? 3,
          compressionGainDb: configMap['compressionGainDb'] is int ? configMap['compressionGainDb'] as int : _agcConfig?.compressionGainDb ?? 9,
          enableLimiter: configMap['enableLimiter'] != false,
        );
        return _agcConfig;
      }
      return _agcConfig;
    } catch (e) {
      print('[FlutterAec] Exception in getCurrentAgcState: $e');
      throw AecException('Failed to query AGC state: $e');
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

  /// Update the VAD configuration while the engine is running.
  Future<bool> configureVad(VadConfig config) async {
    _checkInitialized();
    try {
      final result = await _methodChannel.invokeMethod<bool>('configureVad', {
        'config': config.toMap(),
      });
      if (result == true) {
        _vadConfig = config;
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in configureVad: $e');
      throw AecException('Failed to configure VAD: $e');
    }
  }

  /// Enable or disable the VAD without changing other parameters.
  Future<bool> setVadEnabled(bool enabled) async {
    _checkInitialized();
    try {
      final result = await _methodChannel.invokeMethod<bool>('setVadEnabled', {
        'enabled': enabled,
      });
      if (result == true && _vadConfig != null) {
        _vadConfig = _vadConfig!.copyWith(enabled: enabled);
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in setVadEnabled: $e');
      throw AecException('Failed to toggle VAD: $e');
    }
  }

  /// Update the AGC configuration while the engine is running.
  Future<bool> configureAgc(AgcConfig config) async {
    _checkInitialized();
    try {
      final result = await _methodChannel.invokeMethod<bool>('configureAgc', {
        'config': config.toMap(),
      });
      if (result == true) {
        _agcConfig = config;
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in configureAgc: $e');
      throw AecException('Failed to configure AGC: $e');
    }
  }

  /// Enable or disable the AGC without changing other parameters.
  Future<bool> setAgcEnabled(bool enabled) async {
    _checkInitialized();
    try {
      final result = await _methodChannel.invokeMethod<bool>('setAgcEnabled', {
        'enabled': enabled,
      });
      if (result == true && _agcConfig != null) {
        _agcConfig = _agcConfig!.copyWith(enabled: enabled);
      }
      return result ?? false;
    } catch (e) {
      print('[FlutterAec] Exception in setAgcEnabled: $e');
      throw AecException('Failed to toggle AGC: $e');
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
      _vadEventSubscription?.cancel();
      _vadEventController?.close();
      
      _processedFrameSubscription = null;
      _processedFrameController = null;
      _vadEventSubscription = null;
      _vadEventController = null;
      _config = null;
      _vadConfig = null;
      _agcConfig = null;
      _vadCallback = null;
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

  /// Current VAD configuration, if the engine has been initialized.
  VadConfig? get vadConfig => _vadConfig;

  /// Current AGC configuration, if the engine has been initialized.
  AgcConfig? get agcConfig => _agcConfig;

  /// Query the native layer for the current VAD state.
  Future<VoiceActivityEvent?> getCurrentVadState() async {
    _checkInitialized();
    try {
      final response = await _methodChannel.invokeMapMethod<String, dynamic>('getVadState');
      if (response == null) {
        return null;
      }
      final active = response['active'] == true;
      final configMap = response['config'];
      if (configMap is Map) {
        _vadConfig = VadConfig(
          enabled: configMap['enabled'] == true,
          mode: configMap['mode'] is int ? configMap['mode'] as int : _vadConfig?.mode ?? 2,
          frameMs: configMap['frameMs'] is int ? configMap['frameMs'] as int : _vadConfig?.frameMs ?? 30,
          hangoverMs: configMap['hangoverMs'] is int ? configMap['hangoverMs'] as int : _vadConfig?.hangoverMs ?? 300,
          hangoverEnabled: configMap['hangoverEnabled'] != false,
        );
      }
      return VoiceActivityEvent(
        isActive: active,
        timestamp: DateTime.now().toUtc(),
        mode: _vadConfig?.mode ?? 2,
        frameMs: _vadConfig?.frameMs ?? 30,
        hangoverMs: _vadConfig?.hangoverMs ?? 300,
      );
    } catch (e) {
      print('[FlutterAec] Exception in getCurrentVadState: $e');
      throw AecException('Failed to query VAD state: $e');
    }
  }

  void _setupEventStream() {
    print('[FlutterAec] Setting up event stream...');
    _processedFrameController ??= StreamController<Uint8List>.broadcast();
    _vadEventController ??= StreamController<VoiceActivityEvent>.broadcast();
    
    _processedFrameSubscription?.cancel();
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

    _vadEventSubscription?.cancel();
    _vadEventSubscription = _vadEventChannel
        .receiveBroadcastStream()
        .cast<Map<dynamic, dynamic>>()
        .listen(
          _handleVadPayload,
          onError: (error) {
            print('[FlutterAec] VAD stream error: $error');
            _vadEventController?.addError(
              AecException('VAD event stream error: $error')
            );
          },
          onDone: () {
            print('[FlutterAec] VAD event stream finished');
          },
        );
    print('[FlutterAec] Event stream setup complete');
  }

  void _handleVadPayload(Map<dynamic, dynamic> event) {
    try {
      final mapped = VoiceActivityEvent.fromMap(event);
      _vadEventController?.add(mapped);
      final callback = _vadCallback;
      if (callback != null) {
        callback(mapped);
      }
    } catch (e, stack) {
      print('[FlutterAec] Failed to parse VAD payload: $e');
      _vadEventController?.addError(e, stack);
    }
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
