import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:realtime_audio/realtime_audio.dart';
import 'package:flutter_aec/flutter_aec.dart';

class AudioPlaybackService {
  final List<int> _audioBuffer = [];
  RealtimeAudio? _audioEngine;
  List<StreamSubscription<dynamic>>? _audioEngineSubscriptions;
  Timer? _flushTimer;
  
  final _aec = FlutterAec.instance;

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

  Future<bool> initializeAecPlayback() async {
    try {
      if (!_aec.isInitialized) {
        onError?.call('AEC not initialized. Initialize it in MicrophoneService first.');
        return false;
      }

      // Start AEC native playback
      final success = await _aec.startNativePlayback();
      if (success) {
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
      // IMPORTANT: Feed incoming audio to AEC as far-end reference
      // This must be done BEFORE or simultaneously with playback for optimal echo cancellation
      _feedToAecFarEnd(audioData);

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

  void _feedToAecFarEnd(Uint8List audioData) {
    if (!_aec.isInitialized || !_aec.isPlaybackStarted) {
      return;
    }

    try {
      // The AEC expects frames of exactly the configured size
      // Our config uses 20ms frames at 16kHz = 320 samples = 640 bytes
      const expectedFrameSize = 640; // 20ms * 16000 Hz * 2 bytes per sample
      
      // Split the audio data into AEC frame-sized chunks
      for (int i = 0; i < audioData.length; i += expectedFrameSize) {
        final endIndex = (i + expectedFrameSize > audioData.length) 
            ? audioData.length 
            : i + expectedFrameSize;
        
        if (endIndex - i == expectedFrameSize) {
          final frameData = audioData.sublist(i, endIndex);
          _aec.bufferFarend(frameData);
          onLog?.call('Fed ${frameData.length} bytes to AEC far-end');
        } else {
          // Handle partial frame at the end - pad with zeros or skip
          onLog?.call('Skipping partial frame: ${endIndex - i} bytes (expected: $expectedFrameSize)');
        }
      }
    } catch (e) {
      onError?.call('Error feeding audio to AEC far-end: $e');
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
      
      // Stop AEC native playback
      if (_aec.isInitialized && _aec.isPlaybackStarted) {
        await _aec.stopNativePlayback();
        onLog?.call('AEC native playback stopped');
      }
      
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
