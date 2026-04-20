package api

import (
	"errors"
	"log"
	"net/http"
	"sync"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type bridgeErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (s *Server) handleBridgeCapabilities(w http.ResponseWriter, r *http.Request) {
	if s.bridgeManager == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "mobile runtime bridge is not ready")
		return
	}

	capabilities, err := s.bridgeManager.Capabilities()
	if err != nil {
		var bridgeErr *vscode.BridgeError
		if errors.As(err, &bridgeErr) {
			status := http.StatusServiceUnavailable
			if bridgeErr.Code == "capability_unavailable" {
				status = http.StatusNotFound
			}
			writeBridgeError(w, status, bridgeErr.Code, bridgeErr.Message)
			return
		}
		writeBridgeError(w, http.StatusInternalServerError, "capability_unavailable", "failed to load mobile runtime bridge capabilities")
		return
	}

	writeJSON(w, http.StatusOK, capabilities)
}

func (s *Server) handleWSBridgeEvents(w http.ResponseWriter, r *http.Request) {
	if s.bridgeManager == nil {
		http.Error(w, "mobile runtime bridge is not configured", http.StatusServiceUnavailable)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("bridge websocket upgrade error: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("[WS/Bridge] connection established")

	events, unsubscribe := s.bridgeManager.Subscribe(true)
	defer unsubscribe()

	var writeMu sync.Mutex

	go func() {
		for event := range events {
			writeMu.Lock()
			err := conn.WriteJSON(event)
			writeMu.Unlock()
			if err != nil {
				log.Printf("[WS/Bridge] write error: %v", err)
				return
			}
		}
	}()

	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			log.Printf("[WS/Bridge] connection closed")
			return
		}
	}
}

func writeBridgeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, bridgeErrorDetail{Code: code, Message: message})
}
