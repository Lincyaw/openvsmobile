package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"sync"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type bridgeErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type bridgeDocumentOpenRequest struct {
	Path    string  `json:"path"`
	Version int     `json:"version"`
	Content *string `json:"content,omitempty"`
}

type bridgeDocumentChangeRequest struct {
	Path    string                  `json:"path"`
	Version int                     `json:"version"`
	Changes []vscode.DocumentChange `json:"changes"`
}

type bridgeDocumentPathRequest struct {
	Path string `json:"path"`
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

func (s *Server) handleBridgeDocumentOpen(w http.ResponseWriter, r *http.Request) {
	if s.documentSync == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "document sync is not configured")
		return
	}

	var req bridgeDocumentOpenRequest
	if !decodeBridgeDocumentRequest(w, r, &req) {
		return
	}

	snapshot, err := s.documentSync.OpenDocument(req.Path, req.Version, req.Content)
	if err != nil {
		writeDocumentSyncError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) handleBridgeDocumentChange(w http.ResponseWriter, r *http.Request) {
	if s.documentSync == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "document sync is not configured")
		return
	}

	var req bridgeDocumentChangeRequest
	if !decodeBridgeDocumentRequest(w, r, &req) {
		return
	}

	snapshot, err := s.documentSync.ApplyDocumentChanges(req.Path, req.Version, req.Changes)
	if err != nil {
		writeDocumentSyncError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) handleBridgeDocumentSave(w http.ResponseWriter, r *http.Request) {
	if s.documentSync == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "document sync is not configured")
		return
	}

	var req bridgeDocumentPathRequest
	if !decodeBridgeDocumentRequest(w, r, &req) {
		return
	}

	snapshot, err := s.documentSync.SaveDocument(req.Path)
	if err != nil {
		writeDocumentSyncError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *Server) handleBridgeDocumentClose(w http.ResponseWriter, r *http.Request) {
	if s.documentSync == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "document sync is not configured")
		return
	}

	var req bridgeDocumentPathRequest
	if !decodeBridgeDocumentRequest(w, r, &req) {
		return
	}

	if err := s.documentSync.CloseDocument(req.Path); err != nil {
		writeDocumentSyncError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": req.Path, "closed": true})
}

func decodeBridgeDocumentRequest(w http.ResponseWriter, r *http.Request, dst any) bool {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "failed to read request body")
		return false
	}
	if err := json.Unmarshal(body, dst); err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "failed to decode JSON request body")
		return false
	}
	return true
}

func writeDocumentSyncError(w http.ResponseWriter, err error) {
	var bridgeErr *vscode.BridgeError
	if errors.As(err, &bridgeErr) {
		status := http.StatusInternalServerError
		switch bridgeErr.Code {
		case "invalid_request", "invalid_position":
			status = http.StatusBadRequest
		case "document_not_open":
			status = http.StatusNotFound
		case "version_conflict":
			status = http.StatusConflict
		case "bridge_not_ready":
			status = http.StatusServiceUnavailable
		}
		writeBridgeError(w, status, bridgeErr.Code, bridgeErr.Message)
		return
	}
	writeBridgeError(w, http.StatusInternalServerError, "bridge_error", "bridge document request failed")
}
