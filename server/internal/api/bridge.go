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
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("bridge websocket upgrade error: %v", err)
		return
	}
	defer conn.Close()
	log.Printf("[WS/Bridge] connection established")

	terminalEvents, unsubscribeTerminal := s.termManager.SubscribeEvents()
	defer unsubscribeTerminal()

	var bridgeEvents <-chan vscode.BridgeEvent
	var unsubscribeBridge func()
	if s.bridgeManager != nil {
		bridgeEvents, unsubscribeBridge = s.bridgeManager.Subscribe(true)
		defer unsubscribeBridge()
	}

	var writeMu sync.Mutex
	writeEvent := func(event interface{}) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return conn.WriteJSON(event)
	}

	go func() {
		for event := range terminalEvents {
			if err := writeEvent(vscode.BridgeEvent{Type: event.Type, Payload: event.Session}); err != nil {
				log.Printf("[WS/Bridge] terminal event write error: %v", err)
				return
			}
		}
	}()

	if bridgeEvents != nil {
		go func() {
			for event := range bridgeEvents {
				if err := writeEvent(event); err != nil {
					log.Printf("[WS/Bridge] bridge event write error: %v", err)
					return
				}
			}
		}()
	}

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
