package api

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
)

var upgrader = websocket.Upgrader{
	// Allow connections from any origin. The mobile client connects
	// directly or through a reverse proxy; origin-based protection is
	// not meaningful here — authentication is handled by the auth middleware.
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ChatMessage is the message format for the /ws/chat WebSocket.
type ChatMessage struct {
	Type      string `json:"type"`                // "send", "resume", "start"
	Message   string `json:"message,omitempty"`   // For "send" type.
	SessionID string `json:"sessionId,omitempty"` // For "resume" type.
	WorkDir   string `json:"workDir,omitempty"`   // For "start" type.
}

// handleWSChat handles the /ws/chat WebSocket endpoint for AI conversation streaming.
func (s *Server) handleWSChat(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade error: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("[WS/Chat] connection established")

	// Track the active conversation so we can clean it up when the
	// WebSocket closes (e.g. client disconnects).
	var activeConv *claude.Conversation
	var activeConvMu sync.Mutex
	defer func() {
		activeConvMu.Lock()
		if activeConv != nil {
			activeConv.Close()
			s.processManager.RemoveConversation(activeConv.ID)
		}
		activeConvMu.Unlock()
	}()

	setActiveConv := func(conv *claude.Conversation) {
		activeConvMu.Lock()
		activeConv = conv
		activeConvMu.Unlock()
	}

	for {
		_, msgData, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[WS/Chat] read error: %v", err)
			}
			log.Printf("[WS/Chat] connection closed")
			return
		}

		var chatMsg ChatMessage
		if err := json.Unmarshal(msgData, &chatMsg); err != nil {
			writeWSError(conn, "invalid message format")
			continue
		}

		switch chatMsg.Type {
		case "start":
			s.handleChatStart(conn, chatMsg, setActiveConv)
		case "resume":
			s.handleChatResume(conn, chatMsg, setActiveConv)
		case "send":
			s.handleChatSend(conn, chatMsg)
		default:
			writeWSError(conn, "unknown message type: "+chatMsg.Type)
		}
	}
}

func (s *Server) handleChatStart(conn *websocket.Conn, msg ChatMessage, setActiveConv func(*claude.Conversation)) {
	conv, err := s.processManager.StartConversation(msg.WorkDir)
	if err != nil {
		log.Printf("[WS/Chat] failed to start conversation: %v", err)
		writeWSError(conn, "failed to start conversation: "+err.Error())
		return
	}
	log.Printf("[WS/Chat] started conversation %s (workDir=%s)", conv.ID, msg.WorkDir)
	setActiveConv(conv)

	// Send the conversation ID back.
	writeWSJSON(conn, map[string]string{
		"type":           "started",
		"conversationId": conv.ID,
	})

	// Stream output to WebSocket.
	go s.streamOutput(conn, conv)
}

func (s *Server) handleChatResume(conn *websocket.Conn, msg ChatMessage, setActiveConv func(*claude.Conversation)) {
	conv, err := s.processManager.ResumeConversation(msg.SessionID)
	if err != nil {
		log.Printf("[WS/Chat] failed to resume conversation %s: %v", msg.SessionID, err)
		writeWSError(conn, "failed to resume conversation: "+err.Error())
		return
	}
	log.Printf("[WS/Chat] resumed conversation %s", conv.ID)
	setActiveConv(conv)

	writeWSJSON(conn, map[string]string{
		"type":           "resumed",
		"conversationId": conv.ID,
	})

	go s.streamOutput(conn, conv)
}

func (s *Server) handleChatSend(conn *websocket.Conn, msg ChatMessage) {
	if msg.SessionID == "" {
		writeWSError(conn, "missing sessionId for send")
		return
	}
	conv, ok := s.processManager.GetConversation(msg.SessionID)
	if !ok {
		log.Printf("[WS/Chat] conversation not found: %s", msg.SessionID)
		writeWSError(conn, "conversation not found: "+msg.SessionID)
		return
	}

	if err := conv.Send(msg.Message); err != nil {
		log.Printf("[WS/Chat] failed to send message to %s: %v", conv.ID, err)
		writeWSError(conn, "failed to send message: "+err.Error())
		return
	}
	log.Printf("[WS/Chat] sent message to conversation %s", conv.ID)
}

func (s *Server) streamOutput(conn *websocket.Conn, conv *claude.Conversation) {
	for output := range conv.Output {
		if err := writeWSJSON(conn, output); err != nil {
			log.Printf("[WS/Chat] write error for conversation %s: %v", conv.ID, err)
			return
		}
	}
	// Conversation ended.
	log.Printf("[WS/Chat] conversation %s ended", conv.ID)
	writeWSJSON(conn, map[string]string{"type": "closed"})
	conv.Close()
	s.processManager.RemoveConversation(conv.ID)
}

// FileWatchClient represents a connected file watch client.
type FileWatchClient struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

// FileWatchHub manages file watch WebSocket connections.
type FileWatchHub struct {
	mu      sync.RWMutex
	clients map[*FileWatchClient]struct{}
}

// NewFileWatchHub creates a new FileWatchHub.
func NewFileWatchHub() *FileWatchHub {
	return &FileWatchHub{
		clients: make(map[*FileWatchClient]struct{}),
	}
}

// Broadcast sends a file event to all connected clients.
// Clients that fail to receive the message are removed and closed.
func (h *FileWatchHub) Broadcast(event interface{}) {
	h.mu.RLock()
	var dead []*FileWatchClient
	for client := range h.clients {
		client.mu.Lock()
		err := client.conn.WriteJSON(event)
		client.mu.Unlock()
		if err != nil {
			log.Printf("file watch broadcast error: %v", err)
			dead = append(dead, client)
		}
	}
	h.mu.RUnlock()

	// Remove dead clients outside the read lock to avoid lock inversion.
	for _, client := range dead {
		h.removeClient(client)
		client.conn.Close()
	}
}

func (h *FileWatchHub) addClient(client *FileWatchClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[client] = struct{}{}
}

func (h *FileWatchHub) removeClient(client *FileWatchClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, client)
}

// handleWSFiles handles the /ws/files WebSocket endpoint for file watch events.
func (s *Server) handleWSFiles(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade error: %v", err)
		return
	}
	defer conn.Close()

	client := &FileWatchClient{conn: conn}
	s.fileWatchHub.addClient(client)
	defer s.fileWatchHub.removeClient(client)

	// Keep the connection open; read messages to detect close.
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

func writeWSError(conn *websocket.Conn, msg string) {
	writeWSJSON(conn, map[string]string{
		"type":  "error",
		"error": msg,
	})
}

func writeWSJSON(conn *websocket.Conn, v interface{}) error {
	return conn.WriteJSON(v)
}
