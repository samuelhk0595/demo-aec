import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_aec/flutter_aec.dart';

class AudioPlaybackService {
  final _aec = FlutterAec.instance;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  final StreamController<bool> _playbackStateController =
      StreamController<bool>.broadcast();

  Stream<bool> get playbackStateStream => _playbackStateController.stream;

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
      // Feed incoming audio to AEC as far-end reference
      // This must be done BEFORE or simultaneously with playback for optimal echo cancellation
      _feedToAecFarEnd(audioData);

      onLog?.call('⬇️ Playing audio data: ${audioData.length} bytes (native AEC playback)');
    } catch (e) {
      onError?.call('Error playing audio: $e');
    }
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

  void clearAudioBuffer() {
    // No buffer to clear with native playback
    onLog?.call('Clear buffer requested (no-op with native playback)');
  }

  void dispose() {
    stopPlayback();
    _playbackStateController.close();
  }
}
