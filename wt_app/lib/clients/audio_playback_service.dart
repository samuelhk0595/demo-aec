import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:realtime_audio/realtime_audio.dart';

class AudioPlaybackService {
  final List<int> _audioBuffer = [];
  RealtimeAudio? _audioEngine;
  List<StreamSubscription<dynamic>>? _audioEngineSubscriptions;
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

  AudioPlaybackService({
    this.onPlay,
    this.onStop,
    this.onLog,
    this.onError,
  });

  Future<void> initAudioEngine() async {
    try {
      _audioEngine = RealtimeAudio(
        recorderEnabled: false,
        backgroundEnabled: false,
        playerSampleRate: 16000,
      );
      await _audioEngine?.isInitialized;

      _audioEngineSubscriptions = [
        _audioEngine!.stateStream.listen((state) {
          if (_isPlaying && !state.isPlaying) {
            // Audio engine stopped, check if we need to flush remaining buffer
            if (_audioBuffer.isNotEmpty) {
              _flushRemainingBuffer();
            } else {
              _isPlaying = false;
              onStop?.call();
              _playbackStateController.add(false);
              onLog?.call('Audio playback finished');
            }
          }
        }),
      ];

      onLog?.call('Audio engine initialized');
    } catch (e) {
      onError?.call('Error initializing audio engine: $e');
    }
  }

  void _flushRemainingBuffer() {
    if (_audioEngine == null || _audioBuffer.isEmpty) return;

    try {
      final dataToPlay = Uint8List.fromList(_audioBuffer);
      _audioBuffer.clear();
      _audioEngine?.queueChunk(dataToPlay);
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
    if (_audioEngine == null) return;

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

  void _playBufferedAudioIfNeeded() async {
    if (_audioEngine == null) return;

    // If not playing and we have enough buffer, start playback
    if (!_isPlaying && _audioBuffer.length >= _minBufferSize) {
      _isPlaying = true;
      _playbackStateController.add(true);
      onPlay?.call();
      onLog?.call(
          'Starting audio playback with ${_audioBuffer.length} bytes buffered');
    }

    // If playing, continue feeding the audio engine with chunks
    if (_isPlaying && _audioBuffer.length >= _chunkSize) {
      final dataToPlay =
          Uint8List.fromList(_audioBuffer.take(_chunkSize).toList());
      _audioBuffer.removeRange(0, _chunkSize);

      try {
        _audioEngine?.queueChunk(dataToPlay);
        if (!_audioEngine!.state.isPlaying) {
          _audioEngine?.start();
        }
        onLog?.call(
            'Queued ${dataToPlay.length} bytes, buffer remaining: ${_audioBuffer.length}');
      } catch (e) {
        onError?.call('Error buffering audio: $e');
      }
    }
  }

  Future<void> stopPlayback() async {
    try {
      _flushTimer?.cancel();
      await _audioEngine?.stop();
      await _audioEngine?.clearQueue();
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
    _audioEngine?.clearQueue();
  }

  void dispose() {
    stopPlayback();
    _flushTimer?.cancel();
    _audioEngineSubscriptions?.forEach((sub) => sub.cancel());
    _audioEngineSubscriptions = null;
    _audioEngine?.dispose();
    _audioEngine = null;
    _playbackStateController.close();
  }
}
