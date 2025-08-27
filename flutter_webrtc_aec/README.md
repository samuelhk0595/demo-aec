# Flutter WebRTC AEC Plugin

A Flutter plugin that provides full-duplex audio processing with WebRTC Acoustic Echo Cancellation (AEC) for Android. This plugin enables real-time voice communication with intelligent echo cancellation and speech detection capabilities.

## Features

- **Full-Duplex Audio Processing**: Simultaneous audio capture and playback with shared session
- **WebRTC AEC**: Acoustic Echo Cancellation using WebRTC's proven algorithms
- **Intelligent Interruption**: Automatic audio pause/resume based on speech detection
- **Real-time Processing**: 10ms frame processing for low latency
- **Thread-Safe Architecture**: Optimized for mobile performance
- **Easy Integration**: Simple API for Flutter applications

## Architecture

This plugin encapsulates the full-duplex audio solution with the following components:

- **ApmEngine**: WebRTC Audio Processing Module wrapper
- **AudioSessionManager**: Manages AudioTrack and AudioRecord with shared session
- **AudioThreads**: Handles render and capture thread logic
- **Speech Detection**: Real-time voice activity detection

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  flutter_webrtc_aec:
    path: /path/to/flutter_webrtc_aec  # For local development
```

### Android Permissions

Add the following permissions to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

## Usage

### Basic Example

```dart
import 'package:flutter_webrtc_aec/flutter_webrtc_aec.dart';

class MyAudioApp extends StatefulWidget {
  @override
  _MyAudioAppState createState() => _MyAudioAppState();
}

class _MyAudioAppState extends State<MyAudioApp> {
  final FlutterWebrtcAec _aecPlugin = FlutterWebrtcAec();

  @override
  void initState() {
    super.initState();
    _setupAudioCallbacks();
  }

  void _setupAudioCallbacks() {
    // Receive processed audio frames (ready for network transmission)
    _aecPlugin.setCaptureCallback((audioData) {
      // Send clean audio to your network stack
      print('Received clean audio: ${audioData.length} samples');
    });

    // Monitor speech detection for intelligent interruption
    _aecPlugin.setSpeechDetectionCallback((isSpeaking) {
      print('User is ${isSpeaking ? "speaking" : "silent"}');
    });
  }

  Future<void> _startAudioProcessing() async {
    // Start the WebRTC AEC processing
    final success = await _aecPlugin.start();
    if (success) {
      print('Audio processing started');
      
      // Enable AEC
      await _aecPlugin.setAecEnabled(true);
    }
  }

  Future<void> _stopAudioProcessing() async {
    await _aecPlugin.stop();
    print('Audio processing stopped');
  }
}
```

### AI Speaking Demo (as per requirements)

```dart
Future<void> _startAISpeaking() async {
  // Start audio processing
  await _aecPlugin.start();
  await _aecPlugin.setAecEnabled(true);
  
  // Start playing MP3 in loop (AI speaking)
  await _aecPlugin.playMp3Loop('/path/to/your/audio.mp3');
  
  // The plugin will automatically:
  // 1. Pause MP3 when user starts speaking
  // 2. Resume MP3 after 2 seconds of silence
  // 3. Provide clean captured audio via callback
}
```

## API Reference

### Methods

- `start()` → `Future<bool>`: Start audio processing
- `stop()` → `Future<bool>`: Stop audio processing
- `setAecEnabled(bool enabled)` → `Future<bool>`: Enable/disable AEC
- `isActive()` → `Future<bool>`: Check if processing is active
- `playMp3Loop(String filePath)` → `Future<bool>`: Play MP3 file in loop
- `stopMp3Loop()` → `Future<bool>`: Stop MP3 loop
- `isUserSpeaking()` → `Future<bool>`: Check if user is speaking

### Callbacks

- `setCaptureCallback(Function(List<int>) callback)`: Processed audio frames
- `setSpeechDetectionCallback(Function(bool) callback)`: Speech detection events

## Demo Application

The included demo project demonstrates all plugin features:

1. **Start talking** button: Begins AI audio loop with AEC
2. **Intelligent interruption**: Audio pauses when you speak
3. **Automatic resume**: Audio continues after silence period
4. **Stop** button: Ends the demo

### Running the Demo

```bash
cd webrtc_aec_demo
flutter run
```

## Technical Details

### Audio Format
- Sample Rate: 16 kHz
- Bit Depth: 16-bit PCM
- Frame Size: 10ms (160 samples at 16 kHz)
- Channels: Mono for AEC processing, stereo playback supported

### Speech Detection
- Volume-based detection with configurable threshold
- 2-second silence period before resuming audio
- Real-time callbacks for state changes

### Performance
- Optimized for mobile devices
- Low-latency processing (10ms frames)
- Minimal CPU usage with native implementation

## Requirements

- Flutter 3.8.1+
- Android API level 21+
- WebRTC APM library (included via dependency)

## Dependencies

This plugin uses:
- `com.github.brucekayle:webrtc-apm:v0.0.1` for WebRTC Audio Processing Module

## License

This project is based on the WebRTC implementation and follows the same licensing terms.

## Support

For issues and feature requests, please check the existing issues or create a new one in the repository.
