import 'dart:async';
import 'dart:typed_data';

import '../clients/microphone_service.dart';
import '../clients/audio_playback_service.dart';
import 'websocket_service.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class WalkieTalkieService {
  late final MicrophoneService _microphoneService;
  late final AudioPlaybackService _audioPlaybackService;
  late final WebSocketService _webSocketService;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  bool _useAecProcessedAudio = true; // Prefer AEC-processed audio when available
  String? _nickname;

  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<ConnectionStatus> get connectionStatusStream => _connectionStatusController.stream;
  Stream<String> get logStream => _logController.stream;

  ConnectionStatus get connectionStatus => _connectionStatus;
  String? get nickname => _nickname;
  bool get isMuted => _microphoneService.isMuted;

  WalkieTalkieService() {
    _initializeServices();
  }

  void _initializeServices() {
    _microphoneService = MicrophoneService(
      onLog: _log,
      onError: _logError,
    );

    _audioPlaybackService = AudioPlaybackService(
      onPlay: () => _log('🔊 Starting audio playback'),
      onStop: () => _log('🔇 Audio playback stopped'),
      onLog: _log,
      onError: (error) {
        _logError(error);
        // If AEC consistently fails, fall back to raw microphone
        if (error.contains('APM processing failed') || error.contains('render stream sync')) {
          _log('AEC synchronization issues detected, consider falling back to raw microphone');
        }
      },
      onCaptureFrame: (audioData) {
        // Send the processed audio data to WebSocket
        if (_connectionStatus == ConnectionStatus.connected && _useAecProcessedAudio) {
          // audioData are 16-bit PCM samples (-32768..32767). We must send as little-endian bytes.
          final sampleCount = audioData.length;
          final bytes = Uint8List(sampleCount * 2);
          int bi = 0;
          for (var s in audioData) {
            // Ensure signed 16-bit range then encode LE
            final v = s & 0xFFFF; // mask to 16 bits
            bytes[bi++] = v & 0xFF; // low byte
            bytes[bi++] = (v >> 8) & 0xFF; // high byte
          }
          _webSocketService.sendAudioData(bytes);
        }
      },
    );

    _webSocketService = WebSocketService(
      onConnected: _onWebSocketConnected,
      onDisconnected: _onWebSocketDisconnected,
      onError: _onWebSocketError,
      onAudioData: _onWebSocketAudioData,
    );

    // Connect microphone to WebSocket (as fallback when AEC is not available)
    _microphoneService.audioDataStream.listen((audioData) {
      if (_connectionStatus == ConnectionStatus.connected && !_useAecProcessedAudio) {
        _webSocketService.sendAudioData(audioData);
      }
    });
  }

  Future<void> initialize() async {
    try {
      await _audioPlaybackService.initAudioEngine();
      
      // Check if AEC is properly initialized
      // If AEC initialization fails, fall back to raw microphone
      _useAecProcessedAudio = true; // We'll detect failures and adjust this
      
      _log('Services initialized with AEC processing enabled');
    } catch (e) {
      _logError('Error initializing services: $e');
      _useAecProcessedAudio = false; // Fall back to raw microphone
      _log('Falling back to raw microphone audio (no AEC)');
    }
  }

  Future<bool> requestPermissions() async {
    return await _microphoneService.requestPermissions();
  }

  Future<void> connect(String serverUrl, String nickname) async {
    if (_connectionStatus == ConnectionStatus.connecting || 
        _connectionStatus == ConnectionStatus.connected) {
      return;
    }

    _nickname = nickname;
    _updateConnectionStatus(ConnectionStatus.connecting);

    try {
      await _webSocketService.connect(serverUrl, nickname);
    } catch (e) {
      _logError('Connection failed: $e');
      _updateConnectionStatus(ConnectionStatus.error);
    }
  }

  void disconnect() {
    _stopRecording();
    _webSocketService.disconnect();
    _updateConnectionStatus(ConnectionStatus.disconnected);
    _log('Disconnected from server');
  }

  Future<void> startRecording() async {
    if (_connectionStatus != ConnectionStatus.connected) {
      _logError('Cannot start recording: not connected to server');
      return;
    }

    if (_useAecProcessedAudio) {
      // Enable AEC capture processing
      try {
        await _audioPlaybackService.setCaptureEnabled(true);
        _log('🎤 Recording started (AEC-processed audio)');
      } catch (e) {
        _logError('Failed to enable AEC capture: $e');
        // Fall back to raw microphone
        _useAecProcessedAudio = false;
        await _microphoneService.startRecording();
        _log('🎤 Recording started (fallback to raw microphone)');
      }
    } else {
      // Use raw microphone as fallback
      await _microphoneService.startRecording();
      _log('🎤 Recording started (raw microphone audio)');
    }
  }

  Future<void> stopRecording() async {
    await _stopRecording();
  }

  Future<void> _stopRecording() async {
    if (_useAecProcessedAudio) {
      // For AEC, disable capture but keep playback running
      try {
        await _audioPlaybackService.setCaptureEnabled(false);
        _log('🎤 Recording stopped (AEC playback continues for incoming audio)');
      } catch (e) {
        _logError('Error disabling AEC capture: $e');
      }
    } else {
      // Stop raw microphone
      await _microphoneService.stopRecording();
      _log('🎤 Recording stopped (raw microphone)');
    }
    
    // Note: We deliberately DON'T stop audioPlaybackService.stopPlayback()
    // because we want to keep receiving and playing audio from other clients
  }

  void toggleMute() {
    _microphoneService.toggleMute();
    _log('Microphone ${_microphoneService.isMuted ? 'muted' : 'unmuted'}');
  }

  /// Switch between AEC-processed audio and raw microphone audio
  void toggleAecMode() {
    _useAecProcessedAudio = !_useAecProcessedAudio;
    _log('Audio mode: ${_useAecProcessedAudio ? 'AEC-processed' : 'Raw microphone'}');
    
    // If switching to raw microphone while recording, start the microphone service
    if (!_useAecProcessedAudio && _connectionStatus == ConnectionStatus.connected) {
      _microphoneService.startRecording();
    }
    // If switching to AEC while using raw microphone, stop the microphone service
    else if (_useAecProcessedAudio) {
      _microphoneService.stopRecording();
    }
  }

  void _onWebSocketConnected() {
    _updateConnectionStatus(ConnectionStatus.connected);
    _log('Connected to server as $_nickname');
  }

  void _onWebSocketDisconnected() {
    _stopRecording();
    _updateConnectionStatus(ConnectionStatus.disconnected);
    _log('Disconnected from server');
  }

  void _onWebSocketError(dynamic error) {
    _stopRecording();
    _updateConnectionStatus(ConnectionStatus.error);
    _logError('WebSocket error: $error');
  }

  void _onWebSocketAudioData(Uint8List audioData) {
    _audioPlaybackService.playAudioData(audioData);
  }

  void _updateConnectionStatus(ConnectionStatus status) {
    _connectionStatus = status;
    _connectionStatusController.add(status);
  }

  void _log(String message) {
    _logController.add('[${DateTime.now().toString().substring(11, 19)}] $message');
  }

  void _logError(String error) {
    _logController.add('[${DateTime.now().toString().substring(11, 19)}] ERROR: $error');
  }

  void dispose() {
    _stopRecording();
    _microphoneService.dispose();
    _audioPlaybackService.dispose();
    _webSocketService.dispose();
    _connectionStatusController.close();
    _logController.close();
  }
}
