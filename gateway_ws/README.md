# Walkie Talkie Gateway

A simple WebSocket-based backend server for a walkie talkie application written in Go.

## Features

- WebSocket server for real-time audio data transmission
- Broadcasts audio data from one client to all other connected clients
- Thread-safe client management
- Simple health check endpoint

## API Endpoints

- `GET /` - Basic server information
- `GET /health` - Health check endpoint (returns "OK")
- `WebSocket /ws` - Main WebSocket endpoint for audio data transmission

## How it works

1. Clients connect to the WebSocket endpoint at `/ws`
2. When a client sends audio data (microphone input), the server broadcasts it to all other connected clients
3. Clients receive the broadcasted audio data and can play it through their speakers
4. The server maintains a registry of connected clients and handles disconnections gracefully

## Running the server

```bash
# Install dependencies
go mod tidy

# Run the server
go run main.go
```

The server will start on port 8080 by default.

## WebSocket Protocol

- The WebSocket accepts binary messages containing audio data
- All received audio data is immediately broadcasted to all other connected clients
- No message transformation or audio processing is performed on the server side

## Client Integration

Clients should:
1. Connect to `ws://localhost:8080/ws`
2. Send microphone audio data as binary WebSocket messages
3. Listen for incoming binary messages and play them as audio

## Development Notes

- The server allows connections from any origin (CORS is disabled for simplicity)
- Client identification is basic (using remote address or X-Client-ID header)
- No authentication or authorization is implemented
- Audio data is not persisted or processed

For production use, consider adding:
- Authentication and authorization
- Rate limiting
- Audio format validation
- Message size limits
- Proper logging and monitoring
