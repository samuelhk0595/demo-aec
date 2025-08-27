import 'flutter_webrtc_aec_platform_interface.dart';
import 'dart:typed_data';

/// Flutter plugin for full-duplex audio processing with WebRTC AEC
class FlutterWebrtcAec {
  /// Start full-duplex audio processing with AEC
  Future<bool> start() {
    return FlutterWebrtcAecPlatform.instance.start();
  }

  /// Stop audio processing
  Future<bool> stop() {
    return FlutterWebrtcAecPlatform.instance.stop();
  }

  /// Enable or disable Acoustic Echo Cancellation
  Future<bool> setAecEnabled(bool enabled) {
    return FlutterWebrtcAecPlatform.instance.setAecEnabled(enabled);
  }

  /// Play audio data (this will be used as reference for AEC)
  Future<bool> playAudio(List<int> audioData) {
    return FlutterWebrtcAecPlatform.instance.playAudio(audioData);
  }

  /// Queue raw PCM16 little-endian bytes (mono 16kHz recommended) for real-time playback + AEC.
  Future<bool> queueAudioBytes(Uint8List bytes) {
    return FlutterWebrtcAecPlatform.instance.queueAudioBytes(bytes);
  }

  /// Set callback for processed capture frames
  void setCaptureCallback(Function(List<int>) callback) {
    FlutterWebrtcAecPlatform.instance.setCaptureCallback(callback);
  }

  /// Check if audio processing is currently active
  Future<bool> isActive() {
    return FlutterWebrtcAecPlatform.instance.isActive();
  }

  /// Play MP3 file in loop
  Future<bool> playMp3Loop(String filePath) {
    return FlutterWebrtcAecPlatform.instance.playMp3Loop(filePath);
  }

  /// Stop MP3 loop
  Future<bool> stopMp3Loop() {
    return FlutterWebrtcAecPlatform.instance.stopMp3Loop();
  }

  /// Check if user is speaking (for intelligent interruption)
  Future<bool> isUserSpeaking() {
    return FlutterWebrtcAecPlatform.instance.isUserSpeaking();
  }

  /// Set speech detection callback for intelligent interruption
  void setSpeechDetectionCallback(Function(bool) callback) {
    FlutterWebrtcAecPlatform.instance.setSpeechDetectionCallback(callback);
  }
}
