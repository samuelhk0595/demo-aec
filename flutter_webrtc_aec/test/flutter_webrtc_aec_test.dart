// import 'package:flutter_test/flutter_test.dart';
// import 'package:flutter_webrtc_aec/flutter_webrtc_aec.dart';
// import 'package:flutter_webrtc_aec/flutter_webrtc_aec_platform_interface.dart';
// import 'package:flutter_webrtc_aec/flutter_webrtc_aec_method_channel.dart';
// import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// class MockFlutterWebrtcAecPlatform
//     with MockPlatformInterfaceMixin
//     implements FlutterWebrtcAecPlatform {

//   @override
//   Future<String?> getPlatformVersion() => Future.value('42');
// }

// void main() {
//   final FlutterWebrtcAecPlatform initialPlatform = FlutterWebrtcAecPlatform.instance;

//   test('$MethodChannelFlutterWebrtcAec is the default instance', () {
//     expect(initialPlatform, isInstanceOf<MethodChannelFlutterWebrtcAec>());
//   });

//   test('getPlatformVersion', () async {
//     FlutterWebrtcAec flutterWebrtcAecPlugin = FlutterWebrtcAec();
//     MockFlutterWebrtcAecPlatform fakePlatform = MockFlutterWebrtcAecPlatform();
//     FlutterWebrtcAecPlatform.instance = fakePlatform;

//     expect(await flutterWebrtcAecPlugin.getPlatformVersion(), '42');
//   });
// }
