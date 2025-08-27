import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc_aec/flutter_webrtc_aec.dart';

class AudioPlaybackService {
  final List<int> _audioBuffer = [];
  FlutterWebrtcAec? _aecPlugin;
  Timer? _flushTimer;
  Timer? _frameTimer;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  // Buffering configuration - optimized for AEC
  static const int _minBufferSize = 3200; // Reduced to ~0.2 seconds at 16kHz (160 samples * 20 frames)
  static const int _targetBufferSize = 4800; // ~0.3 seconds target
  static const int _frameSize = 320; // 10ms at 16kHz mono (160 samples * 2 bytes)
  static const Duration _frameInterval = Duration(milliseconds: 10); // Process frames every 10ms
  static const Duration _flushTimeout = Duration(milliseconds: 200); // Reduced timeout

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
        // Start with capture disabled - only enable when user starts recording
        await _aecPlugin!.setCaptureEnabled(false);
        onLog?.call('WebRTC AEC engine initialized and started (capture disabled)');
        
        // Wait a bit for the engine to stabilize before processing audio
        await Future.delayed(Duration(milliseconds: 100));
      } else {
        throw Exception('Failed to start WebRTC AEC');
      }
    } catch (e) {
      onError?.call('Error initializing WebRTC AEC: $e');
      rethrow; // Re-throw so the caller knows initialization failed
    }
  }

  void _flushRemainingBuffer() {
    if (_aecPlugin == null || _audioBuffer.isEmpty) return;

    try {
      // Process remaining partial frame if any
      if (_audioBuffer.isNotEmpty) {
        // Pad to complete frame if necessary
        while (_audioBuffer.length < _frameSize) {
          _audioBuffer.add(0); // Pad with silence
        }
        
        final dataToPlay = Uint8List.fromList(_audioBuffer.take(_frameSize).toList());
        _audioBuffer.removeRange(0, _frameSize);
        _aecPlugin!.queueAudioBytes(dataToPlay);
        onLog?.call('Flushed remaining ${dataToPlay.length} bytes as padded frame');
      }
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

  /// Enable or disable microphone capture processing
  Future<void> setCaptureEnabled(bool enabled) async {
    try {
      await _aecPlugin?.setCaptureEnabled(enabled);
      onLog?.call('Capture ${enabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      onError?.call('Error setting capture enabled: $e');
      rethrow;
    }
  }

  void playAudioData(Uint8List audioData) {
    if (_aecPlugin == null) return;

    try {
      _audioBuffer.addAll(audioData);
      onLog?.call(
          '⬇️ Buffering audio data: ${audioData.length} bytes (total: ${_audioBuffer.length})');

      // Reset the flush timer for timeout-based cleanup
      _flushTimer?.cancel();
      _flushTimer = Timer(_flushTimeout, () {
        if (_audioBuffer.isNotEmpty) {
          onLog?.call('Auto-flushing buffer due to timeout (${_audioBuffer.length} bytes)');
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
      
      // Start the frame-based processing timer
      _startFrameProcessing();
    }

    // Process frames if we have enough data
    _processAvailableFrames();
  }

  void _startFrameProcessing() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(_frameInterval, (_) {
      _processAvailableFrames();
    });
  }

  void _processAvailableFrames() {
    if (_aecPlugin == null || !_isPlaying) return;

    // Process available complete frames
    while (_audioBuffer.length >= _frameSize) {
      final frameData = Uint8List.fromList(_audioBuffer.take(_frameSize).toList());
      _audioBuffer.removeRange(0, _frameSize);

      try {
        // Queue exact frame to the WebRTC AEC plugin
        _aecPlugin!.queueAudioBytes(frameData);
        onLog?.call('Queued ${frameData.length} bytes frame to AEC, buffer remaining: ${_audioBuffer.length}');
      } catch (e) {
        onError?.call('Error queuing frame to AEC: $e');
        break;
      }
    }

    // Stop processing if buffer is too low
    if (_isPlaying && _audioBuffer.length < _frameSize) {
      _stopFrameProcessing();
    }
  }

  void _stopFrameProcessing() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (_isPlaying) {
      _isPlaying = false;
      _playbackStateController.add(false);
      onStop?.call();
      onLog?.call('Frame processing stopped - insufficient buffer');
    }
  }

  Future<void> stopPlayback() async {
    try {
      _flushTimer?.cancel();
      _frameTimer?.cancel();
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
    _stopFrameProcessing();
  }

  void dispose() {
    stopPlayback();
    _flushTimer?.cancel();
    _frameTimer?.cancel();
    _aecPlugin = null;
    _playbackStateController.close();
  }
}
