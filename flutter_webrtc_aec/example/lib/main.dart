import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc_aec/flutter_webrtc_aec.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _flutterWebrtcAecPlugin = FlutterWebrtcAec();
  
  bool _isAudioActive = false;
  bool _isUserSpeaking = false;
  bool _isMp3Playing = false;
  String _statusMessage = 'Ready to start';

  @override
  void initState() {
    super.initState();
    _setupAudioCallbacks();
  }

  void _setupAudioCallbacks() {
    // Set up capture callback for processed audio
    _flutterWebrtcAecPlugin.setCaptureCallback((audioData) {
      // Here you would typically send the processed audio to your network stack
      // For demo purposes, we just log that we received processed audio
      if (mounted) {
        setState(() {
          _statusMessage = 'Receiving processed audio: ${audioData.length} samples';
        });
      }
    });

    // Set up speech detection callback for intelligent interruption
    _flutterWebrtcAecPlugin.setSpeechDetectionCallback((isSpeaking) {
      if (mounted) {
        setState(() {
          _isUserSpeaking = isSpeaking;
          _statusMessage = isSpeaking 
            ? 'User is speaking - MP3 paused' 
            : 'User stopped speaking - MP3 will resume in 2 seconds';
        });
      }
    });
  }

  Future<void> _startTalking() async {
    try {
      // Start the AEC audio processing
      final success = await _flutterWebrtcAecPlugin.start();
      if (success) {
        setState(() {
          _isAudioActive = true;
          _statusMessage = 'Audio processing started';
        });

        // Start playing MP3 in loop (you would replace this with your actual MP3 file path)
        // For demo purposes, we'll simulate MP3 playback
        final mp3Success = await _simulateMp3Playback();
        if (mp3Success) {
          setState(() {
            _isMp3Playing = true;
            _statusMessage = 'AI speaking - MP3 loop started';
          });
        }
      } else {
        setState(() {
          _statusMessage = 'Failed to start audio processing';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    }
  }

  Future<bool> _simulateMp3Playback() async {
    // In a real implementation, you would use:
    // return await _flutterWebrtcAecPlugin.playMp3Loop('/path/to/your/audio.mp3');
    
    // For demo, we'll simulate this
    return true;
  }

  Future<void> _stopTalking() async {
    try {
      // Stop MP3 playback
      await _flutterWebrtcAecPlugin.stopMp3Loop();
      
      // Stop audio processing
      final success = await _flutterWebrtcAecPlugin.stop();
      
      setState(() {
        _isAudioActive = false;
        _isMp3Playing = false;
        _isUserSpeaking = false;
        _statusMessage = success ? 'Audio processing stopped' : 'Failed to stop audio processing';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error stopping: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC AEC Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('WebRTC AEC Demo'),
          backgroundColor: Colors.blue,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Status Card
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text(
                        'Audio Processing Status',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildStatusIndicator('Audio Active', _isAudioActive, Colors.green),
                          _buildStatusIndicator('MP3 Playing', _isMp3Playing, Colors.blue),
                          _buildStatusIndicator('User Speaking', _isUserSpeaking, Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Control Buttons
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isAudioActive ? null : _startTalking,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                      child: const Text('Start Talking'),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isAudioActive ? _stopTalking : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 32),
              
              // Instructions Card
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'How to use:',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Text('1. Press "Start Talking" to begin AI audio loop'),
                      Text('2. Start speaking - the audio will pause automatically'),
                      Text('3. Stop speaking - audio resumes after 2 seconds'),
                      Text('4. Press "Stop" to end the demo'),
                      SizedBox(height: 8),
                      Text(
                        'Note: This demo uses WebRTC AEC to prevent echo while allowing intelligent interruption.',
                        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                      ),
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

  Widget _buildStatusIndicator(String label, bool isActive, Color color) {
    return Column(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? color : Colors.grey.shade300,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? color : Colors.grey,
          ),
        ),
      ],
    );
  }
}
