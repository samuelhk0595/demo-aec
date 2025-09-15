import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_aec/flutter_aec.dart';
import '../services/walkie_talkie_service.dart';

class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({super.key});

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen>
    with TickerProviderStateMixin {
  late final WalkieTalkieService _walkieTalkieService;
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _serverController =
      TextEditingController(text: 'ws://192.168.10.250:8080/ws');

  bool _hasSetNickname = false;
  bool _isRecording = false;
  bool _isContinuousMode = false;
  List<String> _logs = [];

  // Animation and gesture tracking
  late AnimationController _animationController;
  late Animation<double> _buttonOffsetAnimation;
  double _dragStartY = 0;
  bool _isDragging = false;
  static const double _dragThreshold = 50.0; // Pixels to drag up for continuous mode  @override
  void initState() {
    super.initState();
    _walkieTalkieService = WalkieTalkieService();
    
    // Initialize animation controller
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _buttonOffsetAnimation = Tween<double>(
      begin: 0,
      end: -20, // Move up 20 pixels
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _initializeService();
  }

  Future<void> _initializeService() async {
    await _walkieTalkieService.initialize();

    // Listen to connection status changes
    _walkieTalkieService.connectionStatusStream.listen((status) {
      setState(() {});
    });

    // Listen to logs
    _walkieTalkieService.logStream.listen((log) {
      setState(() {
        _logs.add(log);
        if (_logs.length > 50) {
          _logs.removeAt(0); // Keep only last 50 logs
        }
      });
    });
  }

  Future<void> _requestPermissions() async {
    final micPermission = await Permission.microphone.request();
    if (micPermission != PermissionStatus.granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required')),
        );
      }
    }
  }

  Future<void> _setNickname() async {
    if (_nicknameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a nickname')),
      );
      return;
    }

    await _requestPermissions();
    setState(() {
      _hasSetNickname = true;
    });
  }

  Future<void> _connect() async {
    if (_serverController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter server URL')),
      );
      return;
    }

    await _walkieTalkieService.connect(
      _serverController.text.trim(),
      _nicknameController.text.trim(),
    );
  }

  void _disconnect() {
    _walkieTalkieService.disconnect();
    setState(() {
      _isRecording = false;
      _isContinuousMode = false;
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _walkieTalkieService.stopRecording();
    } else {
      await _walkieTalkieService.startRecording();
    }
    setState(() {
      _isRecording = !_isRecording;
    });
  }

  void _handlePanStart(DragStartDetails details) {
    if (!_isContinuousMode) {
      _dragStartY = details.localPosition.dy;
      _isDragging = true;
      // Start recording for push-to-talk
      if (!_isRecording) {
        _toggleRecording();
      }
    }
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!_isContinuousMode && _isDragging) {
      double dragDistance = _dragStartY - details.localPosition.dy;
      
      // Update animation based on drag distance
      double progress = (dragDistance / _dragThreshold).clamp(0.0, 1.0);
      _animationController.value = progress;
      
      // Provide haptic feedback when reaching threshold
      if (progress >= 1.0 && _animationController.value < 1.0) {
        // Haptic feedback when threshold is reached
        // HapticFeedback.mediumImpact(); // Uncomment if you want haptic feedback
      }
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    if (!_isContinuousMode && _isDragging) {
      _isDragging = false;
      
      if (_animationController.value >= 1.0) {
        // Drag threshold reached - enter continuous mode
        _enterContinuousMode();
      } else {
        // Threshold not reached - stop recording and reset animation
        if (_isRecording) {
          _toggleRecording();
        }
        _animationController.reverse();
      }
    }
  }

  void _handleTap() async {
    if (_isContinuousMode) {
      // Exit continuous mode when tapped
      await _exitContinuousMode();
    }else{
      await _enterContinuousMode();
    }
  }

  Future<void> _enterContinuousMode() async {
    setState(() {
      _isContinuousMode = true;
    });
    
    // Complete the animation
    await _animationController.forward();
    
    // Ensure recording is active
    if (!_isRecording) {
      await _toggleRecording();
    }
  }

  Future<void> _exitContinuousMode() async {
    setState(() {
      _isContinuousMode = false;
    });
    
    // Stop recording if active
    if (_isRecording) {
      await _toggleRecording();
    }
    
    // Reset animation
    await _animationController.reverse();
  }

  void _toggleMute() {
    _walkieTalkieService.toggleMute();
    setState(() {});
  }

  String _getConnectionStatusText() {
    switch (_walkieTalkieService.connectionStatus) {
      case ConnectionStatus.disconnected:
        return 'Disconnected';
      case ConnectionStatus.connecting:
        return 'Connecting...';
      case ConnectionStatus.connected:
        return 'Connected as ${_walkieTalkieService.nickname}';
      case ConnectionStatus.error:
        return 'Connection Error';
    }
  }

  String _getRecordingStatusText() {
    if (_isContinuousMode) {
      return _isRecording
          ? 'Recording... (Continuous) - Tap to stop'
          : 'Continuous Mode - Tap to stop';
    } else {
      return _isRecording
          ? 'Recording... (Hold) - Drag up for continuous'
          : 'Hold to talk • Drag up for continuous';
    }
  }

  Color _getConnectionStatusColor() {
    switch (_walkieTalkieService.connectionStatus) {
      case ConnectionStatus.disconnected:
        return Colors.grey;
      case ConnectionStatus.connecting:
        return Colors.orange;
      case ConnectionStatus.connected:
        return Colors.green;
      case ConnectionStatus.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSetNickname) {
      return _buildNicknameScreen();
    }

    return _buildMainScreen();
  }

  Widget _buildNicknameScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walkie Talkie'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.radio,
              size: 100,
              color: Colors.orange,
            ),
            const SizedBox(height: 32),
            const Text(
              'Welcome to Walkie Talkie',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Please enter your nickname to get started',
              style: TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nicknameController,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _setNickname(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _setNickname,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainScreen() {
    final isConnected =
        _walkieTalkieService.connectionStatus == ConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Walkie Talkie'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Connection status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: _getConnectionStatusColor().withOpacity(0.1),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  color: _getConnectionStatusColor(),
                  size: 12,
                ),
                const SizedBox(width: 8),
                Text(
                  _getConnectionStatusText(),
                  style: TextStyle(
                    color: _getConnectionStatusColor(),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // AEC Status indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.blue.withOpacity(0.1),
            child: Row(
              children: [
                Icon(
                  Icons.auto_fix_high,
                  color: FlutterAec.instance.isInitialized ? Colors.green : Colors.grey,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'AEC: ${FlutterAec.instance.isInitialized ? "Active" : "Inactive"} | NS: Enabled',
                  style: TextStyle(
                    color: FlutterAec.instance.isInitialized ? Colors.green : Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (FlutterAec.instance.isInitialized) ...[
                  Icon(
                    Icons.mic,
                    color: FlutterAec.instance.isCaptureStarted ? Colors.red : Colors.grey,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.speaker,
                    color: FlutterAec.instance.isPlaybackStarted ? Colors.blue : Colors.grey,
                    size: 14,
                  ),
                ],
              ],
            ),
          ),

          // Server connection section
          if (!isConnected) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  TextField(
                    controller: _serverController,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.wifi),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _walkieTalkieService.connectionStatus ==
                            ConnectionStatus.connecting
                        ? null
                        : _connect,
                    child: Text(_walkieTalkieService.connectionStatus ==
                            ConnectionStatus.connecting
                        ? 'Connecting...'
                        : 'Connect'),
                  ),
                ],
              ),
            ),
          ],
          // Logs section
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(8),
                        topRight: Radius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Logs',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      reverse: true,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[_logs.length - 1 - index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          child: Text(
                            log,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: log.contains('ERROR')
                                  ? Colors.red
                                  : Colors.black87,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Controls section
          if (isConnected) ...[
            // Control buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Mute button
                ElevatedButton.icon(
                  onPressed: _toggleMute,
                  icon: Icon(
                      _walkieTalkieService.isMuted ? Icons.mic_off : Icons.mic),
                  label: Text(_walkieTalkieService.isMuted ? 'Unmute' : 'Mute'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _walkieTalkieService.isMuted ? Colors.red : null,
                    foregroundColor:
                        _walkieTalkieService.isMuted ? Colors.white : null,
                  ),
                ),

                // Disconnect button
                ElevatedButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Disconnect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  // Record button with animation
                  AnimatedBuilder(
                    animation: _buttonOffsetAnimation,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(0, _buttonOffsetAnimation.value),
                        child: GestureDetector(
                          onTap: _handleTap,
                          // onPanStart: _handlePanStart,
                          // onPanUpdate: _handlePanUpdate,
                          // onPanEnd: _handlePanEnd,
                          // onLongPress: () {
                          //   debugPrint('Long press detected');
                          // },
                          child: Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isRecording ? Colors.red : Colors.grey[300],
                              border: Border.all(
                                color: _isRecording
                                    ? Colors.red[700]!
                                    : Colors.grey[400]!,
                                width: 4,
                              ),
                              // Add visual indicator for continuous mode
                              boxShadow: _isContinuousMode
                                  ? [
                                      BoxShadow(
                                        color: Colors.red.withOpacity(0.5),
                                        blurRadius: 10,
                                        spreadRadius: 2,
                                      )
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              _isContinuousMode ? Icons.stop : Icons.mic,
                              size: 50,
                              color: _isRecording ? Colors.white : Colors.grey[600],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _getRecordingStatusText(),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _walkieTalkieService.dispose();
    _nicknameController.dispose();
    _serverController.dispose();
    _animationController.dispose();
    super.dispose();
  }
}
