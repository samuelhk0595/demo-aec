package main

import (
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

// Client represents a connected websocket client
type Client struct {
	conn *websocket.Conn
	send chan []byte
	hub  *Hub
	id   string
}

// Hub maintains the set of active clients and broadcasts messages to them
type Hub struct {
	// Registered clients
	clients map[*Client]bool

	// Inbound messages from the clients
	broadcast chan BroadcastMessage

	// Register requests from the clients
	register chan *Client

	// Unregister requests from clients
	unregister chan *Client

	// Mutex for thread-safe operations
	mutex sync.RWMutex
}

// BroadcastMessage contains the message and the sender client
type BroadcastMessage struct {
	data   []byte
	sender *Client
}

// NewHub creates a new Hub instance
func NewHub() *Hub {
	return &Hub{
		broadcast:  make(chan BroadcastMessage),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		clients:    make(map[*Client]bool),
	}
}

// Run starts the hub and handles client registration, unregistration, and broadcasting
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mutex.Lock()
			h.clients[client] = true
			h.mutex.Unlock()
			log.Printf("Client %s connected. Total clients: %d", client.id, len(h.clients))

		case client := <-h.unregister:
			h.mutex.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.send)
				log.Printf("Client %s disconnected. Total clients: %d", client.id, len(h.clients))
			}
			h.mutex.Unlock()

		case message := <-h.broadcast:
			h.mutex.RLock()
			for client := range h.clients {
				// Don't send the message back to the sender
				if client == message.sender {
					continue
				}
				select {
				case client.send <- message.data:
				default:
					close(client.send)
					delete(h.clients, client)
				}
			}
			h.mutex.RUnlock()
		}
	}
}

// readPump pumps messages from the websocket connection to the hub
func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("Error reading message from client %s: %v", c.id, err)
			}
			break
		}

		// Broadcast the audio data to all other clients (excluding sender)
		c.hub.broadcast <- BroadcastMessage{
			data:   message,
			sender: c,
		}
	}
}

// writePump pumps messages from the hub to the websocket connection
func (c *Client) writePump() {
	defer c.conn.Close()

	for {
		select {
		case message, ok := <-c.send:
			if !ok {
				// The hub closed the channel
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			if err := c.conn.WriteMessage(websocket.BinaryMessage, message); err != nil {
				log.Printf("Error writing message to client %s: %v", c.id, err)
				return
			}
		}
	}
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		// Allow connections from any origin for simplicity
		// In production, you should validate the origin
		return true
	},
}

// serveWS handles websocket requests from the peer
func serveWS(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	// Generate a simple client ID (in production, use proper UUID)
	clientID := r.Header.Get("X-Client-ID")
	if clientID == "" {
		clientID = r.RemoteAddr
	}

	client := &Client{
		conn: conn,
		send: make(chan []byte, 256),
		hub:  hub,
		id:   clientID,
	}

	client.hub.register <- client

	// Start goroutines for reading and writing
	go client.writePump()
	go client.readPump()
}

func main() {
	hub := NewHub()
	go hub.Run()

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveWS(hub, w, r)
	})

	// Simple health check endpoint
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	// Serve basic info about the server
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`
			<h1>Walkie Talkie Gateway</h1>
			<p>WebSocket endpoint: <code>/ws</code></p>
			<p>Health check: <code>/health</code></p>
		`))
	})

	port := ":8080"
	log.Printf("Starting walkie talkie gateway server on port %s", port)
	log.Printf("WebSocket endpoint: ws://localhost%s/ws", port)

	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatal("ListenAndServe: ", err)
	}
}
