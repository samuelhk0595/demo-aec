import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc_aec/flutter_webrtc_aec.dart';

class AudioPlaybackService {
  final List<int> _audioBuffer = [];
  FlutterWebrtcAec? _aecPlugin;
  Timer? _flushTimer;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  // Buffering configuration
  static const int _minBufferSize =
      8000; // Minimum bytes before starting playback (~0.5 seconds at 16kHz)
  static const int _chunkSize = 15000; // Size of chunks to send to audio engine
  static const Duration _flushTimeout =
      Duration(milliseconds: 500); // Auto-flush timeout

  final StreamController<bool> _playbackStateController =
      StreamController<bool>.broadcast();

  Stream<bool> get playbackStateStream => _playbackStateController.stream;

  final VoidCallback? onPlay;
  final VoidCallback? onStop;
  final void Function(String message)? onLog;
  final void Function(String error)? onError;
  final void Function(List<int> audioData)? onCaptureFrame;

  AudioPlaybackService({
    this.onPlay,
    this.onStop,
    this.onLog,
    this.onError,
    this.onCaptureFrame,
  });

  Future<void> initAudioEngine() async {
    try {
      _aecPlugin = FlutterWebrtcAec();
      
      // Set up capture callback for processed audio
      _aecPlugin!.setCaptureCallback((audioData) {
        onCaptureFrame?.call(audioData);
        onLog?.call('Received processed audio: ${audioData.length} samples');
      });

      // Set up speech detection callback
      _aecPlugin!.setSpeechDetectionCallback((isSpeaking) {
        onLog?.call('User is ${isSpeaking ? "speaking" : "silent"}');
      });

      // Start the AEC processing
      final success = await _aecPlugin!.start();
      if (success) {
        await _aecPlugin!.setAecEnabled(true);
        onLog?.call('WebRTC AEC engine initialized and started');
      } else {
        throw Exception('Failed to start WebRTC AEC');
      }
    } catch (e) {
      onError?.call('Error initializing WebRTC AEC: $e');
    }
  }

  void _flushRemainingBuffer() {
    if (_aecPlugin == null || _audioBuffer.isEmpty) return;

    try {
      final dataToPlay = Uint8List.fromList(_audioBuffer);
      _audioBuffer.clear();
      _aecPlugin!.queueAudioBytes(dataToPlay);
      onLog?.call('Flushed remaining ${dataToPlay.length} bytes from buffer');
    } catch (e) {
      onError?.call('Error flushing buffer: $e');
    }
  }

  // Call this method when you know no more audio data is coming for a while
  void flushBuffer() {
    if (_isPlaying && _audioBuffer.isNotEmpty) {
      _flushRemainingBuffer();
    }
  }

  void playAudioData(Uint8List audioData) {
    if (_aecPlugin == null) return;

    try {
      _audioBuffer.addAll(audioData);
      onLog?.call(
          '⬇️ Buffering audio data: ${audioData.length} bytes (total: ${_audioBuffer.length})');

      // Reset the flush timer
      _flushTimer?.cancel();
      _flushTimer = Timer(_flushTimeout, () {
        if (_isPlaying && _audioBuffer.isNotEmpty) {
          onLog?.call('Auto-flushing buffer due to timeout');
          _flushRemainingBuffer();
        }
      });

      _playBufferedAudioIfNeeded();
    } catch (e) {
      onError?.call('Error playing audio: $e');
    }
  }

  void _playBufferedAudioIfNeeded() {
    if (_aecPlugin == null) return;

    // If not playing and we have enough buffer, start playback
    if (!_isPlaying && _audioBuffer.length >= _minBufferSize) {
      _isPlaying = true;
      _playbackStateController.add(true);
      onPlay?.call();
      onLog?.call(
          'Starting audio playback with ${_audioBuffer.length} bytes buffered');
    }

    // If playing, continue feeding the AEC engine with chunks
    if (_isPlaying && _audioBuffer.length >= _chunkSize) {
      final dataToPlay =
          Uint8List.fromList(_audioBuffer.take(_chunkSize).toList());
      _audioBuffer.removeRange(0, _chunkSize);

      try {
        // Queue audio bytes to the WebRTC AEC plugin
        _aecPlugin!.queueAudioBytes(dataToPlay);
        onLog?.call(
            'Queued ${dataToPlay.length} bytes to AEC, buffer remaining: ${_audioBuffer.length}');
      } catch (e) {
        onError?.call('Error buffering audio to AEC: $e');
      }
    }
  }

  Future<void> stopPlayback() async {
    try {
      _flushTimer?.cancel();
      await _aecPlugin?.stop();
      _isPlaying = false;
      _playbackStateController.add(false);
      onStop?.call();
      onLog?.call('Audio playback stopped');
    } catch (e) {
      onError?.call('Error stopping audio: $e');
    }
  }

  void clearAudioBuffer() {
    _audioBuffer.clear();
  }

  void dispose() {
    stopPlayback();
    _flushTimer?.cancel();
    _aecPlugin = null;
    _playbackStateController.close();
  }
}
