package api

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

// terminalMessage is the JSON wire format for terminal WebSocket messages.
type terminalMessage struct {
	Type    string `json:"type"`
	ID      string `json:"id"`
	Shell   string `json:"shell,omitempty"`
	WorkDir string `json:"workDir,omitempty"`
	Rows    uint16 `json:"rows,omitempty"`
	Cols    uint16 `json:"cols,omitempty"`
	Data    string `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// handleWSTerminal handles the /ws/terminal WebSocket endpoint.
func (s *Server) handleWSTerminal(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("terminal websocket upgrade error: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("[WS/Terminal] connection established")

	// connMu protects writes to the WebSocket connection from concurrent goroutines.
	var connMu sync.Mutex

	// Track goroutines reading from terminals so we can clean up.
	var wg sync.WaitGroup
	// Track which terminals were created via this connection.
	var createdIDs []string
	var idsMu sync.Mutex

	defer func() {
		// Close all terminals created on this connection.
		idsMu.Lock()
		ids := createdIDs
		idsMu.Unlock()
		for _, id := range ids {
			_ = s.termManager.Close(id)
		}
		wg.Wait()
	}()

	sendMsg := func(msg terminalMessage) {
		connMu.Lock()
		defer connMu.Unlock()
		if err := conn.WriteJSON(msg); err != nil {
			log.Printf("terminal ws write error: %v", err)
		}
	}

	sendError := func(id string, errMsg string) {
		sendMsg(terminalMessage{Type: "error", ID: id, Error: errMsg})
	}

	for {
		_, rawMsg, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[WS/Terminal] read error: %v", err)
			}
			log.Printf("[WS/Terminal] connection closed")
			return
		}

		var msg terminalMessage
		if err := json.Unmarshal(rawMsg, &msg); err != nil {
			sendError("", "invalid message format")
			continue
		}

		switch msg.Type {
		case "create":
			s.handleTermCreate(&wg, conn, &connMu, &createdIDs, &idsMu, msg, sendMsg, sendError)
		case "input":
			s.handleTermInput(msg, sendError)
		case "resize":
			s.handleTermResize(msg, sendError)
		case "close":
			s.handleTermClose(msg, sendMsg, sendError)
		default:
			sendError(msg.ID, "unknown message type: "+msg.Type)
		}
	}
}

// allowedShells is the set of permitted shell commands for terminal creation.
// Any shell not in this list is rejected to prevent arbitrary command execution.
var allowedShells = map[string]bool{
	"":              true, // empty means default (/bin/bash)
	"/bin/bash":     true,
	"/bin/sh":       true,
	"/bin/zsh":      true,
	"/usr/bin/bash": true,
	"/usr/bin/zsh":  true,
	"bash":          true,
	"sh":            true,
	"zsh":           true,
}

func (s *Server) handleTermCreate(
	wg *sync.WaitGroup,
	conn *websocket.Conn,
	connMu *sync.Mutex,
	createdIDs *[]string,
	idsMu *sync.Mutex,
	msg terminalMessage,
	sendMsg func(terminalMessage),
	sendError func(string, string),
) {
	if msg.ID == "" {
		sendError("", "missing terminal id")
		return
	}

	// Validate shell against allowlist to prevent arbitrary command execution.
	if !allowedShells[msg.Shell] {
		sendError(msg.ID, "shell not allowed: "+msg.Shell)
		return
	}

	// Validate workDir to prevent path traversal.
	if msg.WorkDir != "" {
		cleanedDir, err := sanitizePath(msg.WorkDir, true)
		if err != nil {
			sendError(msg.ID, "invalid workDir: "+err.Error())
			return
		}
		msg.WorkDir = cleanedDir
	}

	term, err := s.termManager.Create(msg.ID, msg.Shell, msg.WorkDir, msg.Rows, msg.Cols)
	if err != nil {
		sendError(msg.ID, "failed to create terminal: "+err.Error())
		return
	}

	idsMu.Lock()
	*createdIDs = append(*createdIDs, msg.ID)
	idsMu.Unlock()

	log.Printf("[WS/Terminal] created terminal %s via websocket", msg.ID)
	sendMsg(terminalMessage{Type: "created", ID: msg.ID})

	// Start a goroutine to read PTY output and send to client.
	wg.Add(1)
	go func(t *terminal.Terminal, id string) {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, err := t.Read(buf)
			if err != nil {
				// PTY closed or process exited.
				return
			}
			encoded := base64.StdEncoding.EncodeToString(buf[:n])
			connMu.Lock()
			writeErr := conn.WriteJSON(terminalMessage{
				Type: "output",
				ID:   id,
				Data: encoded,
			})
			connMu.Unlock()
			if writeErr != nil {
				return
			}
		}
	}(term, msg.ID)
}

func (s *Server) handleTermInput(msg terminalMessage, sendError func(string, string)) {
	t, ok := s.termManager.Get(msg.ID)
	if !ok {
		sendError(msg.ID, "terminal not found")
		return
	}

	data, err := base64.StdEncoding.DecodeString(msg.Data)
	if err != nil {
		// Try raw string if not base64.
		data = []byte(msg.Data)
	}

	if _, err := t.Write(data); err != nil {
		sendError(msg.ID, "write error: "+err.Error())
	}
}

func (s *Server) handleTermResize(msg terminalMessage, sendError func(string, string)) {
	if err := s.termManager.Resize(msg.ID, msg.Rows, msg.Cols); err != nil {
		sendError(msg.ID, "resize error: "+err.Error())
	}
}

func (s *Server) handleTermClose(msg terminalMessage, sendMsg func(terminalMessage), sendError func(string, string)) {
	if err := s.termManager.Close(msg.ID); err != nil {
		sendError(msg.ID, "close error: "+err.Error())
		return
	}
	log.Printf("[WS/Terminal] closed terminal %s via websocket", msg.ID)
	sendMsg(terminalMessage{Type: "closed", ID: msg.ID})
}
