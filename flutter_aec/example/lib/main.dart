import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_aec/flutter_aec.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _aec = FlutterAec.instance;
  
  bool _isInitialized = false;
  bool _isCapturing = false;
  bool _isPlaying = false;
  String _status = 'Not initialized';
  int _processedFrames = 0;
  
  StreamSubscription<Uint8List>? _frameSubscription;
  Timer? _testToneTimer;
  
  final AecConfig _config = const AecConfig(
    sampleRate: 16000,
    frameMs: 20,
    echoMode: 3,
    enableNs: true,
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _cleanup() async {
    _testToneTimer?.cancel();
    _frameSubscription?.cancel();
    if (_isInitialized) {
      await _aec.dispose();
    }
  }

  Future<void> _requestPermissions() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _setStatus('Microphone permission denied');
      return;
    }
    _setStatus('Permissions granted');
  }

  Future<void> _initialize() async {
    try {
      await _requestPermissions();
      
      final success = await _aec.initialize(_config);
      if (success) {
        setState(() {
          _isInitialized = true;
        });
        _setStatus('AEC Engine initialized successfully');
        
        // Subscribe to processed frames
        _frameSubscription = _aec.processedNearStream.listen(
          (frameData) {
            setState(() {
              _processedFrames++;
            });
          },
          onError: (error) {
            _setStatus('Frame stream error: $error');
          },
        );
      } else {
        _setStatus('Failed to initialize AEC Engine');
      }
    } catch (e) {
      _setStatus('Initialize error: $e');
    }
  }

  Future<void> _startCapture() async {
    if (!_isInitialized) {
      _setStatus('Not initialized');
      return;
    }

    try {
      final success = await _aec.startNativeCapture();
      if (success) {
        setState(() {
          _isCapturing = true;
        });
        _setStatus('Audio capture started');
      } else {
        _setStatus('Failed to start capture');
      }
    } catch (e) {
      _setStatus('Capture error: $e');
    }
  }

  Future<void> _stopCapture() async {
    try {
      await _aec.stopNativeCapture();
      setState(() {
        _isCapturing = false;
      });
      _setStatus('Audio capture stopped');
    } catch (e) {
      _setStatus('Stop capture error: $e');
    }
  }

  Future<void> _startPlayback() async {
    if (!_isInitialized) {
      _setStatus('Not initialized');
      return;
    }

    try {
      final success = await _aec.startNativePlayback();
      if (success) {
        setState(() {
          _isPlaying = true;
        });
        _setStatus('Audio playback started');
      } else {
        _setStatus('Failed to start playback');
      }
    } catch (e) {
      _setStatus('Playback error: $e');
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _aec.stopNativePlayback();
      setState(() {
        _isPlaying = false;
      });
      _setStatus('Audio playback stopped');
      _testToneTimer?.cancel();
    } catch (e) {
      _setStatus('Stop playback error: $e');
    }
  }

  void _startTestTone() {
    if (!_isInitialized || !_isPlaying) {
      _setStatus('Playback not started');
      return;
    }

    // Generate test tone at 1kHz
    const frequency = 1000.0;
    const amplitude = 0.3;
    int sampleIndex = 0;

    _testToneTimer = Timer.periodic(
      Duration(milliseconds: _config.frameMs),
      (timer) async {
        try {
          final frameSize = _config.frameSizeSamples;
          final frameData = Uint8List(frameSize * 2); // PCM16
          
          for (int i = 0; i < frameSize; i++) {
            final sample = (amplitude * 32767 * 
                math.sin(2 * math.pi * frequency * sampleIndex / _config.sampleRate))
                .round()
                .clamp(-32768, 32767);
            
            // Write as little-endian PCM16
            frameData[i * 2] = sample & 0xFF;
            frameData[i * 2 + 1] = (sample >> 8) & 0xFF;
            sampleIndex++;
          }

          await _aec.bufferFarend(frameData);
        } catch (e) {
          _setStatus('Test tone error: $e');
          timer.cancel();
        }
      },
    );
    
    _setStatus('Test tone started (1kHz)');
  }

  void _stopTestTone() {
    _testToneTimer?.cancel();
    _setStatus('Test tone stopped');
  }

  void _setStatus(String status) {
    setState(() {
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter AEC Demo'),
          backgroundColor: Colors.blue[600],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AEC Engine Status',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Status: $_status'),
                      Text('Initialized: ${_isInitialized ? 'Yes' : 'No'}'),
                      Text('Capturing: ${_isCapturing ? 'Yes' : 'No'}'),
                      Text('Playing: ${_isPlaying ? 'Yes' : 'No'}'),
                      Text('Processed frames: $_processedFrames'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Configuration',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Sample Rate: ${_config.sampleRate} Hz'),
                      Text('Frame Size: ${_config.frameMs} ms'),
                      Text('Echo Mode: ${_config.echoMode}'),
                      Text('Noise Suppression: ${_config.enableNs ? 'Enabled' : 'Disabled'}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isInitialized ? null : _initialize,
                child: const Text('Initialize AEC Engine'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: !_isInitialized ? null : 
                        (_isCapturing ? _stopCapture : _startCapture),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isCapturing ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(_isCapturing ? 'Stop Capture' : 'Start Capture'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: !_isInitialized ? null : 
                        (_isPlaying ? _stopPlayback : _startPlayback),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isPlaying ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(_isPlaying ? 'Stop Playback' : 'Start Playback'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: !_isPlaying ? null : _startTestTone,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Start Test Tone'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _stopTestTone,
                      child: const Text('Stop Test Tone'),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Card(
                color: Colors.blue[50],
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How to test AEC:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text('1. Initialize the engine'),
                      Text('2. Start capture and playback'),
                      Text('3. Start test tone - you should hear it from speaker'),
                      Text('4. Speak into microphone - processed frames will be captured with echo cancelled'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
