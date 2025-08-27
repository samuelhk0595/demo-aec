import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:typed_data';

import 'flutter_webrtc_aec_method_channel.dart';

abstract class FlutterWebrtcAecPlatform extends PlatformInterface {
  /// Constructs a FlutterWebrtcAecPlatform.
  FlutterWebrtcAecPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterWebrtcAecPlatform _instance = MethodChannelFlutterWebrtcAec();

  /// The default instance of [FlutterWebrtcAecPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterWebrtcAec].
  static FlutterWebrtcAecPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterWebrtcAecPlatform] when
  /// they register themselves.
  static set instance(FlutterWebrtcAecPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> start() {
    throw UnimplementedError('start() has not been implemented.');
  }

  Future<bool> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  Future<bool> setAecEnabled(bool enabled) {
    throw UnimplementedError('setAecEnabled() has not been implemented.');
  }

  Future<bool> playAudio(List<int> audioData) {
    throw UnimplementedError('playAudio() has not been implemented.');
  }

  Future<bool> queueAudioBytes(Uint8List bytes) {
    throw UnimplementedError('queueAudioBytes() has not been implemented.');
  }

  void setCaptureCallback(Function(List<int>) callback) {
    throw UnimplementedError('setCaptureCallback() has not been implemented.');
  }

  Future<bool> isActive() {
    throw UnimplementedError('isActive() has not been implemented.');
  }

  Future<bool> playMp3Loop(String filePath) {
    throw UnimplementedError('playMp3Loop() has not been implemented.');
  }

  Future<bool> stopMp3Loop() {
    throw UnimplementedError('stopMp3Loop() has not been implemented.');
  }

  Future<bool> isUserSpeaking() {
    throw UnimplementedError('isUserSpeaking() has not been implemented.');
  }

  void setSpeechDetectionCallback(Function(bool) callback) {
    throw UnimplementedError('setSpeechDetectionCallback() has not been implemented.');
  }
}
