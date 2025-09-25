import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class WebSocketService {
  WebSocketChannel? _channel;
  String? _nickname;
  bool _isConnected = false;

  final void Function(String message)? onMessage;
  final void Function()? onConnected;
  final void Function()? onDisconnected;
  final void Function(dynamic error)? onError;
  final void Function(Uint8List audioData)? onAudioData;

  WebSocketService({
    this.onMessage,
    this.onConnected,
    this.onDisconnected,
    this.onError,
    this.onAudioData,
  });

  bool get isConnected => _isConnected;
  String? get nickname => _nickname;

  Future<void> connect(String serverUrl, String nickname) async {
    try {
      _nickname = nickname;
      _channel = WebSocketChannel.connect(
        Uri.parse(serverUrl),
      );

      _channel!.stream.listen(
        (data) {
          if (data is List<int>) {
            // Binary data (audio)
            onAudioData?.call(Uint8List.fromList(data));
          } else if (data is String) {
            // Text message
            onMessage?.call(data);
          }
        },
        onError: (error) {
          _isConnected = false;
          onError?.call(error);
        },
        onDone: () {
          _isConnected = false;
          onDisconnected?.call();
        },
      );

      _isConnected = true;
      onConnected?.call();
    } catch (e) {
      _isConnected = false;
      onError?.call(e);
    }
  }

  void sendAudioData(Uint8List audioData) {
    if (_isConnected && _channel != null) {
      _channel!.sink.add(audioData);
    }
  }

  void sendTextMessage(String message) {
    if (_isConnected && _channel != null) {
      final messageWithNickname = jsonEncode({
        'nickname': _nickname,
        'message': message,
        'timestamp': DateTime.now().toIso8601String(),
      });
      _channel!.sink.add(messageWithNickname);
    }
  }

  void disconnect() {
    _isConnected = false;
    _channel?.sink.close(status.goingAway);
    _channel = null;
    _nickname = null;
  }

  void dispose() {
    disconnect();
  }
}
