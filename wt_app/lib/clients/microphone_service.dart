import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

class MicrophoneService {
  bool _isMuted = false;
  bool _isRecording = false;
  final _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  bool get isMuted => _isMuted;
  bool get isRecording => _isRecording;

  final void Function(String message)? onLog;
  final void Function(String error)? onError;

  MicrophoneService({
    this.onLog,
    this.onError,
  });

  Future<bool> requestPermissions() async {
    try {
      return await _audioRecorder.hasPermission();
    } catch (e) {
      onError?.call('Error requesting microphone permissions: $e');
      return false;
    }
  }

  Future<void> startRecording() async {
    if (_isRecording) return;
    
    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        onError?.call('Microphone permission denied');
        return;
      }

      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 128000,
      );

      final audioStream = await _audioRecorder.startStream(config);
      _isRecording = true;

      _audioStreamSubscription = audioStream.listen(
        (data) => _onAudioData(data),
        onError: (error) {
          onError?.call('Microphone Stream Error: $error');
          _stopRecording();
        },
        onDone: () {
          onLog?.call('Microphone stream finished.');
          _isRecording = false;
        },
        cancelOnError: true,
      );
      
      onLog?.call('Started microphone recording');
    } catch (e) {
      onError?.call('Error starting microphone: $e');
      _isRecording = false;
    }
  }

  void _onAudioData(Uint8List data) {
    if (_isRecording && !_isMuted) {
      _audioDataController.add(data);
      onLog?.call('⬆️ Sending microphone data: ${data.length} bytes');
    } else if (_isMuted) {
      // Send silence when muted
      final silentData = Uint8List(data.length);
      _audioDataController.add(silentData);
    }
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    onLog?.call('Microphone ${muted ? 'muted' : 'unmuted'}');
  }

  void toggleMute() {
    setMuted(!_isMuted);
  }

  Future<void> stopRecording() async {
    await _stopRecording();
  }

  Future<void> _stopRecording() async {
    if (_isRecording) {
      await _audioRecorder.stop();
      _isRecording = false;
      onLog?.call('Microphone recording stopped');
    }
    
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;
  }

  void dispose() {
    _stopRecording();
    _audioRecorder.dispose();
    _audioDataController.close();
  }
}
