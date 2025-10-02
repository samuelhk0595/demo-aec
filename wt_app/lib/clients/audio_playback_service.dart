import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aec/flutter_aec.dart';

class AudioPlaybackService {
  final _aec = FlutterAec.instance;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  bool _isPlayingAsset = false;
  bool get isPlayingAsset => _isPlayingAsset;

  Timer? _assetPlaybackTimer;
  int _currentAssetPosition = 0;
  Uint8List? _currentAssetData;

  // Buffer for mixing audio streams
  // final List<int> _mixBuffer = [];
  // static const int _bufferSize = 320; // 10ms frame size

  final StreamController<bool> _playbackStateController =
      StreamController<bool>.broadcast();

  final StreamController<bool> _assetPlaybackStateController =
      StreamController<bool>.broadcast();

  Stream<bool> get playbackStateStream => _playbackStateController.stream;
  Stream<bool> get assetPlaybackStateStream => _assetPlaybackStateController.stream;

  final VoidCallback? onPlay;
  final VoidCallback? onStop;
  final void Function(String message)? onLog;
  final void Function(String error)? onError;

  AudioPlaybackService({
    this.onPlay,
    this.onStop,
    this.onLog,
    this.onError,
  });

  Future<void> initAudioEngine() async {
    print('[AudioPlaybackService] initAudioEngine() called - using native AEC playback');
    // No external audio engine needed - we'll use AEC native playback
    onLog?.call('Audio engine initialized (native AEC playback)');
  }

  Future<bool> initializeAecPlayback({bool useNative = true}) async {
    try {
      if (!_aec.isInitialized) {
        onError?.call('AEC not initialized. Initialize it in MicrophoneService first.');
        return false;
      }

      // Always use native playback now
      final success = await _aec.startNativePlayback();
      if (success) {
        _isPlaying = true;
        _playbackStateController.add(true);
        onPlay?.call();
        onLog?.call('AEC native playback started');
        return true;
      } else {
        onError?.call('Failed to start AEC native playback');
        return false;
      }
    } catch (e) {
      onError?.call('Error initializing AEC playback: $e');
      return false;
    }
  }

  void playAudioData(Uint8List audioData) {
    if (!_aec.isInitialized) {
      onError?.call('AEC not initialized');
      return;
    }

    try {
      // Mix with current asset audio if playing
      Uint8List finalAudioData;
      if (_isPlayingAsset && _currentAssetData != null) {
        finalAudioData = _mixAudioStreams(audioData, _getCurrentAssetChunk(audioData.length));
        onLog?.call('⬇️ Playing mixed audio: WebSocket(${audioData.length}) + Asset mixed = ${finalAudioData.length} bytes');
      } else {
        finalAudioData = audioData;
        onLog?.call('⬇️ Playing WebSocket audio: ${audioData.length} bytes (native AEC playback)');
      }

      // Feed mixed audio to AEC as far-end reference
      _feedToAecFarEnd(finalAudioData);

    } catch (e) {
      onError?.call('Error playing audio: $e');
    }
  }

  Uint8List _mixAudioStreams(Uint8List stream1, Uint8List stream2) {
    final int maxLength = stream1.length > stream2.length ? stream1.length : stream2.length;
    final List<int> mixedData = [];

    for (int i = 0; i < maxLength; i += 2) { // Process 16-bit samples (2 bytes each)
      // Get 16-bit samples from both streams
      int sample1 = 0;
      if (i + 1 < stream1.length) {
        sample1 = (stream1[i + 1] << 8) | stream1[i]; // Little-endian 16-bit
        if (sample1 > 32767) sample1 -= 65536; // Convert to signed
      }

      int sample2 = 0;
      if (i + 1 < stream2.length) {
        sample2 = (stream2[i + 1] << 8) | stream2[i]; // Little-endian 16-bit
        if (sample2 > 32767) sample2 -= 65536; // Convert to signed
      }

      // Mix the samples (simple addition with clipping)
      int mixedSample = sample1 + sample2;
      
      // Clip to prevent overflow
      if (mixedSample > 32767) mixedSample = 32767;
      if (mixedSample < -32768) mixedSample = -32768;

      // Convert back to unsigned 16-bit and add to output
      if (mixedSample < 0) mixedSample += 65536;
      mixedData.add(mixedSample & 0xFF);        // Low byte
      mixedData.add((mixedSample >> 8) & 0xFF); // High byte
    }

    return Uint8List.fromList(mixedData);
  }

  Uint8List _getCurrentAssetChunk(int requestedLength) {
    if (_currentAssetData == null || _currentAssetPosition >= _currentAssetData!.length) {
      return Uint8List(requestedLength); // Return silence if no asset data
    }

    final int endPos = (_currentAssetPosition + requestedLength).clamp(0, _currentAssetData!.length);
    final Uint8List chunk = _currentAssetData!.sublist(_currentAssetPosition, endPos);
    
    // Advance position for next call
    _currentAssetPosition = endPos;
    
    // Pad with silence if chunk is shorter than requested
    if (chunk.length < requestedLength) {
      final paddedChunk = Uint8List(requestedLength);
      paddedChunk.setAll(0, chunk);
      return paddedChunk;
    }
    
    return chunk;
  }

  void _feedToAecFarEnd(Uint8List audioData) {
    print('[AudioPlaybackService] _feedToAecFarEnd() called with ${audioData.length} bytes');
    if (!_aec.isInitialized) {
      print('[AudioPlaybackService] AEC not initialized, skip far-end feed');
      return;
    }

    try {
      // With native AEC engine enforcing 10ms frames internally, we should send 320 bytes (10ms at 16kHz)
      const expectedFrameSize = 320; // 10ms * 16000 Hz * 2 bytes per sample
      
      // Split the audio data into AEC frame-sized chunks (10ms frames)
      for (int i = 0; i < audioData.length; i += expectedFrameSize) {
        final endIndex = (i + expectedFrameSize > audioData.length) 
            ? audioData.length 
            : i + expectedFrameSize;
        
        if (endIndex - i == expectedFrameSize) {
          final frameData = audioData.sublist(i, endIndex);
          _aec.bufferFarend(frameData);
          // Don't log every frame as it's too verbose
          // print('[AudioPlaybackService] Fed frame to AEC: ${frameData.length} bytes');
        } else {
          // Handle partial frame at the end - pad with zeros or skip
          onLog?.call('Skipping partial frame: ${endIndex - i} bytes (expected: $expectedFrameSize)');
          print('[AudioPlaybackService] Skipped partial frame: ${endIndex - i} bytes');
        }
      }
    } catch (e) {
      onError?.call('Error feeding audio to AEC far-end: $e');
    }
  }

  // Call this method when you know no more audio data is coming for a while
  void flushBuffer() {
    // No buffering needed with native playback
    onLog?.call('Flush requested (no-op with native playback)');
  }

  Future<void> stopPlayback() async {
    try {
      if (_aec.isInitialized && _isPlaying) {
        await _aec.stopNativePlayback();
        _isPlaying = false;
        _playbackStateController.add(false);
        onStop?.call();
        onLog?.call('AEC native playback stopped');
      }
    } catch (e) {
      onError?.call('Error stopping audio: $e');
    }
  }

  Future<void> playAssetAudio(String assetPath) async {
    if (_isPlayingAsset) {
      onLog?.call('Asset already playing, stopping current playback');
      await stopAssetAudio();
    }

    try {
      // Load the asset file
      final ByteData data = await rootBundle.load(assetPath);
      final Uint8List audioBytes = data.buffer.asUint8List();
      
      onLog?.call('🎵 Loading asset: $assetPath (${audioBytes.length} bytes)');

      // Skip WAV header (44 bytes) to get raw PCM data
      // Assuming 16kHz, 16-bit, mono PCM data after header
      const int wavHeaderSize = 44;
      if (audioBytes.length <= wavHeaderSize) {
        onError?.call('Audio file too small or invalid format');
        return;
      }

      _currentAssetData = audioBytes.sublist(wavHeaderSize);
      onLog?.call('🎵 Raw audio data loaded: ${_currentAssetData!.length} bytes');

      if (!_aec.isInitialized) {
        onError?.call('AEC not initialized');
        return;
      }

      // Initialize AEC playback if not already started
      if (!_isPlaying) {
        final success = await initializeAecPlayback();
        if (!success) {
          onError?.call('Failed to initialize AEC playback');
          return;
        }
      }

      _isPlayingAsset = true;
      _currentAssetPosition = 0;
      _assetPlaybackStateController.add(true);
      onLog?.call('🎵 Started asset audio mixing (will mix with incoming WebSocket audio)');

      // Set up a timer to check when asset playback is complete
      // The actual mixing happens in playAudioData() method
      _assetPlaybackTimer = Timer.periodic(
        Duration(milliseconds: 50), // Check every 50ms
        (timer) {
          if (_currentAssetPosition >= _currentAssetData!.length) {
            // Asset playback completed
            timer.cancel();
            _finishAssetPlayback();
          }
        },
      );

    } catch (e) {
      onError?.call('Error playing asset audio: $e');
      _isPlayingAsset = false;
      _assetPlaybackStateController.add(false);
    }
  }

  Future<void> stopAssetAudio() async {
    if (!_isPlayingAsset) return;

    _assetPlaybackTimer?.cancel();
    _assetPlaybackTimer = null;
    
    _isPlayingAsset = false;
    _currentAssetPosition = 0;
    _currentAssetData = null;
    _assetPlaybackStateController.add(false);
    
    onLog?.call('🎵 Stopped asset audio mixing');
  }

  void _finishAssetPlayback() {
    _isPlayingAsset = false;
    _currentAssetPosition = 0;
    _currentAssetData = null;
    _assetPlaybackTimer?.cancel();
    _assetPlaybackTimer = null;
    _assetPlaybackStateController.add(false);
    
    onLog?.call('🎵 Asset audio playback completed');
  }

  void clearAudioBuffer() {
    // No buffer to clear with native playback
    onLog?.call('Clear buffer requested (no-op with native playback)');
  }

  void dispose() {
    stopPlayback();
    stopAssetAudio();
    _playbackStateController.close();
    _assetPlaybackStateController.close();
  }
}
