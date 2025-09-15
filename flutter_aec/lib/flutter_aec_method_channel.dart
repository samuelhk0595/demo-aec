import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_aec_platform_interface.dart';

/// An implementation of [FlutterAecPlatform] that uses method channels.
class MethodChannelFlutterAec extends FlutterAecPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_aec');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
