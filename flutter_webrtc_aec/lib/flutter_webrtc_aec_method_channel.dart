import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_webrtc_aec_platform_interface.dart';

/// An implementation of [FlutterWebrtcAecPlatform] that uses method channels.
class MethodChannelFlutterWebrtcAec extends FlutterWebrtcAecPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_webrtc_aec');

  Function(List<int>)? _captureCallback;
  Function(bool)? _speechDetectionCallback;

  MethodChannelFlutterWebrtcAec() {
    methodChannel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCaptureFrame':
        final audioData = List<int>.from(call.arguments['audioData']);
        _captureCallback?.call(audioData);
        break;
      case 'onSpeechDetection':
        final isSpeaking = call.arguments['isSpeaking'] as bool;
        _speechDetectionCallback?.call(isSpeaking);
        break;
    }
  }

  @override
  Future<bool> start() async {
    final result = await methodChannel.invokeMethod<bool>('start');
    return result ?? false;
  }

  @override
  Future<bool> stop() async {
    final result = await methodChannel.invokeMethod<bool>('stop');
    return result ?? false;
  }

  @override
  Future<bool> setAecEnabled(bool enabled) async {
    final result = await methodChannel.invokeMethod<bool>('setAecEnabled', {'enabled': enabled});
    return result ?? false;
  }

  @override
  Future<bool> setCaptureEnabled(bool enabled) async {
    final result = await methodChannel.invokeMethod<bool>('setCaptureEnabled', {'enabled': enabled});
    return result ?? false;
  }

  @override
  Future<bool> playAudio(List<int> audioData) async {
    final result = await methodChannel.invokeMethod<bool>('playAudio', {'audioData': audioData});
    return result ?? false;
  }

  @override
  Future<bool> queueAudioBytes(Uint8List bytes) async {
    final result = await methodChannel.invokeMethod<bool>('queueAudioBytes', {'bytes': bytes});
    return result ?? false;
  }

  @override
  void setCaptureCallback(Function(List<int>) callback) {
    _captureCallback = callback;
  }

  @override
  Future<bool> isActive() async {
    final result = await methodChannel.invokeMethod<bool>('isActive');
    return result ?? false;
  }

  @override
  Future<bool> playMp3Loop(String filePath) async {
    final result = await methodChannel.invokeMethod<bool>('playMp3Loop', {'filePath': filePath});
    return result ?? false;
  }

  @override
  Future<bool> stopMp3Loop() async {
    final result = await methodChannel.invokeMethod<bool>('stopMp3Loop');
    return result ?? false;
  }

  @override
  Future<bool> isUserSpeaking() async {
    final result = await methodChannel.invokeMethod<bool>('isUserSpeaking');
    return result ?? false;
  }

  @override
  void setSpeechDetectionCallback(Function(bool) callback) {
    _speechDetectionCallback = callback;
  }
}
