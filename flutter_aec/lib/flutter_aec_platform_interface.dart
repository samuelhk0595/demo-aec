import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_aec_method_channel.dart';

abstract class FlutterAecPlatform extends PlatformInterface {
  /// Constructs a FlutterAecPlatform.
  FlutterAecPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterAecPlatform _instance = MethodChannelFlutterAec();

  /// The default instance of [FlutterAecPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterAec].
  static FlutterAecPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterAecPlatform] when
  /// they register themselves.
  static set instance(FlutterAecPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
