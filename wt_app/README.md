# wt_app

# Walkie Talkie Flutter App

A simple walkie talkie mobile application built with Flutter that connects to a WebSocket backend for real-time audio communication.

## Features

- **Nickname Setup**: Users enter a nickname when first opening the app
- **WebSocket Connection**: Connects to a Go backend server via WebSocket
- **Real-time Audio**: 
  - Records microphone audio and sends it to the server
  - Receives and plays audio from other connected users
  - Push-to-talk functionality
- **Mute Function**: Users can mute their microphone
- **Connection Status**: Visual indicator showing connection status
- **Logs**: Real-time logging of app activities

## Dependencies

The app uses the following key packages:

- `web_socket_channel: ^2.4.0` - WebSocket client communication
- `record: ^5.2.1` - Audio recording from microphone
- `realtime_audio: ^0.0.10` - Real-time audio playback
- `permission_handler: ^11.3.1` - Requesting microphone permissions

## Architecture

### Services

1. **WebSocketService** (`lib/services/websocket_service.dart`)
   - Handles WebSocket connection to the backend
   - Sends/receives binary audio data and text messages
   - Manages connection state

2. **MicrophoneService** (`lib/clients/microphone_service.dart`)
   - Records audio from device microphone
   - Streams audio data as Uint8List
   - Handles mute/unmute functionality

3. **AudioPlaybackService** (`lib/clients/audio_playback_service.dart`)
   - Plays received audio data through device speakers
   - Manages audio playback queue
   - Handles real-time audio streaming

4. **WalkieTalkieService** (`lib/services/walkie_talkie_service.dart`)
   - Coordinates all services
   - Manages connection lifecycle
   - Provides unified API for the UI

### UI

- **WalkieTalkieScreen** (`lib/screens/walkie_talkie_screen.dart`)
  - Main app interface
  - Nickname setup flow
  - Connection management
  - Push-to-talk controls
  - Status indicators and logs

## Setup

### Prerequisites

- Flutter SDK (3.8.1+)
- Android Studio / Xcode for mobile development
- Running Go backend server (see `gateway_ws` folder)

### Installation

1. Navigate to the app directory:
   ```bash
   cd wt_app
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the app:
   ```bash
   flutter run
   ```

### Permissions

The app requires microphone permissions to function:

- **Android**: Automatically configured in `android/app/src/main/AndroidManifest.xml`
- **iOS**: Microphone usage description added to `ios/Runner/Info.plist`

## Usage

1. **First Launch**: Enter your nickname
2. **Connect**: Enter the WebSocket server URL (default: `ws://localhost:8080/ws`)
3. **Talk**: Tap and hold the microphone button to record and broadcast audio
4. **Listen**: Audio from other users plays automatically
5. **Mute**: Use the mute button to stop sending audio while staying connected
6. **Disconnect**: Use the disconnect button to leave the session

## Configuration

### Server URL

By default, the app connects to `ws://localhost:8080/ws`. For production or testing with different servers, update the server URL in the connection screen.

### Audio Settings

Audio recording is configured with:
- Sample rate: 16 kHz
- Channels: Mono (1 channel)
- Encoding: PCM 16-bit
- Bit rate: 128 kbps

## Development Notes

- The app uses WebSocket binary messages for audio data transmission
- Audio data is sent as raw PCM without compression
- The UI provides real-time feedback through logs and status indicators
- Push-to-talk is implemented with tap-and-hold gesture recognition

## Troubleshooting

### Common Issues

1. **Microphone Permission Denied**
   - Grant microphone permission in device settings
   - Restart the app after granting permission

2. **Connection Failed**
   - Verify the backend server is running
   - Check the WebSocket URL format
   - Ensure network connectivity

3. **No Audio Playback**
   - Check device volume settings
   - Verify other users are connected and talking
   - Restart the app if audio engine fails to initialize

### Debug Mode

The app includes comprehensive logging that shows:
- Connection status changes
- Audio data transmission
- Service initialization
- Error messages

Monitor the logs section in the app for troubleshooting information.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
