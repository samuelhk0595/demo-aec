import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_aec/flutter_aec.dart';
import 'package:flutter_aec/flutter_aec_platform_interface.dart';
import 'package:flutter_aec/flutter_aec_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterAecPlatform
    with MockPlatformInterfaceMixin
    implements FlutterAecPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterAecPlatform initialPlatform = FlutterAecPlatform.instance;

  test('$MethodChannelFlutterAec is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterAec>());
  });

  test('getPlatformVersion', () async {
    FlutterAec flutterAecPlugin = FlutterAec();
    MockFlutterAecPlatform fakePlatform = MockFlutterAecPlatform();
    FlutterAecPlatform.instance = fakePlatform;

    expect(await flutterAecPlugin.getPlatformVersion(), '42');
  });
}
