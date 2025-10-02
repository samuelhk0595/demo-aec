# flutter_aec

Real-time Acoustic Echo Cancellation (AEC) and audio enhancement utilities for Flutter.

## ✨ Features

- WebRTC Acoustic Echo Canceller Mobile (AECM) integration
- Optional WebRTC Noise Suppression (NS)
- **Voice Activity Detection (VAD)** powered by WebRTC with configurable sensitivity and hangover
- **Automatic Gain Control (AGC)** for dynamic microphone level adjustment
- Native Android capture/playback pipeline for low-latency VoIP and walkie-talkie scenarios

> **Note:** VAD and AGC are currently implemented for Android. iOS support is planned.

## 🚀 Getting Started

Add the plugin to your `pubspec.yaml`, then initialise it with the desired configuration:

```dart
final aec = FlutterAec.instance;

final config = AecConfig(
	sampleRate: 16000,
	frameMs: 20,
	echoMode: 3,
	cngMode: false,
	enableNs: true,
	vadConfig: const VadConfig(
		enabled: true,
		mode: 2,
		frameMs: 30,
		hangoverMs: 300,
		hangoverEnabled: true,
	),
	agcConfig: const AgcConfig(
		enabled: true,
		mode: 2,            // Adaptive digital
		targetLevelDbfs: 3,
		compressionGainDb: 9,
		enableLimiter: true,
	),
);

final success = await aec.initialize(config);
if (!success) {
	throw Exception('Failed to initialise AEC');
}

await aec.startNativeCapture();
await aec.startNativePlayback();
```

## 🎧 Processing Audio

Listen for near-end (microphone) audio frames that have already been echo-cancelled and noise-suppressed:

```dart
final sub = aec.processedNearStream.listen((frame) {
	// frame is a Uint8List with PCM16 mono data
	sendToRemotePeer(frame);
});

// ... later
await sub.cancel();
```

Provide far-end reference frames to keep the echo canceller in sync:

```dart
await aec.bufferFarend(remotePcmFrame);
```

If you render audio yourself instead of using `startNativePlayback`, inform the engine about your estimated output latency:

```dart
await aec.setExternalPlaybackDelay(70); // milliseconds
```

## 🗣️ Working with VAD

You can react to voice activity changes via the broadcast stream or an optional callback:

```dart
final vadSubscription = aec.voiceActivityStream.listen((event) {
	debugPrint('Voice activity: ${event.isActive} at ${event.timestamp}');
});

aec.setVoiceActivityCallback((event) {
	// Trigger push-to-talk, gating, or UI updates here
});
```

VAD parameters can be updated at runtime:

```dart
await aec.configureVad(
	const VadConfig(
		enabled: true,
		mode: 3, // more aggressive
		frameMs: 20,
		hangoverMs: 500,
	),
);

// Quickly toggle VAD
await aec.setVadEnabled(false);
```

Query the latest state reported by the native layer:

```dart
final current = await aec.getCurrentVadState();
if (current != null) {
  debugPrint('VAD active: ${current.isActive}');
}
```

## 🎚️ Working with AGC

AGC automatically adjusts microphone gain to maintain consistent audio levels:

```dart
// Update AGC settings at runtime
await aec.configureAgc(
  const AgcConfig(
    enabled: true,
    mode: 2,              // 0=unchanged, 1=analog, 2=digital, 3=fixed
    targetLevelDbfs: 3,   // Target output level (0-31 dBFS)
    compressionGainDb: 9, // Max gain applied (0-90 dB)
    enableLimiter: true,  // Prevent clipping
  ),
);

// Quick toggle
await aec.setAgcEnabled(false);

// Query current AGC config
final agcState = await aec.getCurrentAgcState();
if (agcState != null) {
  debugPrint('AGC enabled: ${agcState.enabled}, mode: ${agcState.mode}');
}
```

Remember to clean up resources when finished:```dart
await aec.stopNativeCapture();
await aec.stopNativePlayback();
await aec.dispose();
```

## 📋 Notes

- Ensure `RECORD_AUDIO` permission is granted before calling `startNativeCapture()`.
- The provided frame data is 16-bit PCM mono; keep buffer sizes aligned with `AecConfig.frameMs`.
- When using a custom playback path, call `setExternalPlaybackDelay()` to help the echo canceller track latency.

## 📚 Additional Resources

- [Flutter plugin development guide](https://docs.flutter.dev)
- [WebRTC Audio Processing Module documentation](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/)

