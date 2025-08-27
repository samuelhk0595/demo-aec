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
      onLog: _log,
      onError: _logError,
    );

    _webSocketService = WebSocketService(
      onConnected: _onWebSocketConnected,
      onDisconnected: _onWebSocketDisconnected,
      onError: _onWebSocketError,
      onAudioData: _onWebSocketAudioData,
    );

    // Connect microphone to WebSocket
    _microphoneService.audioDataStream.listen((audioData) {
      if (_connectionStatus == ConnectionStatus.connected) {
        _webSocketService.sendAudioData(audioData);
      }
    });
  }

  Future<void> initialize() async {
    try {
      await _audioPlaybackService.initAudioEngine();
      _log('Services initialized');
    } catch (e) {
      _logError('Error initializing services: $e');
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

    await _microphoneService.startRecording();
  }

  Future<void> stopRecording() async {
    await _stopRecording();
  }

  Future<void> _stopRecording() async {
    await _microphoneService.stopRecording();
    await _audioPlaybackService.stopPlayback();
  }

  void toggleMute() {
    _microphoneService.toggleMute();
    _log('Microphone ${_microphoneService.isMuted ? 'muted' : 'unmuted'}');
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
