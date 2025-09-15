import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_aec/flutter_aec.dart';

class MicrophoneService {
  bool _isMuted = false;
  bool _isRecording = false;
  final _aec = FlutterAec.instance;
  StreamSubscription<Uint8List>? _aecFrameSubscription;

  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  bool get isMuted => _isMuted;
  bool get isRecording => _isRecording;

  final void Function(String message)? onLog;
  final void Function(String error)? onError;

  MicrophoneService({
    this.onLog,
    this.onError,
  });

  Future<bool> requestPermissions() async {
    try {
      // The AEC plugin will handle permission requests internally
      return true;
    } catch (e) {
      onError?.call('Error requesting microphone permissions: $e');
      return false;
    }
  }

  Future<bool> initializeAec() async {
    try {
      if (_aec.isInitialized) {
        return true;
      }

      const config = AecConfig(
        sampleRate: 16000,
        frameMs: 20,
        echoMode: 1,        // Default echo cancellation mode
        cngMode: false,     // Disable comfort noise generation for walkie-talkie
        enableNs: false,     // Enable noise suppression
      );

      final success = await _aec.initialize(config);
      if (success) {
        onLog?.call('AEC Engine initialized successfully');
        return true;  
      } else {
        onError?.call('Failed to initialize AEC Engine');
        return false;
      }
    } catch (e) {
      onError?.call('Error initializing AEC: $e');
      return false;
    }
  }

  Future<void> startRecording() async {
    if (_isRecording) return;
    
    try {
      // Initialize AEC if not already done
      final aecReady = await initializeAec();
      if (!aecReady) {
        onError?.call('AEC initialization failed');
        return;
      }

      // Start AEC native capture
      final success = await _aec.startNativeCapture();
      if (!success) {
        onError?.call('Failed to start AEC native capture');
        return;
      }

      _isRecording = true;

      // Subscribe to processed frames from AEC
      _aecFrameSubscription = _aec.processedNearStream.listen(
        (frameData) => _onAudioData(frameData),
        onError: (error) {
          onError?.call('AEC Frame Stream Error: $error');
          _stopRecording();
        },
        onDone: () {
          onLog?.call('AEC processed frame stream finished.');
          _isRecording = false;
        },
        cancelOnError: true,
      );
      
      onLog?.call('Started AEC-processed microphone recording');
    } catch (e) {
      onError?.call('Error starting AEC microphone: $e');
      _isRecording = false;
    }
  }

  void _onAudioData(Uint8List data) {
    if (_isRecording && !_isMuted) {
      _audioDataController.add(data);
      onLog?.call('⬆️ Sending AEC-processed audio: ${data.length} bytes');
    } else if (_isMuted) {
      // Send silence when muted
      final silentData = Uint8List(data.length);
      _audioDataController.add(silentData);
    }
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    onLog?.call('Microphone ${muted ? 'muted' : 'unmuted'}');
  }

  void toggleMute() {
    setMuted(!_isMuted);
  }

  Future<void> stopRecording() async {
    await _stopRecording();
  }

  Future<void> _stopRecording() async {
    if (_isRecording) {
      await _aec.stopNativeCapture();
      _isRecording = false;
      onLog?.call('AEC microphone recording stopped');
    }
    
    await _aecFrameSubscription?.cancel();
    _aecFrameSubscription = null;
  }

  void dispose() async {
    await _stopRecording();
    _audioDataController.close();
    // Note: We don't dispose the AEC here as it might be shared with other services
  }
}
